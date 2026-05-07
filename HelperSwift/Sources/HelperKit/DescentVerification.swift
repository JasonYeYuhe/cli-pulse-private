import Foundation
import Darwin

/// Process-ancestry (descent) verification — Swift port of
/// `helper/local_approvals.py:_peer_pid_from_socket` and
/// `_read_ppid`.
///
/// Why descent verification:
///   The hook subprocess Claude spawns connects to the helper's
///   UDS over the same socket every other process can reach. The
///   capability token in env protects against another USER's
///   session forging a request, but token compromise alone could
///   come from many places (env-leak in a screen recording, an
///   accidental `printenv > /tmp/foo`, etc.). Descent verification
///   adds a kernel-level second factor: the request MUST come from
///   a process whose ancestry chain includes the recorded Claude
///   pid. A leaked token from outside the Claude process tree
///   doesn't authenticate.
///
/// macOS APIs used:
///   - `getsockopt(SOL_LOCAL, LOCAL_PEERPID)` — kernel-attested
///     pid of the peer that connected. Cannot be forged from
///     userspace.
///   - `proc_pidinfo(PROC_PIDT_BSDINFO_WITH_UNIQID, ...)` from
///     libproc.h — read the BSD kinfo_proc struct to extract
///     `pbi_ppid` (parent pid).
///
/// Cap on ppid walks: 20 hops. A pathological process tree can
/// loop forever otherwise (kernel-level pid recycling can in
/// theory create cycles though it's unusual). 20 is far above the
/// realistic Claude-spawn-helper-spawn-… depth.
public enum DescentVerification {

    public static let ppidWalkLimit = 20

    public enum DescentError: Error, Equatable {
        case noPeerPid
        case ppidLookupFailed(pid: Int32)
        case descentMismatch(claudePid: Int32, peerPid: Int32)
    }

    /// Resolve the peer pid for a connected AF_UNIX socket fd.
    /// Returns nil when the syscall fails (typically because the
    /// peer has already disconnected).
    public static func peerPid(forFD fd: Int32) -> Int32? {
        var pid: Int32 = 0
        var len: socklen_t = socklen_t(MemoryLayout<Int32>.size)
        let result = withUnsafeMutablePointer(to: &pid) { pidPtr -> Int32 in
            return Darwin.getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, pidPtr, &len)
        }
        guard result == 0 else { return nil }
        return pid > 0 ? pid : nil
    }

    /// Resolve the parent pid for `pid` via libproc. Returns nil
    /// when the process has already exited (most common reason)
    /// or when libproc rejects (rare).
    public static func parentPid(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            size
        )
        guard result == size else { return nil }
        let ppid = Int32(info.pbi_ppid)
        return ppid > 0 ? ppid : nil
    }

    /// Walk the parent chain starting from `peerPid`, up to
    /// `ppidWalkLimit` hops. Returns true iff `claudePid` is
    /// found anywhere in the chain (inclusive of peerPid itself).
    /// Returns false on:
    ///   - peerPid == 0
    ///   - chain runs out before reaching claudePid
    ///   - chain hits the limit without a match
    ///   - libproc lookup fails mid-walk (process already reaped)
    public static func descentChainContains(
        claudePid: Int32,
        peerPid: Int32,
        parentResolver: (Int32) -> Int32? = parentPid(of:)
    ) -> Bool {
        if claudePid <= 0 || peerPid <= 0 { return false }
        var current = peerPid
        var hops = 0
        while hops < ppidWalkLimit {
            if current == claudePid { return true }
            // pid 1 is launchd; reached the root → no match.
            if current == 1 { return false }
            guard let parent = parentResolver(current) else {
                return false
            }
            // Defensive: if a syscall returns the same pid as its
            // parent (kernel pathology) treat as no-match rather
            // than spinning.
            if parent == current { return false }
            current = parent
            hops += 1
        }
        return false
    }

    /// Verify `peerFD`'s connecting process descends from
    /// `claudePid`. Throws on any failure mode. Use from
    /// `LocalSessionServer` connection handler before honouring
    /// hook-ingress requests.
    public static func verify(
        peerFD: Int32,
        claudePid: Int32
    ) throws {
        guard let peer = peerPid(forFD: peerFD) else {
            throw DescentError.noPeerPid
        }
        if descentChainContains(claudePid: claudePid, peerPid: peer) {
            return
        }
        throw DescentError.descentMismatch(claudePid: claudePid, peerPid: peer)
    }
}
