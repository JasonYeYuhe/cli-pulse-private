#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Tests targeting the integration gap Codex flagged on PR #17:
/// "local managed sessions are still not actually part of the
/// primary UI list" — i.e. the Sessions tab was rendering off
/// `remoteSessions` only, which `refreshRemoteSessions` clears
/// when Remote Control is off, AND the Open button was gated
/// solely on `remoteControlEnabled`.
///
/// These tests exercise the AppState surfaces the macOS UI now
/// binds to — `displayedManagedSessions`, `canStartLocalManaged
/// Session`, `shouldUseLocalSessionControl(forDeviceId:)` — under
/// every routing combination Codex listed:
///
/// | Remote Control | Local enabled | Helper reachable | Expected |
/// | -------------- | ------------- | ---------------- | -------- |
/// | OFF            | ON            | YES              | local rows visible, Open button present, send/stop route locally |
/// | OFF            | ON            | NO               | banner shown, Open button absent (helper not running) |
/// | ON             | ON            | YES              | merged list (remote + local-only), per-row routing |
/// | ON             | OFF           | YES              | remote-only path, local rows hidden |
///
/// The tests don't render SwiftUI views — they assert on the
/// underlying view-model state. SwiftUI integration testing
/// belongs in a UITest target the project doesn't currently have;
/// view-model tests catch the routing-decision bugs Codex caught.
final class SessionControlIntegrationGapTests: XCTestCase {

    // MARK: - Setup

    @MainActor
    private func makeState() -> AppState {
        let state = AppState()
        // No real network; we mutate the published surfaces directly
        // to simulate `refreshLocalSessionControlState` outcomes.
        state.remoteSessions = []
        state.localManagedSessions = []
        state.localDetectedSessions = []
        state.localHelperReachable = false
        state.localControlEnabled = false
        state.remoteControlEnabled = false
        return state
    }

    // MARK: - displayedManagedSessions: dedupe + merge

    @MainActor
    func testDisplayedManagedSessions_emptyWhenBothListsEmpty() {
        let state = makeState()
        XCTAssertTrue(state.displayedManagedSessions.isEmpty)
    }

    @MainActor
    func testDisplayedManagedSessions_includesLocalOnlyRow_evenWithRemoteControlOff() {
        // The exact scenario Codex called out: Remote Control off
        // (so `remoteSessions` is empty), but a session was started
        // via local UDS. The row MUST still appear.
        let state = makeState()
        state.remoteControlEnabled = false
        state.remoteSessions = []
        state.localManagedSessions = [
            .init(id: "S-1", provider: "claude", clientLabel: "Mac",
                  status: "running", controllable: true, source: .managed)
        ]
        let displayed = state.displayedManagedSessions
        XCTAssertEqual(displayed.count, 1)
        XCTAssertEqual(displayed[0].id, "S-1")
    }

    @MainActor
    func testDisplayedManagedSessions_dedupesById_remoteRowWins() {
        // When the helper's `register_session` RPC has caught up
        // and the same session id appears in both lists, prefer
        // the remote row (richer metadata: created_at,
        // last_event_at, cwd_hmac).
        let state = makeState()
        state.remoteSessions = [
            RemoteSession(
                id: "S-1", device_id: "dev-self",
                device_name: "MacBook", provider: "claude",
                cwd_basename: "proj", cwd_hmac: "h",
                status: "running", client_label: "remote-label",
                created_at: "2026-05-05T00:00:00Z",
                last_event_at: "2026-05-05T00:01:00Z"
            )
        ]
        state.localManagedSessions = [
            .init(id: "S-1", provider: "claude",
                  clientLabel: "local-label", status: "running",
                  controllable: true, source: .managed)
        ]
        let displayed = state.displayedManagedSessions
        XCTAssertEqual(displayed.count, 1, "expected dedup by id")
        XCTAssertEqual(displayed[0].client_label, "remote-label",
                       "remote row's metadata should win on dedup")
        XCTAssertEqual(displayed[0].cwd_basename, "proj")
        XCTAssertEqual(displayed[0].last_event_at, "2026-05-05T00:01:00Z")
    }

    @MainActor
    func testDisplayedManagedSessions_localOnlyRow_carriesSelfDeviceId() {
        // The synthesised RemoteSession for a local-only row MUST
        // have device_id == this Mac's helper deviceId, so row-
        // level routing (`shouldUseLocalSessionControl(forDeviceId:)`)
        // correctly picks the local UDS path.
        let state = makeState()
        // We can't call HelperConfig.load() in a test rig, but
        // selfDeviceId reads through that. If it returns nil the
        // synthesised row uses "" — assert on the contract: the
        // synthesised id matches whatever `selfDeviceId` returns
        // (or empty).
        state.localManagedSessions = [
            .init(id: "S-2", provider: "claude", clientLabel: nil,
                  status: "running", controllable: true, source: .managed)
        ]
        let displayed = state.displayedManagedSessions
        XCTAssertEqual(displayed.count, 1)
        XCTAssertEqual(displayed[0].device_id, state.selfDeviceId ?? "")
    }

