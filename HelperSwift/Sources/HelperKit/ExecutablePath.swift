import Foundation
import Darwin

/// Resolve the running process's actual on-disk executable path.
///
/// Codex P1④ review fix: `CommandLine.arguments[0]` is NOT the
/// binary path under launchd. The macOS LaunchAgent plist sets
/// `BundleProgram` (the on-disk binary) separately from
/// `ProgramArguments[0]` (the argv label). When launchd spawns
/// the helper, argv[0] is just the label string `cli_pulse_helper`
/// — wrapping it with `URL(fileURLWithPath:)` resolves against
/// launchd's cwd (typically `/`) and produces nonsense like
/// `/cli_pulse_helper`. That path is then embedded into the
/// `claude --settings` inline JSON as the hook command, and
/// Claude's hook subprocess fails to exec it, breaking
/// structured approval entirely.
///
/// `_NSGetExecutablePath` is the macOS-blessed API (declared in
/// `<mach-o/dyld.h>`) that returns the path the kernel used to
/// load the running binary. It works in every spawn context —
/// launchd, posix_spawn, exec from a shell — without depending
/// on argv0, cwd, or `Bundle.main` (which doesn't exist for
/// command-line tools that aren't inside a `.app`).
///
/// Two-step call:
///   1. Pass `nil` + `&size` to learn the buffer length needed.
///   2. Allocate buffer, call again to fill it.
public enum ExecutablePath {

    /// Resolve symlinks + normalise so the resulting path is the
    /// canonical absolute file path (e.g. `/Applications/CLI Pulse
    /// Bar.app/Contents/Helpers/cli_pulse_helper`).
    /// Returns nil only on the unrealistic case where
    /// `_NSGetExecutablePath` fails twice.
    public static func current() -> String? {
        // First call with nil buffer just reports the required size.
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(size))
        let result = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            return _NSGetExecutablePath(ptr.baseAddress, &size)
        }
        if result != 0 { return nil }
        let raw = String(cString: buf)
        // `_NSGetExecutablePath` may return a path containing `..`
        // or symlinks (e.g. when the .app bundle was launched via
        // an Alias). `URL.standardizedFileURL.resolvingSymlinksInPath()`
        // canonicalises so the hook command embedded in
        // `--settings` is stable across launches.
        let url = URL(fileURLWithPath: raw)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
