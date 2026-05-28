// v1.25 Phase 4 — SwiftUI wrapper around `RemoteTerminalView`.
// Drops into the iOS Sessions detail view; subscribes to the
// session's Realtime broadcast channel on appear, tears down on
// disappear.
//
// Slice 1: read-only display.
// Slice 2: interactive keystrokes + resize wired through.
// Slice 3: soft-keyboard helper bar (in `RemoteTerminalKeyBar`).
// Slice 4 (THIS FILE'S latest revision): lifecycle + reconnect:
//   * scenePhase background → disconnect WS + freeze view
//     (Gemini HIGH §4e: avoid WebKit OOM on JS resume-burst).
//   * scenePhase active → resubscribe.
//   * Auto-reconnect on unexpected WS disconnect with jittered
//     exponential backoff, max ~10 s (Codex M1).
//   * reconnect counter resets on every successful chunk —
//     a healthy connection clears the backoff.

#if os(iOS) || os(visionOS)
import SwiftUI
import UIKit

/// UIViewRepresentable that hosts an xterm.js terminal viewport
/// inside SwiftUI. Owns a `RemoteSessionEventStream` subscription
/// keyed by `sessionId`; output chunks land on the embedded
/// `RemoteTerminalView`'s coalescer and render in the WebView.
public struct RemoteTerminalViewRepresentable: UIViewRepresentable {

    public let sessionId: String
    public let streamConfig: RemoteSessionEventStream.Configuration
    /// v1.25 Phase 4 slice 4: drive lifecycle from the host's
    /// `@Environment(\.scenePhase)`. When this flips to `.background`
    /// the Coordinator disconnects the WS; when it flips back to
    /// `.active` the Coordinator resubscribes (no replay — accept
    /// the gap; `fetchTailSnapshot` lands in a future train).
    public let scenePhase: ScenePhase
    /// Caller-supplied callback fired when the WS subscription
    /// ends (any error, peer close, or `coordinator.cancel()`).
    /// Optional — most callers don't need to react.
    public let onDisconnect: ((Error?) -> Void)?
    /// v1.25 Phase 4 slice 2: caller-supplied keystroke forwarder.
    /// Fired once per xterm.js `onData` event with raw UTF-8 bytes
    /// (control sequences encoded inline). Typically wired to
    /// `RemoteSessionControlClient.sendInputRaw`.
    public let onStdin: ((Data) -> Void)?
    /// v1.25 Phase 4 slice 2: caller-supplied viewport-resize
    /// forwarder. Typically wired to `RemoteSessionControlClient.resize`.
    public let onResize: ((Int, Int) -> Void)?
    /// v1.26 Phase B2: caller-supplied snapshot-request forwarder.
    /// Fired on a **warm** subscribe (resubscribe after we've seen
    /// chunks for this session before — e.g. background→foreground
    /// or auto-reconnect). Typically wired to
    /// `state.requestRemoteSessionTailSnapshot(...)` →
    /// APIClient `remote_app_send_command(.tail_snapshot)`.
    /// Fire-and-forget; the Coordinator times out at 2 s and
    /// drains the pending buffer without a recovery prefix if no
    /// `tail_snapshot_result` broadcast arrives.
    public let onRequestTailSnapshot: ((String, Int) -> Void)?

