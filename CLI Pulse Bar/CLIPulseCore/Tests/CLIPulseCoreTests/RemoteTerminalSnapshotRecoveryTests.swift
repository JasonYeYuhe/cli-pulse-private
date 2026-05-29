#if os(iOS) || os(visionOS)
import XCTest
@testable import CLIPulseCore

/// v1.26 Phase B2 — fetchTailSnapshot / subscribe-first-buffer.
/// Tests for the Coordinator's foreground-recovery state machine.
///
/// The Coordinator is unit-testable in isolation: its init creates
/// only a `RemoteSessionEventStream` (no WKWebView, no UIView). We
/// drive `routeChunk(_:into:)` directly with a nil view to exercise
/// the buffer/drain logic without opening a real WebSocket.
final class RemoteTerminalSnapshotRecoveryTests: XCTestCase {

    typealias C = RemoteTerminalViewRepresentable.Coordinator

    // Dummy stream config — never used because we never call subscribe.
    private static let streamConfig = RemoteSessionEventStream.Configuration(
        supabaseURL: "https://test.local",
        supabaseAnonKey: "anon"
    )

    // MARK: - constants

    func test_snapshotTimeout_2s_matchesPlan() {
        XCTAssertEqual(C.snapshotTimeoutSeconds, 2.0, accuracy: 0.001)
    }

    func test_snapshotMaxBytes_8192_matchesHelperDefault() {
        // Helper-side `decodeTailSnapshotPayload("")` defaults to
        // 8192; align the iOS request so payload omission and
        // explicit "8192" produce identical helper behavior.
        XCTAssertEqual(C.snapshotMaxBytes, 8192)
    }

    func test_snapshotEventName_isTailSnapshotResult() {
        // Pinned helper-side AND iOS-side. If this drifts, recovery
        // silently fails — iOS receives the snapshot but routes it
        // through the live-write path instead of the drain path.
        XCTAssertEqual(C.snapshotEventName, "tail_snapshot_result")
    }

    // MARK: - cold-start (no prior chunks)

    /// Brand-new session: no `lastChunkedSessionId` set, no snapshot
    /// callback fires — there's nothing to recover. Direct-write
    /// from the first chunk forward.
    func test_coldStart_skipsSnapshotRPC() {
        var requested: (String, Int)? = nil
        let c = C(
            sessionId: "sess-cold",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { sid, n in requested = (sid, n) }
        )
        XCTAssertNil(c.pendingSnapshotBuffer)
        // Simulate the first chunk arriving (as if subscribeIfNeeded
        // had been called and the WS started delivering).
        c.routeChunk(.init(event: "stdout", data: Data("hello\n".utf8)), into: nil)
        XCTAssertNil(c.pendingSnapshotBuffer,
                     "cold subscribe stays in direct-write mode")
        XCTAssertNil(requested,
                     "no snapshot RPC should fire on cold path")
    }

