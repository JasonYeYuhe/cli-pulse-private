import XCTest
@testable import CLIPulseCore

/// Pin the iter16 contract: after `applySignedOutState`, `selectedTab`
/// MUST be `.settings`. The pre-iter16 reset to `.overview` made
/// post-sign-out / post-delete-account users land on an empty
/// "No Data Yet" view with no hint about what to do next; the iter14
/// "Continue without account" escape and the iter9 sign-in form both
/// live on the Settings tab, so that's the right landing.
///
/// iter19 (2026-04-29) note: the `restoreSession()` `.unavailable`
/// branch (cold launch with no stored token) ALSO sets
/// `selectedTab = .settings` directly — it was previously a `break`
/// no-op, which left the AppState init default `.overview` intact and
/// dropped fresh-install users onto a blank Overview. The iter19
/// behavior isn't unit-tested here because exercising it requires
/// touching live Keychain state (deleting the user's running tokens
/// to simulate "no stored token"), which would either break the dev
/// machine's session or be flaky depending on the order tests run.
/// The contract is verified by:
///   1. Code-level invariant — both `.unavailable` and `.failed`
///      branches now route to the same destination (.settings).
///   2. The tests below pinning `applySignedOutState → .settings`.
///   3. Manual real-device verification (open menu bar after fresh
///      install / Keychain wipe → land on Settings, not Overview).
///
/// `applySignedOutState` is `internal`, accessed via `@testable`. The
/// public `signOut()` wrapper would also exercise this, but it spawns
/// a Task to unregister the push token, so calling the inner reset
/// directly keeps the test deterministic.
@MainActor
final class SignedOutLandingTests: XCTestCase {

    /// The iter16 fix: signed-out reset must select `.settings` so the
    /// user sees the Sign-In form / OAuth buttons / "Continue without
    /// account" escape — not an empty Overview.
    func testApplySignedOutStateSelectsSettingsTab() {
        let state = AppState()
        // Simulate a signed-in user mid-session who happens to be on
        // a non-Settings tab.
        state.selectedTab = .overview

        state.applySignedOutState()

        XCTAssertEqual(state.selectedTab, .settings,
                       "post-sign-out landing must be Settings (Sign-In form), not Overview")
    }

    /// Defense-in-depth: regardless of which tab the user was on
    /// (Providers / Sessions / Alerts / Overview / Settings), the reset
    /// converges on `.settings`. The signed-out branch in MenuBarView
    /// routes by `selectedTab`, so this single field drives the entire
    /// post-sign-out first-impression UX.
    func testApplySignedOutStateConvergesFromAnyTab() {
        for startTab in AppState.Tab.allCases {
            let state = AppState()
            state.selectedTab = startTab
            state.applySignedOutState()
            XCTAssertEqual(
                state.selectedTab, .settings,
                "starting from \(startTab) must converge to .settings after sign-out"
            )
        }
    }

    /// Pin that the other state cleared by `applySignedOutState`
    /// stays cleared. This is a regression guard: if a future refactor
    /// drops fields from the reset, the test catches the most
    /// safety-relevant ones (auth flag, dashboard cache, error state).
    /// The full list lives at `AuthManager.swift:applySignedOutState`.
    func testApplySignedOutStateClearsAuthAndCache() {
        let state = AppState()
        state.isAuthenticated = true
        state.isPaired = true
        state.userId = "test-user"
        state.lastError = "stale error"

        state.applySignedOutState()

        XCTAssertFalse(state.isAuthenticated, "auth flag must clear")
        XCTAssertFalse(state.isPaired, "pair flag must clear")
        XCTAssertEqual(state.userId, "", "userId must clear")
        XCTAssertNil(state.lastError, "stale error must clear")
        XCTAssertNil(state.dashboard, "dashboard must clear")
    }

    /// iter17 contract: a sign-out from local mode must clear
    /// `isLocalMode`. Otherwise re-opening the popover after sign-out
    /// would still route to the connected shell (because MenuBarView
    /// gates on `state.isLocalMode || authState.isPaired`), and the
    /// user would land on the Overview empty card with stale provider
    /// data — exactly the "what's going on" symptom this iter aims
    /// to fix.
    func testApplySignedOutStateClearsLocalMode() {
        let state = AppState()
        state.isLocalMode = true

        state.applySignedOutState()

        XCTAssertFalse(state.isLocalMode,
                       "sign-out must drop the local-mode flag so MenuBarView routes back to notConnectedView (Sign-In form)")
    }
}
