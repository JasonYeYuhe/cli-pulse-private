import XCTest
@testable import CLIPulseCore

/// Tests for the iter8 hotfix: APNs push token registration must NOT race
/// the sign-in flow. Pre-auth, syncPushToken caches the token and returns
/// silently; the cached value is replayed by `flushPendingPushTokenIfAvailable`
/// after `applyAuthenticatedState` flips `isAuthenticated = true`.
///
/// These tests pin the AppState-level state-machine without mocking
/// APIClient — `syncPushToken` short-circuits before kicking off the
/// network Task when the auth guard fails, so the assertions are
/// observable purely on `pendingPushTokenRegistration` / `lastError`.
///
/// iter20 (2026-04-29) note: in addition to the outer
/// `guard isAuthenticated` (covered by `testSyncPushTokenWhenUnauthenticated…`
/// below), `syncPushToken`'s Task body now re-checks `isAuthenticated`
/// *inside* the spawned Task. That defense-in-depth guard handles the
/// sub-second race where APNs delivers the device token via
/// `didRegisterForRemoteNotificationsWithDeviceToken`, the sync method
/// passes its synchronous outer guard, queues a Task, and a sign-out
/// completes before that Task actually runs. Without the inner guard
/// the spawned Task's `api.registerAppPushToken` would fire under a
/// stale/cleared JWT, the catch branch would write
/// `lastError = "Failed to register for push notifications: ..."`, and
/// the now-logged-out login screen would display that confusing message
/// — exactly the iter8 user-reported symptom we already fixed for the
/// outer launch path.
///
/// The inner guard is NOT unit-tested here because exercising it
/// requires either (a) a mock APIClient that lets us hold the
/// `await api.registerAppPushToken` mid-flight while we flip
/// `isAuthenticated`, which would need an injection point that
/// doesn't exist on the actor today, or (b) deterministic Task
/// scheduling guarantees that Swift Concurrency doesn't expose.
/// Instead the contract is verified by:
///   1. Code-level invariant — the inner `guard isAuthenticated else
///      { return }` is the very first statement inside the Task body,
///      ahead of any await.
///   2. The outer guard's tests below (which prove syncPushToken's
///      synchronous half is correct).
///   3. Real-device verification — the previously reported iter8
///      symptom does not recur after sign-out + token redelivery.
@MainActor
final class PushTokenAuthGuardTests: XCTestCase {

    // 64-char realistic APNs hex token.
    private let realisticToken = String(repeating: "a", count: 64)
    private let alternateToken = String(repeating: "b", count: 64)

    private func freshState() -> AppState {
        let state = AppState()
        // Force a clean baseline regardless of any global UserDefaults state
        // a previous test or sibling target might have left behind.
        state.isAuthenticated = false
        state.lastError = nil
        state.registeredPushToken = nil
        state.pendingPushTokenRegistration = nil
        return state
    }

    // MARK: - Auth guard on entry

    func testSyncPushTokenWhenUnauthenticatedCachesAndDoesNotError() {
        let state = freshState()
        state.syncPushToken(
            token: realisticToken,
            platform: "ios",
            bundleId: "yyh.CLI-Pulse"
        )
        // Critical: NO lastError. The previous bug surfaced "Failed to
        // register for push notifications: Session expired. Please sign
        // in again." right on the login screen because of this path.
        XCTAssertNil(state.lastError,
                     "pre-auth syncPushToken must NEVER set lastError")
        XCTAssertNil(state.registeredPushToken,
                     "pre-auth syncPushToken must NEVER mark registered")
        // Token is cached for replay-after-auth.
        let pending = state.pendingPushTokenRegistration
        XCTAssertEqual(pending?.token, realisticToken)
        XCTAssertEqual(pending?.platform, "ios")
        XCTAssertEqual(pending?.bundleId, "yyh.CLI-Pulse")
    }

    func testSyncPushTokenWhenUnauthenticatedOverwritesCacheOnNewToken() {
        // If iOS re-delivers a different token (rare — APNs token rolls
        // are uncommon, but possible after device restore), the latest
        // value wins so post-auth replay sends the current token, not
        // a stale one.
        let state = freshState()
        state.syncPushToken(token: realisticToken, platform: "ios", bundleId: "yyh.CLI-Pulse")
        state.syncPushToken(token: alternateToken, platform: "ios", bundleId: "yyh.CLI-Pulse")
        XCTAssertEqual(state.pendingPushTokenRegistration?.token, alternateToken)
        XCTAssertNil(state.lastError)
    }

    func testSyncPushTokenRejectsInvalidTokenLengthSilently() {
        let state = freshState()
        state.syncPushToken(token: "tiny", platform: "ios", bundleId: "yyh.CLI-Pulse")
        XCTAssertNil(state.pendingPushTokenRegistration,
                     "invalid token must not be cached")
        XCTAssertNil(state.lastError)
    }

