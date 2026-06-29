#if os(macOS)
import Foundation

/// Resolve the current user's REAL home directory from the password database,
/// bypassing the App Sandbox container redirect that `NSHomeDirectory()` /
/// `FileManager.homeDirectoryForCurrentUser` apply (those return
/// `~/Library/Containers/<bundle>/Data` under the sandbox).
///
/// Why `getpwuid_r` and not plain `getpwuid`: `getpwuid` returns a pointer into
/// a single process-wide static `passwd` buffer. A concurrent `getpwuid` /
/// `getpwnam` / `getpwent` call on ANY other thread can overwrite that buffer
/// between our call and the `pw_dir` read, yielding a torn or wrong home path
/// (the result of `getpwuid` "may point to a static area" — POSIX). The `_r`
/// ("reentrant") variant fills a caller-owned buffer instead, so the lookup is
/// thread-safe. This matters because home resolution runs from background
/// queues (collectors, the local-session client, bookmark restore) while the
/// app is live.
///
/// Returns `nil` (never a sandbox path) when the passwd lookup fails or the
/// entry has an empty home, so each caller can apply its own fallback
/// (`NSHomeDirectoryForUser`, container-path stripping, etc.) — matching the
/// behavior each site had with the old `getpwuid` guard.
func passwdHomeDirectory() -> String? {
    let uid = getuid()
    // Initial buffer size: the system's suggested maximum, or a generous
    // default if the platform reports "indeterminate" (-1). `getpwuid_r` then
    // signals `ERANGE` if the buffer is too small and we grow + retry.
    var capacity = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
    if capacity <= 0 { capacity = 16_384 }

    while true {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>? = nil
        var buffer = [CChar](repeating: 0, count: capacity)
        // `pwd.pw_dir` points INTO `buffer`, so keep the buffer's borrow open
        // across BOTH the lookup and the `String(cString:)` copy — reading the
        // C pointer after the buffer's guaranteed-valid scope ends would be
        // formally undefined in Swift's memory model. `rc == 0` with a NULL
        // result means "no matching entry" (not an error).
        let outcome: (rc: Int32, home: String?) = buffer.withUnsafeMutableBufferPointer { ptr in
            let rc = getpwuid_r(uid, &pwd, ptr.baseAddress, capacity, &result)
            guard rc == 0, result != nil, let dir = pwd.pw_dir else { return (rc, nil) }
            let home = String(cString: dir)
            return (rc, home.isEmpty ? nil : home)
        }
        if outcome.rc == 0 {
            return outcome.home
        }
        // Buffer too small — double and retry, capped so a misbehaving libc
        // can never spin us into an unbounded allocation loop.
        if outcome.rc == ERANGE, capacity < (1 << 20) {
            capacity *= 2
            continue
        }
        // Any other errno (EIO, EMFILE, EINTR, …): give up and let the caller
        // fall back. Never return a guessed/sandbox path from here.
        return nil
    }
}
#endif
