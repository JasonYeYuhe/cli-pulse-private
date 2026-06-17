#if os(macOS)
import Foundation

/// Holds a process-lifetime `NSActivity` assertion so the menu-bar app
/// isn't App-Napped while it sits in the background.
///
/// CLI Pulse is an `LSUIElement` accessory app that polls usage on a timer.
/// Left to the default policy, macOS App-Naps the backgrounded process and
/// throttles its run loop — which (a) stalls the periodic refresh so the UI
/// shows stale data and feels "unresponsive in the background", and (b)
/// makes Sentry's app-hang watchdog misfire on the throttled idle run loop
/// (Sentry APPLE-MACOS-B). A single `.background` activity assertion
/// suppresses App Nap without preventing system or display sleep, so the
/// energy cost is the periodic work the app was already doing.
///
/// Lives in CLIPulseCore (compiles + type-checks with the local Swift
/// toolchain) and is driven by the macOS app target, which holds one
/// instance for its lifetime.
public final class BackgroundActivityAssertion {
    private var token: NSObjectProtocol?

    public init() {}

    /// Begin the assertion. Idempotent — a second call while already active
    /// is a no-op.
    public func begin(reason: String = "CLI Pulse background usage refresh") {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(options: .background, reason: reason)
    }

    /// End the assertion (released automatically on deinit).
    public func end() {
        if let token {
            ProcessInfo.processInfo.endActivity(token)
        }
        token = nil
    }

    deinit {
        end()
    }
}
#endif