    /// First chunk for a session promotes us to "warm" — the NEXT
    /// resubscribe (background→foreground or auto-reconnect) should
    /// fire a snapshot request.
    func test_firstChunk_setsLastChunkedSessionId() {
        let c = C(
            sessionId: "sess-warm",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in }
        )
        c.routeChunk(.init(event: "stdout", data: Data("hi".utf8)), into: nil)
        XCTAssertEqual(c.lastChunkedSessionId, "sess-warm")
    }

    // MARK: - buffer / drain state machine

    /// Once `pendingSnapshotBuffer` is non-nil, live chunks
    /// accumulate in arrival order without touching the view.
    /// Then the `tail_snapshot_result` event arrives: snapshot is
    /// written FIRST, then buffered chunks in order, then the
    /// buffer is nil'd (direct-write mode resumed).
    func test_snapshotResult_drains_snapshot_then_buffer_in_order() {
        let c = C(
            sessionId: "sess-1",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in }
        )
        // Manually enter "warm-subscribe pending" state. (In
        // production this happens inside subscribeIfNeeded before
        // the WS comes up; we skip the WS hop here.)
        c.pendingSnapshotBuffer = []

        // Two live chunks arrive while we're waiting for the snapshot.
        c.routeChunk(.init(event: "stdout", data: Data("LIVE-1".utf8)), into: nil)
        c.routeChunk(.init(event: "stdout", data: Data("LIVE-2".utf8)), into: nil)

        // Buffer should have both chunks, view untouched.
        XCTAssertEqual(c.pendingSnapshotBuffer?.count, 2)
        XCTAssertEqual(c.pendingSnapshotBuffer?[0], Data("LIVE-1".utf8))
        XCTAssertEqual(c.pendingSnapshotBuffer?[1], Data("LIVE-2".utf8))

        // Snapshot arrives. routeChunk should drain and switch
        // back to direct-write mode.
        c.routeChunk(.init(event: C.snapshotEventName, data: Data("SNAP".utf8)), into: nil)
        XCTAssertNil(c.pendingSnapshotBuffer,
                     "after snapshot result, buffer is nil (direct-write mode)")
    }

    /// Snapshot arriving with EMPTY buffer (no live chunks
    /// interleaved) still flips out of buffer mode and routes the
    /// snapshot to the view.
    func test_snapshotResult_withEmptyBuffer_stillDrains() {
        let c = C(
            sessionId: "sess-2",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in }
        )
        c.pendingSnapshotBuffer = []
        c.routeChunk(.init(event: C.snapshotEventName, data: Data("ONLY".utf8)), into: nil)
        XCTAssertNil(c.pendingSnapshotBuffer)
    }

    /// `drainBufferAndSwitchToDirectWrite(snapshot: nil, ...)` is the
    /// 2 s timeout path: no snapshot, but drain whatever live chunks
    /// accumulated and flip back to direct-write. User sees the
    /// chunks unprefixed (same UX as the v1.25 baseline).
    func test_drainOnTimeout_flushesBufferWithoutSnapshot() {
        let c = C(
            sessionId: "sess-3",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in }
        )
        c.pendingSnapshotBuffer = []
        c.routeChunk(.init(event: "stdout", data: Data("X".utf8)), into: nil)
        c.routeChunk(.init(event: "stdout", data: Data("Y".utf8)), into: nil)
        XCTAssertEqual(c.pendingSnapshotBuffer?.count, 2)

        c.drainBufferAndSwitchToDirectWrite(snapshot: nil, into: nil)
        XCTAssertNil(c.pendingSnapshotBuffer)
    }

    /// Post-drain, live chunks go direct-write again (no buffer).
    func test_postDrain_chunksGoDirectWrite() {
        let c = C(
            sessionId: "sess-4",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in }
        )
        c.pendingSnapshotBuffer = []
        c.drainBufferAndSwitchToDirectWrite(snapshot: nil, into: nil)
        // Direct-write mode: a chunk should NOT recreate the buffer.
        c.routeChunk(.init(event: "stdout", data: Data("post".utf8)), into: nil)
        XCTAssertNil(c.pendingSnapshotBuffer)
    }

    // MARK: - v1.26.1 telemetry: snapshot outcome emission

    /// A snapshot arriving in-window emits `.recovered` with the
    /// count of live chunks that were buffered during the wait.
    func test_recovery_emitsRecoveredOutcome_withBufferedCount() {
        var outcomes: [C.SnapshotOutcome] = []
        let c = C(
            sessionId: "sess-tel-1",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in },
            onSnapshotOutcome: { outcomes.append($0) }
        )
        c.pendingSnapshotBuffer = []
        c.routeChunk(.init(event: "stdout", data: Data("A".utf8)), into: nil)
        c.routeChunk(.init(event: "stdout", data: Data("B".utf8)), into: nil)
        c.routeChunk(.init(event: C.snapshotEventName, data: Data("SNAP".utf8)), into: nil)
        XCTAssertEqual(outcomes, [.recovered(bufferedChunks: 2)])
    }

    /// Timeout resolution emits `.timedOut` with the buffered count.
    func test_timeout_emitsTimedOutOutcome_withBufferedCount() {
        var outcomes: [C.SnapshotOutcome] = []
        let c = C(
            sessionId: "sess-tel-2",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in },
            onSnapshotOutcome: { outcomes.append($0) }
        )
        c.pendingSnapshotBuffer = []
        c.routeChunk(.init(event: "stdout", data: Data("X".utf8)), into: nil)
        c.resolveSnapshotTimeout()
        XCTAssertEqual(outcomes, [.timedOut(bufferedChunks: 1)])
    }

    /// A timeout that fires AFTER the snapshot already drained the
    /// buffer must NOT emit a second outcome (no double-report).
    func test_timeoutAfterRecovery_doesNotDoubleReport() {
        var outcomes: [C.SnapshotOutcome] = []
        let c = C(
            sessionId: "sess-tel-3",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in },
            onSnapshotOutcome: { outcomes.append($0) }
        )
        c.pendingSnapshotBuffer = []
        c.routeChunk(.init(event: C.snapshotEventName, data: Data("SNAP".utf8)), into: nil)
        XCTAssertEqual(outcomes, [.recovered(bufferedChunks: 0)])
        // Late timeout fires — buffer already nil, must be a no-op.
        c.resolveSnapshotTimeout()
        XCTAssertEqual(outcomes, [.recovered(bufferedChunks: 0)], "timeout after recovery must not double-report")
    }

    /// Cold start (no warm subscribe) never emits an outcome — there
    /// was nothing to recover.
    func test_coldStart_emitsNoOutcome() {
        var outcomes: [C.SnapshotOutcome] = []
        let c = C(
            sessionId: "sess-tel-4",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in },
            onSnapshotOutcome: { outcomes.append($0) }
        )
        // No pendingSnapshotBuffer seeded; direct-write from first chunk.
        c.routeChunk(.init(event: "stdout", data: Data("hi".utf8)), into: nil)
        XCTAssertTrue(outcomes.isEmpty)
    }

    // MARK: - Codex hotfix: late snapshot drop

    /// Codex MEDIUM (v1.26.0 hotfix): a `tail_snapshot_result` that
    /// arrives AFTER the 2 s timeout has already fired must be
    /// dropped — by that point direct-write has been emitting
    /// newer live chunks for some non-zero duration, and writing
    /// the stale snapshot now would inject older content AFTER
    /// newer output (visible reorder / duplication).
    func test_lateSnapshot_afterTimeout_isDropped() {
        let c = C(
            sessionId: "sess-late",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in }
        )
        // Simulate: warm subscribe primed the buffer; timeout fired
        // → buffer drained to nil; live chunks have started direct-
        // writing.
        c.pendingSnapshotBuffer = []
        c.drainBufferAndSwitchToDirectWrite(snapshot: nil, into: nil)
        XCTAssertNil(c.pendingSnapshotBuffer)

        // Live chunk arrives after timeout (normal direct-write).
        c.routeChunk(.init(event: "stdout", data: Data("LIVE-after-timeout".utf8)), into: nil)

        // Now the stale snapshot finally arrives. Must be DROPPED —
        // not drained into the view (would visibly reorder).
        c.routeChunk(.init(event: C.snapshotEventName, data: Data("STALE-snap".utf8)), into: nil)
        XCTAssertNil(c.pendingSnapshotBuffer,
                     "late snapshot must not revive the buffer or change mode")

        // Subsequent live chunk still direct-writes (no buffer revival).
        c.routeChunk(.init(event: "stdout", data: Data("more-live".utf8)), into: nil)
        XCTAssertNil(c.pendingSnapshotBuffer)
    }

    /// A snapshot that arrives while buffer IS still pending (the
    /// happy path) is unaffected — drain proceeds as designed.
    func test_snapshot_arrivingDuringPendingBuffer_drainsNormally() {
        let c = C(
            sessionId: "sess-on-time",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in }
        )
        c.pendingSnapshotBuffer = []
        c.routeChunk(.init(event: "stdout", data: Data("LIVE-1".utf8)), into: nil)
        c.routeChunk(.init(event: C.snapshotEventName, data: Data("SNAP".utf8)), into: nil)
        XCTAssertNil(c.pendingSnapshotBuffer)
    }

    // MARK: - cancel / pause cleanup

    func test_cancel_clearsPendingSnapshotState() {
        let c = C(
            sessionId: "sess-5",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in }
        )
        c.pendingSnapshotBuffer = []
        c.cancel()
        XCTAssertNil(c.pendingSnapshotBuffer,
                     "cancel must clear pending buffer so a stale timeout can't fire")
    }

    func test_pause_clearsPendingSnapshotState() {
        let c = C(
            sessionId: "sess-6",
            streamConfig: Self.streamConfig,
            onDisconnect: nil,
            onRequestTailSnapshot: { _, _ in }
        )
        c.pendingSnapshotBuffer = []
        c.pause()
        XCTAssertNil(c.pendingSnapshotBuffer,
                     "pause must clear pending buffer; resume issues a fresh snapshot request")
    }
}
#endif
