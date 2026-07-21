// Post-1.42.0 audit: passive update discovery. `refresh()` used to fire only
// from the Settings Updates section, so a user who never opened Settings never
// learned a release existed — including security-relevant ones (the 1.41.2
// TCC fix). Gated exactly like AppUpdater itself.
#if os(macOS) && DEVID_BUILD
import Foundation

extension AppUpdater {

    /// Throttled `refresh()`: runs when the last check is older than `maxAge`
    /// (24h) and nothing is mid-flight. Called from the popover-focus hook in
    /// `MenuBarView` (next to `HelperInstaller.refreshIfStale()`), so the
    /// network cost is at most one manifest GET per `maxAge` window.
    ///
    /// Gates on `inFlight`, NOT on `state == .checking`: the initial `state`
    /// value IS `.checking` with no request behind it, so a state check would
    /// return early on every fresh launch and passive discovery would never
    /// run at all — the exact bug this method exists to fix (codex review).
    @MainActor
    public func refreshIfStale(now: Date = Date(),
                               maxAge: TimeInterval = 24 * 60 * 60) async {
        if inFlight { return }
        if case .readyToInstall = state {
            return  // never yank a staged install out from under the user
        }
        if let last = lastChecked, now.timeIntervalSince(last) < maxAge { return }
        await refresh()
    }
}

#endif