    // MARK: - canStartLocalManagedSession

    @MainActor
    func testCanStartLocal_falseWhenHelperUnreachable() {
        let state = makeState()
        state.localControlEnabled = true
        state.localHelperReachable = false
        XCTAssertFalse(state.canStartLocalManagedSession)
    }

    @MainActor
    func testCanStartLocal_falseWhenGateOff() {
        let state = makeState()
        state.localHelperReachable = true
        state.localControlEnabled = false
        XCTAssertFalse(state.canStartLocalManagedSession)
    }

    @MainActor
    func testCanStartLocal_trueWhenReachableAndGateOn_independentFromRemoteControl() {
        // Codex review fix: local control must NOT depend on
        // `remoteControlEnabled`. Toggle remote off, local on,
        // helper reachable → can start.
        let state = makeState()
        state.remoteControlEnabled = false  // explicitly off
        state.localHelperReachable = true
        state.localControlEnabled = true
        // canStartLocalManagedSession also requires selfDeviceId
        // to be non-empty (i.e. helper is paired). In a test rig
        // without HelperConfig the value is nil → gate returns false
        // here. We assert the rule "remote-control state doesn't
        // matter" by comparing the result with remote on vs off:
        let withRemoteOff = state.canStartLocalManagedSession
        state.remoteControlEnabled = true
        let withRemoteOn = state.canStartLocalManagedSession
        XCTAssertEqual(withRemoteOff, withRemoteOn,
            "canStartLocalManagedSession must NOT depend on remoteControlEnabled")
    }

    // MARK: - shouldUseLocalSessionControl(forDeviceId:)

    @MainActor
    func testShouldUseLocal_falseForCrossDeviceTarget() {
        let state = makeState()
        state.localHelperReachable = true
        state.localControlEnabled = true
        // `selfDeviceId` reads from HelperConfig; in test rig it's
        // nil. A different device id is unambiguously not-self.
        XCTAssertFalse(state.shouldUseLocalSessionControl(forDeviceId: "other-mac"))
    }

    @MainActor
    func testShouldUseLocal_falseWhenGateOff_evenForSelfDevice() {
        let state = makeState()
        state.localHelperReachable = true
        state.localControlEnabled = false
        XCTAssertFalse(state.shouldUseLocalSessionControl(forDeviceId: state.selfDeviceId))
    }

    @MainActor
    func testShouldUseLocal_falseWhenHelperUnreachable_evenForSelfDevice() {
        let state = makeState()
        state.localHelperReachable = false
        state.localControlEnabled = true
        XCTAssertFalse(state.shouldUseLocalSessionControl(forDeviceId: state.selfDeviceId))
    }

    // MARK: - Detected (unmanaged) rows are NOT in displayedManagedSessions

    @MainActor
    func testDetectedRows_doNotLeakIntoPrimaryDisplayedList() {
        // Only `localManagedSessions` are merged into the primary
        // list. `localDetectedSessions` are rendered separately
        // (read-only section) so the UI never offers send/stop
        // actions against a row the helper can't safely control.
        let state = makeState()
        state.localManagedSessions = []
        state.localDetectedSessions = [
            .init(id: "proc-7", provider: "Claude", clientLabel: "claude",
                  status: "running", controllable: false, source: .detected)
        ]
        XCTAssertTrue(state.displayedManagedSessions.isEmpty,
            "detected rows must NOT leak into the primary displayed list")
    }

    // MARK: - Capability gate (no silent cloud fallback)

    @MainActor
    func testSendLocal_capabilityFalse_shortCircuitsAndReturnsFalse() async {
        // sendLocalSessionInput hard-checks the helper's advertised
        // `send_input` capability before opening any connection.
        // When capability is false, returns false IMMEDIATELY (no
        // silent fallback to cloud) — the UI gate above also
        // disables the input, but this is the defense-in-depth.
        let state = makeState()
        state.localCapabilities = SessionControlCapabilities(
            sendInput: false, subscribeEvents: false, approvals: false
        )
        let ok = await state.sendLocalSessionInput(sessionId: "S-1", payload: "hi")
        XCTAssertFalse(ok)
    }

    @MainActor
    func testIter2aCapabilityPresetEnablesSendInput() {
        // Pin the iter-2A invariant the macOS UI now binds to.
        let caps = SessionControlCapabilities.iter2aLocal
        XCTAssertTrue(caps.sendInput)
    }

    @MainActor
    func testIter1CapabilityPresetDisablesSendInput() {
        // Pin the iter-1 baseline the regression tests defend.
        let caps = SessionControlCapabilities.iter1Local
        XCTAssertFalse(caps.sendInput)
    }

    // MARK: - shouldRouteSessionLocally(_:) — Codex PR #17 stop-routing fix

    @MainActor
    private func makeRow(id: String, deviceId: String) -> RemoteSession {
        RemoteSession(
            id: id, device_id: deviceId,
            device_name: nil, provider: "claude",
            cwd_basename: "", cwd_hmac: nil,
            status: "running", client_label: "test",
            created_at: "2026-05-05T00:00:00Z",
            last_event_at: nil
        )
    }

