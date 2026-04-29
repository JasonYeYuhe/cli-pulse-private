#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Pin the macOS-only `AppState.continueWithoutAccount()` contract
/// added in iter17. This is the user's "Use local mode" entry point
/// from the signed-out Settings tab.
///
/// Pre-iter17 the SettingsTab button only mutated `state.selectedTab
/// = .overview`, but `refreshAll` early-exited at the `!isAuthenti-
/// cated` gate so the dashboard stayed empty. iter17 makes the button
/// actually flip into local mode (collector results applied,
/// `MenuBarView` routes to `connectedView`, etc.).
///
/// We pin the synchronous state mutations directly. The downstream
/// `Task { await refreshAll() }` spawns asynchronously and depends
/// on a real APIClient + collectors, so its end-to-end behavior is
/// covered by manual real-device verification + `RefreshRouterTests`
/// (which pins the routing decision the spawned task will reach).
@MainActor
final class ContinueWithoutAccountTests: XCTestCase {

    /// Headline contract: after `continueWithoutAccount()`, the user
    /// is in local mode, on the Overview tab, with `serverOnline =
    /// true` so the "Server offline" banner doesn't flash.
    func testContinueWithoutAccountFlipsLocalModeAndOverview() {
        let state = AppState()
        // Mid-session preconditions a signed-out user could be in:
        // not authenticated, on Settings (the iter16 default landing).
        state.isAuthenticated = false
        state.isLocalMode = false
        state.selectedTab = .settings
        state.serverOnline = false

        state.continueWithoutAccount()

        XCTAssertTrue(state.isLocalMode,
                      "must flip isLocalMode → MenuBarView routes to connectedView")
        XCTAssertEqual(state.selectedTab, .overview,
                       "must land on Overview tab so the user sees the local-mode-ready guide")
        XCTAssertTrue(state.serverOnline,
                      "must clear serverOnline=false so 'Server offline' banner doesn't flash on entry")
    }

    /// Defense: `continueWithoutAccount` is callable from any tab,
    /// not only Settings. Idempotent for callers who somehow ended
    /// up here twice (e.g. tap-tap on the button before the popover
    /// re-renders).
    func testContinueWithoutAccountIsIdempotent() {
        let state = AppState()
        state.continueWithoutAccount()
        let firstSnapshot = (state.isLocalMode, state.selectedTab, state.serverOnline)

        state.continueWithoutAccount()
        let secondSnapshot = (state.isLocalMode, state.selectedTab, state.serverOnline)

        XCTAssertEqual(firstSnapshot.0, secondSnapshot.0)
        XCTAssertEqual(firstSnapshot.1, secondSnapshot.1)
        XCTAssertEqual(firstSnapshot.2, secondSnapshot.2)
    }
}
#endif
