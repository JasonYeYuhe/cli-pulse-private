import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Environment resolution for spawned managed-session children.
///
/// Why: a per-user LaunchAgent often starts with a bogus `$HOME` (launchd hands
/// agents `/var/empty` or `/` depending on the session type) and a minimal `PATH`
/// that omits `/opt/homebrew/bin`. Managed providers are file-driven by HOME —
/// `claude` (~/.claude), `codex` (~/.codex), and `agy`→gemini (~/.gemini/oauth_creds.json)
/// — so spawning them with the inherited launchd env silently breaks plan auth or fails
/// to find the binary. We therefore resolve HOME from the PASSWORD DATABASE (getpwuid,
/// NOT `$HOME`) and augment PATH before spawn.
public enum HelperEnvironment {

    /// The current user's home directory from the password database via
    /// `getpwuid_r(getuid())` — reliable even when `$HOME` is wrong. Returns nil
    /// (so callers skip augmentation rather than inject a wrong home) if:
    ///   - running as root (uid 0) — managed providers must never run as root, and
    ///     root's home is not the GUI user's creds dir; or
    ///   - the home can't be resolved to an absolute path.
    public static func resolvedUserHome() -> String? {
        let uid = getuid()
        guard uid != 0 else { return nil }
        var capacity = 16384
        let maxCapacity = 1 << 20
        while capacity <= maxCapacity {
            var buffer = [CChar](repeating: 0, count: capacity)
            // Copy pw_dir into a Swift String INSIDE the buffer's lifetime — the
            // passwd struct's char* fields point into `buffer` (see R1a getpwuid_r).
            let outcome: (rc: Int32, home: String?) = buffer.withUnsafeMutableBufferPointer { buf in
                var pwd = passwd()
                var result: UnsafeMutablePointer<passwd>? = nil
                let rc = getpwuid_r(uid, &pwd, buf.baseAddress, buf.count, &result)
                if rc == 0, result != nil, let dir = pwd.pw_dir {
                    return (0, String(cString: dir))
                }
                return (rc, nil)
            }
            if outcome.rc == 0 {
                guard let home = outcome.home, home.hasPrefix("/") else { return nil }
                return home
            }
            if outcome.rc == ERANGE { capacity *= 2; continue }
            return nil
        }
        return nil
    }

    /// Standard Homebrew / local install dirs that a launchd PATH usually omits but
    /// where `claude`/`codex`/`agy` commonly live.
    static func extraBinDirs(home: String?) -> [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        if let home, home.hasPrefix("/") { dirs.append("\(home)/.local/bin") }
        return dirs
    }

    /// `base` PATH (the inherited launchd PATH) with the extra bin dirs appended.
    /// The resolved home is INTERPOLATED here in Swift — `posix_spawn`/`execve` do NOT
    /// expand a literal `$HOME`, so a `"$HOME/.local/bin"` string would be a dead path.
    public static func augmentedPATH(base: String?, home: String?) -> String {
        var dirs = (base ?? "").split(separator: ":").map(String.init)
        for d in extraBinDirs(home: home) where !dirs.contains(d) { dirs.append(d) }
        return dirs.joined(separator: ":")
    }
}
