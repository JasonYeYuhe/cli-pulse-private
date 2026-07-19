import Foundation
import Darwin

/// The bundled DEVID helper's private runtime directory: `~/.clipulse`.
///
/// WHY THIS EXISTS — it is the fix for the recurring macOS prompt
/// *"CLI Pulse would like to access data from other apps."*
///
/// `kTCCServiceSystemPolicyAppData` is **path-prefix triggered**. The kernel asks
/// `tccd` only when an `open(2)`/`bind(2)` lands under a protected prefix —
/// `~/Library/Containers/*`, `~/Library/Group Containers/*`,
/// `~/Library/Application Support/<other app>/*`. Our rendezvous (UDS socket +
/// auth token) used to live in `~/Library/Group Containers/group.yyh.CLI-Pulse/`,
/// so every launchd start of this unsandboxed helper generated a consult.
///
/// `~/.clipulse` is a plain dotdir at the home root, owned by the same uid, under
/// **no** protected prefix. **No consult is generated at all** — the helper is not
/// "allowed", it is never evaluated. That distinction is the whole point:
///
///   * A *grant* can be revoked, can fail to persist, and is re-evaluated per
///     binary identity. We measured all three failure modes on the owner's Mac:
///     the bundled helper had **zero** TCC rows despite repeated prompting, so its
///     answer was never persisted and it asked forever. Clicking "Don't Allow"
///     recorded nothing; clicking "Allow" would have recorded nothing either.
///   * *Never being evaluated* cannot fail. There is no row to lose, nothing to
///     re-approve on update, and no dialog to dismiss.
///
/// Measured on macOS 26.5, launchd-spawned, same uid (2026-07-18):
///   - group container : 1–10s first touch, >20s tail, **prompts**
///   - `~/.clipulse`   : **29ms** first touch, 28ms second, **cannot prompt**
///
/// Ruled out by evidence rather than assumption: the `application-groups`
/// entitlement does NOT exempt a binary from this consult — the `.pkg` helper
/// carries that entitlement and still has a `reason=2` (user consent) AppData row,
/// i.e. it prompted. And no CLI Pulse row pins a `csreq`, so "re-signing
/// invalidates the grant" was never the mechanism either.
///
/// SECURITY — a home dotdir is weaker than a container in exactly one way that
/// matters: **another local process can create it first.** A container is vended
/// by the OS and cannot be pre-planted. So every use goes through `secureRoot()`,
/// which REFUSES a root that is a symlink, not a directory, or owned by another
/// uid — the shapes that actually indicate a planted directory, and that no chmod
/// can make safe. The UDS auth token lives here and grants full control of managed
/// CLI sessions, so that would be a real privilege escalation.
///
/// A root we DO own that merely has loose permissions is TIGHTENED to 0700, not
/// refused: `~/.clipulse` already exists at 0755 on real installs (this repo's
/// `ClaudeSnapshotWriter` has written `claude_snapshot.json` there for ages, via
/// the default umask), so refusing it would have failed token rotation on
/// essentially every existing machine.
public enum RuntimeRoot {

    /// Directory name under the user's home. Dotted so it stays out of Finder and
    /// out of the "user data" prefixes (Desktop/Documents/Downloads) that carry
    /// their own TCC gates.
    public static let directoryName = ".clipulse"

    /// Escape hatch for tests and for anyone who needs to relocate the runtime
    /// root. Honoured by the app-side resolver too, so both ends stay in sync.
    public static let overrideEnvVar = "CLIPULSE_HELPER_ROOT"

    public enum RootError: Error, CustomStringConvertible {
        case unsafeRoot(path: String, reason: String)

        public var description: String {
            switch self {
            case let .unsafeRoot(path, reason):
                return "refusing to use runtime root \(path): \(reason)"
            }
        }
    }

