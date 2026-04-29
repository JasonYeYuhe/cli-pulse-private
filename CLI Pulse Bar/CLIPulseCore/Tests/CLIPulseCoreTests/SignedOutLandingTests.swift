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

    // MARK: - iter20 Remote Approvals + push-token state cleanup

    /// iter20 F1: same-session sign-out → sign-in (account switch with no
    /// app relaunch) must not leak Remote Approvals UI state from the
    /// previous user. Without this reset:
    ///   - `remoteControlEnabled = true` would route the new user into
    ///     `connectedView` immediately on sign-in instead of the proper
    ///     post-sign-in shell;
    ///   - `remotePendingApprovals` would render the previous user's
    ///     approval rows as actionable until the next 120s refresh;
    ///   - `remoteControlSaving = true` (mid-PATCH at sign-out) would
    ///     leave the toggle disabled forever for the new session.
    ///
    /// Documenting the full set of remote-approval fields here so a
    /// future refactor that drops one of them is caught by this test.
    func testApplySignedOutStateClearsRemoteApprovalsState() {
        let state = AppState()
        state.remoteControlEnabled = true
        state.remoteControlSaving = true
        state.remotePendingApprovals = [
            RemotePermissionRequest(
                id: "req-1", session_id: nil, device_id: "dev-1",
                device_name: "Test Mac",
                provider: "claude", tool_name: "Bash",
                summary: "$ ls -la", risk: "medium", status: "pending",
                created_at: "2026-04-29T00:00:00Z",
                expires_at: "2026-04-29T00:05:00Z"
            )
        ]
        state.remoteApprovalsLastRefresh = Date()
        state.remoteApprovalsError = "stale error from previous session"

        state.applySignedOutState()

        XCTAssertFalse(state.remoteControlEnabled,
                       "remoteControlEnabled must clear so MenuBarView doesn't route into connectedView under the previous user's gate")
        XCTAssertFalse(state.remoteControlSaving,
                       "remoteControlSaving must clear so a mid-PATCH sign-out doesn't lock the new session's toggle")
        XCTAssertTrue(state.remotePendingApprovals.isEmpty,
                      "remotePendingApprovals must clear so the new session never sees previous-user approval rows")
        XCTAssertNil(state.remoteApprovalsLastRefresh,
                     "lastRefresh must clear so the polling loop's freshness gate starts cold for the new session")
        XCTAssertNil(state.remoteApprovalsError,
                     "stale error must clear so the new login screen doesn't display a previous-session error")
    }

    /// iter20 F1: push-token state must reset on sign-out. The concrete
    /// failure window if `registeredPushToken` survives sign-out:
    ///   1. User A signs in, APNs delivers token, `syncPushToken`
    ///      writes `registeredPushToken = "abc..."` and registers
    ///      server-side.
    ///   2. User A taps Sign Out. iter11's `unregisterPushTokenOnLogout`
    ///      DELETEs the server `app_push_tokens` row. But pre-iter20,
    ///      `applySignedOutState` left `registeredPushToken = "abc..."`
    ///      on AppState.
    ///   3. User B signs in same-session (no app relaunch). APNs does
    ///      NOT redeliver mid-session — the device token is only
    ///      published once via `didRegister` at app launch. So the only
    ///      replay surface is `flushPendingPushTokenIfAvailable`.
    ///   4. `flushPendingPushTokenIfAvailable` calls `syncPushToken`
    ///      with the cached pending tuple (or no-ops if already
    ///      consumed). Either way, `syncPushToken`'s short-circuit at
    ///      `if registeredPushToken == token` fires — no server-side
    ///      registration happens for User B.
    ///   5. User B receives no push notifications until app relaunch.
    ///
    /// Clearing `registeredPushToken` on sign-out forces a fresh
    /// server-side registration for the next sign-in.
    func testApplySignedOutStateClearsPushTokenState() {
        let state = AppState()
        let realisticToken = String(repeating: "a", count: 64)
        state.registeredPushToken = realisticToken
        state.pendingPushTokenRegistration = PendingPushTokenRegistration(
            token: realisticToken,
            platform: "ios",
            bundleId: "yyh.CLI-Pulse"
        )

        state.applySignedOutState()

        XCTAssertNil(state.registeredPushToken,
                     "registeredPushToken must clear so the next sign-in's syncPushToken doesn't short-circuit on a stale acknowledgment")
        XCTAssertNil(state.pendingPushTokenRegistration,
                     "pendingPushTokenRegistration must clear so the previous user's cached tuple doesn't replay against the new user's JWT")
    }

    /// iter20 F1: defense-in-depth combined snapshot — every field
    /// touched by the iter20 reset clears in a single applySignedOutState
    /// call. If a future refactor splits the reset into branches that
    /// might miss one field, this test catches the regression.
    func testApplySignedOutStateClearsEntireRemotePushSurface() {
        let state = AppState()
        state.remoteControlEnabled = true
        state.remoteControlSaving = true
        state.remotePendingApprovals = [
            RemotePermissionRequest(
                id: "x", session_id: nil, device_id: "y", device_name: nil,
                provider: "claude", tool_name: "Bash",
                summary: "x", risk: "low", status: "pending",
                created_at: "2026-04-29T00:00:00Z",
                expires_at: "2026-04-29T00:05:00Z"
            )
        ]
        state.remoteApprovalsLastRefresh = Date()
        state.remoteApprovalsError = "x"
        state.registeredPushToken = "x"
        state.pendingPushTokenRegistration = PendingPushTokenRegistration(
            token: "x", platform: "ios", bundleId: "y"
        )

        state.applySignedOutState()

        XCTAssertFalse(state.remoteControlEnabled)
        XCTAssertFalse(state.remoteControlSaving)
        XCTAssertTrue(state.remotePendingApprovals.isEmpty)
        XCTAssertNil(state.remoteApprovalsLastRefresh)
        XCTAssertNil(state.remoteApprovalsError)
        XCTAssertNil(state.registeredPushToken)
        XCTAssertNil(state.pendingPushTokenRegistration)
    }
}