    public init(
        sessionId: String,
        streamConfig: RemoteSessionEventStream.Configuration,
        scenePhase: ScenePhase = .active,
        onDisconnect: ((Error?) -> Void)? = nil,
        onStdin: ((Data) -> Void)? = nil,
        onResize: ((Int, Int) -> Void)? = nil,
        onRequestTailSnapshot: ((String, Int) -> Void)? = nil
    ) {
        self.sessionId = sessionId
        self.streamConfig = streamConfig
        self.scenePhase = scenePhase
        self.onDisconnect = onDisconnect
        self.onStdin = onStdin
        self.onResize = onResize
        self.onRequestTailSnapshot = onRequestTailSnapshot
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionId: sessionId,
            streamConfig: streamConfig,
            onDisconnect: onDisconnect,
            onStdin: onStdin,
            onResize: onResize,
            onRequestTailSnapshot: onRequestTailSnapshot
        )
    }

    public func makeUIView(context: Context) -> RemoteTerminalView {
        let view = RemoteTerminalView(frame: .zero)
        view.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.applyScenePhase(scenePhase)
        context.coordinator.subscribeIfNeeded()
        return view
    }

    public func updateUIView(_ uiView: RemoteTerminalView, context: Context) {
        // Session id change → cancel-before-replace. Codex M1 guard
        // against rapid-switch channel thrash.
        if context.coordinator.activeSessionId != sessionId {
            context.coordinator.cancel()
            context.coordinator.sessionId = sessionId
            uiView.clear()
            context.coordinator.subscribeIfNeeded()
        }
        // scenePhase reconciliation — fires every time the host's
        // @Environment(\.scenePhase) value changes (background ↔
        // active). Coordinator pauses / resumes the WS accordingly.
        context.coordinator.applyScenePhase(scenePhase)
    }

    public static func dismantleUIView(
        _ uiView: RemoteTerminalView, coordinator: Coordinator
    ) {
        coordinator.cancel()
    }

    /// Coordinator owns the live `RemoteSessionEventStream`
    /// subscription + the reconnect state machine.
    ///
    /// State transitions:
    /// ```
    /// initial ── subscribeIfNeeded ──→ active
    /// active ── onChunk ──→ active (reconnectAttempt = 0)
    /// active ── onDisconnect ──→ reconnecting (scheduleReconnect)
    /// reconnecting ── timer fires ──→ active (subscribeIfNeeded)
    /// active|reconnecting ── pause ──→ paused
    /// paused ── resume ──→ active (subscribeIfNeeded)
    /// any ── cancel ──→ cancelled (terminal; reconnect cancelled)
    /// ```
    public final class Coordinator: NSObject, RemoteTerminalViewDelegate {

        var sessionId: String
        let streamConfig: RemoteSessionEventStream.Configuration
        let onDisconnect: ((Error?) -> Void)?
        let onStdin: ((Data) -> Void)?
        let onResize: ((Int, Int) -> Void)?
        /// v1.26 B2: when set, the Coordinator calls this with
        /// `(sessionId, maxBytes)` on a **warm** subscribe (i.e. a
        /// resubscribe after we've seen chunks for this session
        /// before). The host wires this to
        /// `state.requestRemoteSessionTailSnapshot(...)` →
        /// APIClient `remote_app_send_command(.tail_snapshot)`.
        /// Helper publishes the snapshot via the same Realtime
        /// channel as live stdout (event `tail_snapshot_result`).
        /// Fire-and-forget — failures are surfaced via the 2 s
        /// timeout (drain pending buffer, proceed without prefix).
        let onRequestTailSnapshot: ((String, Int) -> Void)?
        weak var view: RemoteTerminalView?

        /// Tracks the session id the active subscription is bound
        /// to. Diverges from `sessionId` momentarily when the
        /// session changes; `updateUIView` calls
        /// `subscribeIfNeeded` to reconcile.
        private(set) var activeSessionId: String?
        private var cancellable: RemoteSessionEventStream.Cancellable?
        private let stream: RemoteSessionEventStream

        /// v1.25 Phase 4 slice 4: lifecycle + reconnect state.
        private(set) var isPaused: Bool = false
        private(set) var isCancelled: Bool = false
        private(set) var reconnectAttempt: Int = 0
        private var reconnectTask: Task<Void, Never>?

        /// v1.26 B2: foreground-recovery state machine.
        /// `nil` = direct-write mode; non-`nil` = buffer live
        /// chunks while we wait for `tail_snapshot_result`. When
        /// the snapshot arrives (or the 2 s timeout fires) we
        /// drain the buffer into the terminal and revert to
        /// direct-write.
        ///
        /// Mutated only by `subscribeIfNeeded`, `routeChunk`, and
        /// `drainBufferAndSwitchToDirectWrite`. The non-`private`
        /// setter is a test seam (state-machine cases are easier to
        /// seed than to drive through a live WS); production code
        /// must go through those methods.
        var pendingSnapshotBuffer: [Data]?
        private var snapshotTimeoutTask: Task<Void, Never>?
        /// Session id we've seen at least one chunk for. Drives
        /// the cold/warm subscribe distinction: cold subscribes
        /// (no prior chunks for `sessionId`) skip the snapshot
        /// request entirely — nothing to recover. Same test-seam
        /// posture as `pendingSnapshotBuffer`.
        var lastChunkedSessionId: String?
        /// Snapshot request timeout (Plan §B2). 2 s — long enough
        /// for the round-trip through Postgres → helper → Realtime
        /// → WS in normal conditions, short enough that the user
        /// doesn't notice a wedge if the snapshot never arrives.
        public static let snapshotTimeoutSeconds: TimeInterval = 2.0
        /// Snapshot maxBytes the iOS side asks for. Matches the
        /// helper-side parser's default (`decodeTailSnapshotPayload`
        /// defaults to 8192 on empty payload too).
        public static let snapshotMaxBytes: Int = 8192
        /// v1.26 B2: routing event name the helper publishes
        /// snapshots under. Pinned here + helper-side so a typo
        /// can't silently break recovery.
        public static let snapshotEventName: String = "tail_snapshot_result"

        init(
            sessionId: String,
            streamConfig: RemoteSessionEventStream.Configuration,
            onDisconnect: ((Error?) -> Void)?,
            onStdin: ((Data) -> Void)? = nil,
            onResize: ((Int, Int) -> Void)? = nil,
            onRequestTailSnapshot: ((String, Int) -> Void)? = nil
        ) {
            self.sessionId = sessionId
            self.streamConfig = streamConfig
            self.onDisconnect = onDisconnect
            self.onStdin = onStdin
            self.onResize = onResize
            self.onRequestTailSnapshot = onRequestTailSnapshot
            self.stream = RemoteSessionEventStream(config: streamConfig)
            super.init()
        }

        deinit {
            reconnectTask?.cancel()
            cancellable?.cancel()
        }

        func subscribeIfNeeded() {
            if isPaused || isCancelled { return }
            if activeSessionId == sessionId, cancellable != nil { return }

            // v1.26 B2: warm-subscribe detection. If we've already
            // seen at least one chunk for this exact sessionId, the
            // resubscribe is filling a known gap (background-resume
            // or WS reconnect) — request a snapshot and buffer
            // incoming chunks until it arrives. A cold subscribe
            // (no prior chunks) skips the RPC entirely, since
            // there's no history to recover.
            //
            // Codex/Gemini B2 race fix: subscribe FIRST and start
            // buffering BEFORE we fire the RPC, so any chunks the
            // helper emits between snapshot-read and our subscribe
            // hitting the broadcast topic are captured (the naïve
            // "request → await → subscribe" order would lose
            // those).
            let isWarmSubscribe =
                lastChunkedSessionId == sessionId
                && onRequestTailSnapshot != nil
            if isWarmSubscribe {
                pendingSnapshotBuffer = []
            }

            let sid = sessionId
            let weakView = view  // captured by handlers
            let userDisconnectCB = onDisconnect
            cancellable = stream.subscribeTerminal(
                sessionId: sid,
                onChunk: { [weak self] chunk in
                    // Successful chunk = healthy connection. Clear
                    // backoff so the next disconnect starts from
                    // attempt 0 (Codex M1: don't accumulate backoff
                    // across periods of healthy traffic).
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.reconnectAttempt = 0
                        self.routeChunk(chunk, into: weakView)
                    }
                },
                onDisconnect: { [weak self] err in
                    DispatchQueue.main.async {
                        userDisconnectCB?(err)
                        self?.handleStreamDisconnect()
                    }
                }
            )
            activeSessionId = sid

            // Now that the subscription is live AND the buffer is
            // primed, fire the snapshot RPC and start the timeout.
            // Order matters: buffer must be non-nil before any
            // chunk callback can fire.
            if isWarmSubscribe, let cb = onRequestTailSnapshot {
                cb(sid, Self.snapshotMaxBytes)
                startSnapshotTimeout()
            }
        }

        /// v1.26 B2: per-chunk dispatch. Routes `tail_snapshot_result`
        /// frames into the buffer-drain path; live `stdout` / `stderr`
        /// frames either go direct or buffer (depending on whether
        /// we're waiting on a snapshot). The drain ordering is:
        /// **snapshot first, then buffered chunks in arrival order**
        /// — this matches the helper's broadcast ordering and
        /// reproduces a coherent terminal state on the iOS side.
        func routeChunk(
            _ chunk: RemoteSessionEventStream.TerminalChunk,
            into view: RemoteTerminalView?
        ) {
            // Always remember we've seen a chunk for this session,
            // even before drain — a session that just produced a
            // result chunk has clearly emitted before, so the next
            // resubscribe should warm-pattern.
            lastChunkedSessionId = sessionId

            if chunk.event == Self.snapshotEventName {
                // Codex MEDIUM (v1.26.0 hotfix): a snapshot that
                // arrives AFTER the 2 s timeout has already fired
                // is stale by definition — direct-write has been
                // emitting newer live chunks for some duration.
                // Writing the snapshot now would inject older
                // content AFTER the newer output, producing
                // visual reorder / duplication. Drop it.
                //
                // We detect "timeout already fired" via
                // pendingSnapshotBuffer == nil — drain sets it
                // nil, and a fresh subscribe would have set it
                // back to [] before any chunk could arrive.
                guard pendingSnapshotBuffer != nil else { return }
                drainBufferAndSwitchToDirectWrite(snapshot: chunk.data, into: view)
                return
            }
            if pendingSnapshotBuffer != nil {
                // Append to pending buffer. Capacity is implicitly
                // bounded by the 2 s timeout — at typical chunk
                // rates this is dozens of small payloads at most.
                pendingSnapshotBuffer?.append(chunk.data)
                return
            }
            // Direct-write mode (cold subscribe or post-drain).
            view?.pushStdout(chunk.data)
        }

        private func startSnapshotTimeout() {
            snapshotTimeoutTask?.cancel()
            let weakSelf = self
            snapshotTimeoutTask = Task { [weak weakSelf] in
                let nanos = UInt64(Self.snapshotTimeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled, let s = weakSelf else { return }
                await MainActor.run {
                    // Snapshot never arrived. Drain whatever
                    // accumulated and switch to direct write —
                    // the user sees the live chunks unprefixed,
                    // which is the same UX as the v1.25 baseline.
                    s.drainBufferAndSwitchToDirectWrite(snapshot: nil, into: s.view)
                }
            }
        }

        /// Common drain helper: writes the snapshot (if present),
        /// then the buffered chunks in order, then nils the buffer
        /// + cancels the timeout. Idempotent — calling with an
        /// already-drained buffer is a no-op.
        func drainBufferAndSwitchToDirectWrite(
            snapshot: Data?,
            into view: RemoteTerminalView?
        ) {
            snapshotTimeoutTask?.cancel()
            snapshotTimeoutTask = nil
            let buffered = pendingSnapshotBuffer ?? []
            pendingSnapshotBuffer = nil
            if let snapshot = snapshot, !snapshot.isEmpty {
                view?.pushStdout(snapshot)
            }
            for chunk in buffered {
                view?.pushStdout(chunk)
            }
        }

        /// v1.25 Phase 4 slice 4: terminal cancel — no further
        /// reconnect attempts will fire. Idempotent.
        func cancel() {
            isCancelled = true
            reconnectTask?.cancel()
            reconnectTask = nil
            cancellable?.cancel()
            cancellable = nil
            activeSessionId = nil
            // v1.26 B2: also tear down the snapshot path so a
            // stale timeout can't fire after cancel.
            snapshotTimeoutTask?.cancel()
            snapshotTimeoutTask = nil
            pendingSnapshotBuffer = nil
        }

        // MARK: - scenePhase lifecycle (slice 4)

        /// Drive lifecycle from the host's scenePhase. Background /
        /// inactive → pause; active → resume. Idempotent: calling
        /// with the same phase twice is a no-op.
        func applyScenePhase(_ phase: ScenePhase) {
            switch phase {
            case .background, .inactive:
                pause()
            case .active:
                resume()
            @unknown default:
                // Treat future phases as a soft pause — conservative
                // default; the foreground transition will explicitly
                // .active and resume.
                pause()
            }
        }

        func pause() {
            if isPaused || isCancelled { return }
            isPaused = true
            reconnectTask?.cancel()
            reconnectTask = nil
            cancellable?.cancel()
            cancellable = nil
            // Leave activeSessionId untouched so resume can detect
            // "same session, paused" and reattach without churn.
            // `subscribeIfNeeded` checks isPaused; we just nil out
            // cancellable so resume rebuilds.
            //
            // v1.26 B2: any pending snapshot is orphaned — drop the
            // timeout task and the buffer. resume() will warm-
            // subscribe (since lastChunkedSessionId is preserved)
            // and issue a fresh snapshot RPC.
            snapshotTimeoutTask?.cancel()
            snapshotTimeoutTask = nil
            pendingSnapshotBuffer = nil
        }

        func resume() {
            if !isPaused || isCancelled { return }
            isPaused = false
            // Force a fresh subscribe by clearing activeSessionId.
            // Background disconnect drops the WS entirely; the
            // server doesn't hold our subscription so resubscribing
            // is the only path.
            activeSessionId = nil
            subscribeIfNeeded()
        }

        // MARK: - reconnect (slice 4)

        private func handleStreamDisconnect() {
            // The stream's onDisconnect fires for ANY shutdown —
            // including the one we trigger via `cancel()` /
            // `pause()`. Don't reconnect in those cases.
            if isCancelled || isPaused { return }
            // Clear the dead subscription handle so subscribeIfNeeded
            // proceeds when the reconnect timer fires.
            cancellable = nil
            activeSessionId = nil
            scheduleReconnect()
        }

        private func scheduleReconnect() {
            if isCancelled || isPaused { return }
            reconnectTask?.cancel()
            let attempt = reconnectAttempt
            let delay = Self.computeBackoff(attempt: attempt)
            reconnectAttempt += 1
            reconnectTask = Task { [weak self] in
                let nanos = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard let self = self, !Task.isCancelled else { return }
                await MainActor.run {
                    self.subscribeIfNeeded()
                }
            }
        }

        /// Jittered exponential backoff. attempt 0 → ~0.5–0.625 s,
        /// attempt 1 → ~1.0–1.25 s, … capped at ~10 s + 25 % jitter.
        /// Public + static so tests can pin the curve.
        public static func computeBackoff(
            attempt: Int,
            base: TimeInterval = 0.5,
            cap: TimeInterval = 10.0,
            jitterPercent: Double = 0.25,
            random: () -> Double = { Double.random(in: 0...1) }
        ) -> TimeInterval {
            // Clamp attempt at a value where the geometric series
            // would already exceed the cap — avoids Double overflow
            // for pathological attempt counts.
            let clamped = max(0, min(attempt, 16))
            let unjittered = min(base * pow(2.0, Double(clamped)), cap)
            // Jitter on top: +0...+25% by default. Keeps adjacent
            // clients from synchronising on the same backoff curve
            // (thundering-herd avoidance — Codex M1).
            let jitter = unjittered * jitterPercent * random()
            return unjittered + jitter
        }

        // MARK: - RemoteTerminalViewDelegate

        public func remoteTerminalViewDidBecomeReady(_ view: RemoteTerminalView) {
            // No-op for slice 1-3. Slice 4+ may use this to drive
            // a host-facing "terminal ready" signal once the JS
            // bundle is loaded.
        }

        public func remoteTerminalView(
            _ view: RemoteTerminalView,
            didReceiveStdin data: String
        ) {
            // v1.25 Phase 4 slice 2: forward raw bytes to the host.
            guard let onStdin = onStdin, !data.isEmpty else { return }
            onStdin(Data(data.utf8))
        }

        public func remoteTerminalView(
            _ view: RemoteTerminalView,
            didResizeTo cols: Int, rows: Int
        ) {
            // v1.25 Phase 4 slice 2: forward viewport size to the host.
            guard let onResize = onResize, cols > 0, rows > 0 else { return }
            onResize(cols, rows)
        }
    }
}

#endif
