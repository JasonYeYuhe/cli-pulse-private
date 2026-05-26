import Foundation

/// v1.24 Phase 3 (Gemini LOW from in-app-terminal plan §R1): the
/// in-app terminal needs out-of-sandbox PTY spawn, which MAS
/// installs cannot do without a helper PKG (and even with one,
/// the matrix is not wired up for v1.24.0). Rather than fail with
/// a confusing error message at "New Terminal" tap, **hide the
/// menu entry entirely on MAS builds**.
///
/// Detection method: MAS containers live under
/// `~/Library/Containers/<bundle id>/`, so `NSHomeDirectory()`
/// returns a path containing `/Library/Containers/` on sandboxed
/// runs and the user's real home on Developer ID builds. This is
/// the same probe the codebase has used elsewhere for sandbox
/// detection (cf. `feedback_mas_vs_devid_helper` memory).
public enum MASSandboxGate {

    /// True iff the current process is running inside the App
    /// Sandbox. Treat the result as "show the terminal UI?": false →
    /// show, true → hide. Computed once per call (sandbox status
    /// cannot change at runtime — it's a launchd / xcrun decision).
    public static var isSandboxed: Bool {
        NSHomeDirectory().contains("/Library/Containers/")
    }

    /// Inverse of `isSandboxed` — readability sugar for menu/scene
    /// `if` predicates. `if MASSandboxGate.canHostInAppTerminal { ... }`
    /// reads more naturally than `if !MASSandboxGate.isSandboxed`.
    public static var canHostInAppTerminal: Bool {
        !isSandboxed
    }
}