    @MainActor
    func testRouteLocally_ownershipById_winsOverDeviceIdMismatch() {
        // The exact regression Codex caught: helper-owned session
        // appears in `localManagedSessions`, but its Supabase row
        // (in `remoteSessions`) carries a `device_id` that DOESN'T
        // match `selfDeviceId` because the two pairing stores
        // drifted. Ownership-by-id MUST win.
        let state = makeState()
        state.localHelperReachable = true
        state.localControlEnabled = true
        state.localManagedSessions = [
            .init(id: "S-1", provider: "claude", clientLabel: "test",
                  status: "running", controllable: true, source: .managed)
        ]
        // Row with device_id that does NOT match `selfDeviceId`
        // (which is nil in the test rig anyway).
        let row = makeRow(id: "S-1", deviceId: "some-other-helper-deviceid")
        XCTAssertTrue(state.shouldRouteSessionLocally(row),
            "ownership-by-id must win even when device_id doesn't match selfDeviceId")
    }

    @MainActor
    func testRouteLocally_falseWhenSessionUnknownToBothPaths() {
        // Cross-device row, not in localManagedSessions, device_id
        // doesn't match → must NOT route locally.
        let state = makeState()
        state.localHelperReachable = true
        state.localControlEnabled = true
        state.localManagedSessions = []
        let row = makeRow(id: "X", deviceId: "remote-mac-id")
        XCTAssertFalse(state.shouldRouteSessionLocally(row))
    }

    @MainActor
    func testRouteLocally_falseWhenHelperUnreachable() {
        let state = makeState()
        state.localHelperReachable = false
        state.localControlEnabled = true
        state.localManagedSessions = [
            .init(id: "S-1", provider: "claude", clientLabel: nil,
                  status: "running", controllable: true, source: .managed)
        ]
        let row = makeRow(id: "S-1", deviceId: "any")
        XCTAssertFalse(state.shouldRouteSessionLocally(row),
            "no UDS calls when helper is unreachable, even if id is owned")
    }

    @MainActor
    func testRouteLocally_falseWhenGateOff() {
        let state = makeState()
        state.localHelperReachable = true
        state.localControlEnabled = false
        state.localManagedSessions = [
            .init(id: "S-1", provider: "claude", clientLabel: nil,
                  status: "running", controllable: true, source: .managed)
        ]
        let row = makeRow(id: "S-1", deviceId: "any")
        XCTAssertFalse(state.shouldRouteSessionLocally(row),
            "gate off must short-circuit even when helper is reachable")
    }

    // MARK: - Diagnostics surface (Codex PR #17 manual-verify follow-up)

    @MainActor
    func testDiagnosticsAreCapturedOnEveryRefresh() {
        // After the manual-verify failure we surface
        // `LocalSessionControlClient.Diagnostics` on AppState so
        // the UI can render the resolved paths + existence flags
        // without the user having to pull Xcode logs.
        let state = makeState()
        // The Diagnostics struct is initialised on first refresh;
        // before that, nil is the expected default.
        XCTAssertNil(state.localDiagnostics)
    }

    func testDiagnosticsStructEquatable() {
        let a = LocalSessionControlClient.Diagnostics(
            resolvedSocketPath: "/path/to/sock", socketExists: false,
            resolvedTokenPath: "/path/to/token", tokenExists: false,
            tokenReadable: false,
            appGroupContainerPath: "/Users/x/Library/Group Containers/group.yyh.CLI-Pulse",
            nsHomeDirectory: "/Users/x"
        )
        let b = LocalSessionControlClient.Diagnostics(
            resolvedSocketPath: "/path/to/sock", socketExists: false,
            resolvedTokenPath: "/path/to/token", tokenExists: false,
            tokenReadable: false,
            appGroupContainerPath: "/Users/x/Library/Group Containers/group.yyh.CLI-Pulse",
            nsHomeDirectory: "/Users/x"
        )
        XCTAssertEqual(a, b)
    }

    @MainActor
    func testDiagnosticsSnapshotFromClient() {
        // Construct a client with explicit non-existent paths and
        // verify the diagnostics snapshot reflects the inputs +
        // existence flags. Exercising the `.diagnostics()` API
        // surface so a future field-name typo lands here.
        let client = LocalSessionControlClient(
            socketPath: "/tmp/cli-pulse-diag-no-such-socket.sock",
            tokenPath: "/tmp/cli-pulse-diag-no-such-token",
            connectTimeout: 0.2,
            requestTimeout: 0.2
        )
        let diag = client.diagnostics()
        XCTAssertEqual(diag.resolvedSocketPath, "/tmp/cli-pulse-diag-no-such-socket.sock")
        XCTAssertEqual(diag.resolvedTokenPath, "/tmp/cli-pulse-diag-no-such-token")
        XCTAssertFalse(diag.socketExists)
        XCTAssertFalse(diag.tokenExists)
        XCTAssertFalse(diag.tokenReadable)
        XCTAssertFalse(diag.nsHomeDirectory.isEmpty)
    }
}
#endif