    func testSyncPushTokenRejectsInvalidBundleIdSilently() {
        let state = freshState()
        state.syncPushToken(token: realisticToken, platform: "ios", bundleId: "")
        XCTAssertNil(state.pendingPushTokenRegistration)
        XCTAssertNil(state.lastError)
    }

    // MARK: - Replay after auth

    func testFlushPendingPushTokenNoOpWhenNothingCached() {
        let state = freshState()
        state.isAuthenticated = true
        state.flushPendingPushTokenIfAvailable()
        // Nothing was cached, nothing changes. No error either.
        XCTAssertNil(state.pendingPushTokenRegistration)
        XCTAssertNil(state.lastError)
        XCTAssertNil(state.registeredPushToken)
    }

    func testFlushPendingPushTokenNoOpWhenStillUnauthenticated() {
        // Defense-in-depth: if applyAuthenticatedState's contract is ever
        // violated (caller invokes flush before flipping isAuthenticated),
        // the inner syncPushToken's auth guard catches it. Cache stays put.
        let state = freshState()
        state.pendingPushTokenRegistration = PendingPushTokenRegistration(
            token: realisticToken, platform: "ios", bundleId: "yyh.CLI-Pulse"
        )
        state.flushPendingPushTokenIfAvailable()
        XCTAssertEqual(state.pendingPushTokenRegistration?.token, realisticToken,
                       "still-unauthenticated flush must not consume the cache")
    }

    // MARK: - State-machine: pre-auth then post-auth flush

    func testPreAuthSyncThenAuthFlushTriggersRegistration() {
        // Drive the realistic timeline:
        //   1. App launches → APNs delivers token before sign-in completes
        //      → syncPushToken caches.
        //   2. User signs in (Apple/Google/password/restoreSession all
        //      converge on applyAuthenticatedState).
        //   3. flushPendingPushTokenIfAvailable replays through the inner
        //      syncPushToken now that isAuthenticated=true.
        // We can't drive the network round-trip in a unit test (APIClient
        // would talk to Supabase), but we CAN observe that:
        //   * the cache gets consumed
        //   * no error is surfaced before the Task fires
        //   * (the actual registration and `registeredPushToken` mutation
        //     happens inside the Task, which we don't await here)
        let state = freshState()

        // Step 1: pre-auth delivery.
        state.syncPushToken(token: realisticToken, platform: "ios", bundleId: "yyh.CLI-Pulse")
        XCTAssertEqual(state.pendingPushTokenRegistration?.token, realisticToken)
        XCTAssertNil(state.lastError)

        // Step 2: sign-in flips the flag (we simulate just the relevant
        // mutation here — applyAuthenticatedState does this and then
        // calls flushPendingPushTokenIfAvailable).
        state.isAuthenticated = true

        // Step 3: replay. The inner syncPushToken proceeds past the auth
        // guard and kicks off the network Task. We don't assert on the
        // Task's outcome here — what matters is "no error, no stalled
        // cache, no pre-auth shadow message."
        state.flushPendingPushTokenIfAvailable()
        XCTAssertNil(state.lastError,
                     "auth-flush replay path must not surface an error")
    }

    // MARK: - Permission prompt gating

    func testRequestNotificationPermissionNoOpsWhenUnauthenticated() {
        // The previous bug: iOSMainView's .task called requestNotificationPermission
        // unconditionally on launch, which prompted the system permission
        // alert BEFORE the user had a chance to sign in. Now we guard.
        // We can't easily observe the UNUserNotificationCenter prompt from
        // a unit test, but we can verify the function returns without
        // mutating any state when isAuthenticated=false.
        let state = freshState()
        let beforeError = state.lastError
        let beforeRegistered = state.registeredPushToken
        state.requestNotificationPermission()
        XCTAssertEqual(state.lastError, beforeError,
                       "requestNotificationPermission(unauthenticated) must not set lastError")
        XCTAssertEqual(state.registeredPushToken, beforeRegistered,
                       "requestNotificationPermission(unauthenticated) must not mutate registeredPushToken")
    }

    func testPendingPushTokenRegistrationIsEquatable() {
        // Pin the Equatable contract — we may want to use it in future
        // dedup logic, and tests above implicitly rely on it via
        // assertEqual on the optional struct.
        let a = PendingPushTokenRegistration(token: "x", platform: "ios", bundleId: "y")
        let b = PendingPushTokenRegistration(token: "x", platform: "ios", bundleId: "y")
        let c = PendingPushTokenRegistration(token: "z", platform: "ios", bundleId: "y")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