    /// The home directory from the **password database**, not `$HOME`.
    ///
    /// Deliberate: `$HOME` is attacker-influencable in some launch contexts and is
    /// not what a non-sandboxed launchd agent should trust for a security-relevant
    /// path. (It also matches what `NSHomeDirectory()` resolves to for this
    /// process, so behaviour is unchanged for normal runs.)
    static func homeDirectory() -> String {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        let rc = getpwuid_r(getuid(), &pwd, &buffer, buffer.count, &result)
        if rc == 0, result != nil, let dir = pwd.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return path }
        }
        return NSHomeDirectory()
    }

    /// The runtime root path, WITHOUT creating or validating it.
    /// Prefixes that make the kernel consult tccd. An override pointing into one
    /// of these would re-arm the exact prompt this type exists to eliminate, so it
    /// is ignored rather than honoured (review: codex).
    static let tccProtectedFragments = [
        "/Library/Group Containers/",
        "/Library/Containers/",
        "/Library/Application Support/",
    ]

    public static func path() -> URL {
        if let override = ProcessInfo.processInfo.environment[overrideEnvVar],
           !override.isEmpty {
            // Refuse to relocate INTO a protected prefix — that would silently
            // restore the consult (and the dialog) via the escape hatch.
            let normalized = override.hasSuffix("/") ? override : override + "/"
            if tccProtectedFragments.contains(where: { normalized.contains($0) }) {
                FileHandle.standardError.write(Data(
                    ("warning: ignoring \(overrideEnvVar)=\(override) — it points inside a "
                     + "TCC-protected prefix, which would re-arm the app-data permission "
                     + "prompt. Falling back to the default runtime root.\n").utf8
                ))
            } else {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
        }
        return URL(fileURLWithPath: homeDirectory(), isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Create the root if needed, then verify it is safe to hold secrets in.
    /// Throws rather than falling back — a runtime root we cannot vouch for must
    /// never receive the auth token.
    @discardableResult
    public static func secureRoot() throws -> URL {
        let root = path()

        // Open the directory itself with O_NOFOLLOW and validate through the FD,
        // not the path (review: codex). A path-based lstat→chmod sequence is
        // racy: `chmod` follows a symlink swapped in after the `lstat`, so an
        // attacker could redirect the mode change — and our trust — elsewhere.
        // `fstat`/`fchmod` operate on the pinned inode, so whatever we validate
        // is exactly what we modify.
        //
        // THREAT MODEL, honestly stated: swapping that symlink requires write
        // access to the user's HOME, which means the attacker is already running
        // as this same uid — and a same-uid process can read the token file
        // directly regardless. So there is no privilege boundary left to defend
        // in that case. The check that carries real weight is the OWNERSHIP test
        // below, which stops a *different* uid from pre-planting the directory.
        // The fd pinning is defence in depth, not the load-bearing control.
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            defer { close(fd) }
            var st = stat()
            if fstat(fd, &st) != 0 {
                throw RootError.unsafeRoot(path: root.path, reason: "fstat failed")
            }
            if st.st_uid != getuid() {
                throw RootError.unsafeRoot(
                    path: root.path,
                    reason: "it is owned by uid \(st.st_uid), not \(getuid()) — it may have been pre-planted"
                )
            }
            // Group/world access must not stand — the auth token here grants full
            // control of managed CLI sessions. But since we've already proven WE
            // own it, TIGHTEN rather than refuse.
            //
            // This distinction is load-bearing, not pedantry. `~/.clipulse` already
            // exists on real machines at mode 0755: `ClaudeSnapshotWriter` has been
            // writing `claude_snapshot.json` there since long before this change,
            // and it created the directory with the default umask. Refusing a
            // loosely-permissioned directory we own would therefore have failed
            // token rotation on essentially EVERY existing install — the helper
            // would start with an empty token and every gated RPC would fail
            // closed, i.e. local session control silently dead. Verified on the
            // owner's Mac, where ~/.clipulse was already 0755.
            if (st.st_mode & mode_t(S_IRWXG | S_IRWXO)) != 0 {
                if fchmod(fd, 0o700) != 0 {
                    throw RootError.unsafeRoot(
                        path: root.path,
                        reason: String(
                            format: "it is group/world-accessible (mode %o) and fchmod 0700 failed: %s",
                            st.st_mode & 0o777, strerror(errno)
                        )
                    )
                }
            }
            return root
        }
        // ELOOP => a symlink is sitting where our root should be; ENOTDIR => a
        // file. Both are refusal cases: no chmod can make them safe.
        if errno == ELOOP {
            throw RootError.unsafeRoot(path: root.path, reason: "it is a symlink")
        }
        if errno == ENOTDIR {
            throw RootError.unsafeRoot(path: root.path, reason: "it is not a directory")
        }
        if errno != ENOENT {
            throw RootError.unsafeRoot(
                path: root.path, reason: "cannot open: \(String(cString: strerror(errno)))"
            )
        }

        // Does not exist — create it 0700. mkdir is atomic, so it cannot be raced
        // into existence by someone else between our lstat and here: if they win,
        // mkdir fails EEXIST and we re-validate on the next call.
        if mkdir(root.path, 0o700) != 0 {
            let err = errno
            if err == EEXIST {
                // Lost the race; validate whatever is there now.
                return try secureRoot()
            }
            throw RootError.unsafeRoot(
                path: root.path,
                reason: "mkdir failed: \(String(cString: strerror(err)))"
            )
        }
        return root
    }
}
