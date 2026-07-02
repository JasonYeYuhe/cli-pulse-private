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
    /// R0 (B3): the session's `realtime_private` (default false). Picks the
    /// `pterm:`-private + user-JWT join vs the legacy public `term:` + anon
    /// join. The host should key this view's identity on `(sessionId,
    /// isRealtimePrivate)` so a flip recreates cleanly; `updateUIView` also
    /// reconciles a same-identity flip via `reconcilePrivacy`.
    public let isRealtimePrivate: Bool
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
    /// v1.26.1 telemetry: caller-supplied foreground-recovery outcome
    /// sink. Wired to a Sentry breadcrumb so we get field visibility
    /// into recovery success rate.
    public let onSnapshotOutcome: ((Coordinator.SnapshotOutcome) -> Void)?
    /// R0 (S4, Gemini #3): fetch a FRESH GoTrue JWT for a PRIVATE join. Called
    /// imperatively BEFORE a warm-resume / reconnect join so a >1 h background
    /// can't rejoin on a stale token (the detail-view refresh loop may not have
    /// run yet). Wired to `state.api.realtimeConfiguration().accessToken`.
    public let refreshAccessToken: (() async -> String?)?
    /// R0 (S4): fired ONCE when a PRIVATE join is fatally rejected (auth) after a
    /// single refresh-retry. The host surfaces a banner and falls back to the
    /// polled output panel instead of leaving a permanently blank terminal.
    public let onFatalJoinRejection: (() -> Void)?

    public init(
        sessionId: String,
        isRealtimePrivate: Bool = false,
        streamConfig: RemoteSessionEventStream.Configuration,
        scenePhase: ScenePhase = .active,
        onDisconnect: ((Error?) -> Void)? = nil,
        onStdin: ((Data) -> Void)? = nil,
        onResize: ((Int, Int) -> Void)? = nil,
        onRequestTailSnapshot: ((String, Int) -> Void)? = nil,
        onSnapshotOutcome: ((Coordinator.SnapshotOutcome) -> Void)? = nil,
        refreshAccessToken: (() async -> String?)? = nil,
        onFatalJoinRejection: (() -> Void)? = nil
    ) {
        self.sessionId = sessionId
        self.isRealtimePrivate = isRealtimePrivate
        self.streamConfig = streamConfig
        self.scenePhase = scenePhase
        self.onDisconnect = onDisconnect
        self.onStdin = onStdin
        self.onResize = onResize
        self.onRequestTailSnapshot = onRequestTailSnapshot
        self.onSnapshotOutcome = onSnapshotOutcome
        self.refreshAccessToken = refreshAccessToken
        self.onFatalJoinRejection = onFatalJoinRejection
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionId: sessionId,
            isPrivate: isRealtimePrivate,
            streamConfig: streamConfig,
            onDisconnect: onDisconnect,
            onStdin: onStdin,
            onResize: onResize,
            onRequestTailSnapshot: onRequestTailSnapshot,
            onSnapshotOutcome: onSnapshotOutcome,
            refreshAccessToken: refreshAccessToken,
            onFatalJoinRejection: onFatalJoinRejection
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
            context.coordinator.isPrivate = isRealtimePrivate  // R0: adopt the new session's mode
            uiView.clear()
            context.coordinator.subscribeIfNeeded()
        } else {
            // R0 (B3): same session, privacy flipped (initial default-false →
            // loaded value, or cutover) → rejoin on the correct topic.
            context.coordinator.reconcilePrivacy(isRealtimePrivate)
        }
        // R0 (B3): a token refresh re-renders with a fresh streamConfig — push
        // the new token onto the live private join (no-op if unchanged/public).
        context.coordinator.updateAccessToken(streamConfig.accessToken)
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
        /// R0 (B3): the session's resolved private-mode flag. Drives the
        /// `pterm:`-private vs `term:`-public join. A change → cancel +
        /// resubscribe (a mismatch with the helper is a silent blackhole).
        var isPrivate: Bool
        /// Mutable so a token refresh can rebuild the stream (future
        /// reconnects use the fresh token) while `updateAccessToken` pushes
        /// the new token onto the LIVE join.
        var streamConfig: RemoteSessionEventStream.Configuration
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
        /// v1.26.1 telemetry: fired once per warm-subscribe recovery
        /// attempt with the resolved outcome. The host wires this to
        /// a Sentry breadcrumb so we get field visibility into the
        /// real-world success rate of foreground-recovery (Gemini FYI:
        /// the 2 s timeout was previously a silent path). Pure data —
        /// the Coordinator never touches Sentry directly, keeping the
        /// state machine unit-testable.
        let onSnapshotOutcome: ((SnapshotOutcome) -> Void)?
        /// R0 (S4, Gemini #3): async fresh-JWT provider for a private rejoin.
        let refreshAccessToken: (() async -> String?)?
        /// R0 (S4): fatal private-join-rejection surface (host falls back).
        let onFatalJoinRejection: (() -> Void)?
        /// R0 (S4): one-shot guard — a single forced-refresh rejoin per healthy
        /// streak (reset on any chunk). Stops a stale-JWT bounce from becoming a
        /// reconnect storm; a SECOND consecutive rejection is fatal.
        private var authRetryUsed: Bool = false
        weak var view: RemoteTerminalView?

        /// v1.26.1 telemetry: resolution of a warm-subscribe
        /// foreground-recovery attempt.
        public enum SnapshotOutcome: Equatable {
            /// `tail_snapshot_result` arrived in the 2 s window;
            /// `bufferedChunks` live chunks were drained after it.
            case recovered(bufferedChunks: Int)
            /// 2 s elapsed with no snapshot; `bufferedChunks` live
            /// chunks were drained unprefixed (v1.25 baseline UX).
            case timedOut(bufferedChunks: Int)
        }

        /// Tracks the session id the active subscription is bound
        /// to. Diverges from `sessionId` momentarily when the
        /// session changes; `updateUIView` calls
        /// `subscribeIfNeeded` to reconcile.
        private(set) var activeSessionId: String?
        /// The (sessionId, isPrivate) pair the live subscription is bound to —
        /// so a privacy flip is detected even when the sessionId is unchanged.
        private(set) var activeIsPrivate: Bool = false
        private var cancellable: RemoteSessionEventStream.Cancellable?
        private var stream: RemoteSessionEventStream

        /// v1.25 Phase 4 slice 4: lifecycle + reconnect state.
        private(set) var isPaused: Bool = false
        private(set) var isCancelled: Bool = false
        private(set) var reconnectAttempt: Int = 0
        private var reconnectTask: Task<Void, Never>?
        /// R0 (B3): monotonic id for the live subscription. Bumped on every
        /// (re)subscribe so the async `onDisconnect` of a subscription we've
        /// intentionally torn down (privacy flip) can't drive a stray
        /// reconnect — only the CURRENT subscription's disconnect does.
        /// Guards [[feedback_codex_review_late_arrival_pattern]].
        private var subscriptionEpoch: UInt64 = 0

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
            isPrivate: Bool = false,
            streamConfig: RemoteSessionEventStream.Configuration,
            onDisconnect: ((Error?) -> Void)?,
            onStdin: ((Data) -> Void)? = nil,
            onResize: ((Int, Int) -> Void)? = nil,
            onRequestTailSnapshot: ((String, Int) -> Void)? = nil,
            onSnapshotOutcome: ((SnapshotOutcome) -> Void)? = nil,
            refreshAccessToken: (() async -> String?)? = nil,
            onFatalJoinRejection: (() -> Void)? = nil
        ) {
            self.sessionId = sessionId
            self.isPrivate = isPrivate
            self.streamConfig = streamConfig
            self.onDisconnect = onDisconnect
            self.onStdin = onStdin
            self.onResize = onResize
            self.onRequestTailSnapshot = onRequestTailSnapshot
            self.onSnapshotOutcome = onSnapshotOutcome
            self.refreshAccessToken = refreshAccessToken
            self.onFatalJoinRejection = onFatalJoinRejection
            self.stream = RemoteSessionEventStream(config: streamConfig)
            super.init()
        }

        deinit {
            reconnectTask?.cancel()
            cancellable?.cancel()
        }

        func subscribeIfNeeded() {
            if isPaused || isCancelled { return }
            if activeSessionId == sessionId, activeIsPrivate == isPrivate,
               cancellable != nil { return }

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
            subscriptionEpoch &+= 1
            let epoch = subscriptionEpoch
            cancellable = stream.subscribeTerminal(
                sessionId: sid,
                isPrivate: isPrivate,
                onChunk: { [weak self] chunk in
                    // Successful chunk = healthy connection. Clear
                    // backoff so the next disconnect starts from
                    // attempt 0 (Codex M1: don't accumulate backoff
                    // across periods of healthy traffic).
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.reconnectAttempt = 0
                        self.authRetryUsed = false  // healthy traffic re-arms the auth retry
                        self.routeChunk(chunk, into: weakView)
                    }
                },
                onDisconnect: { [weak self] err in
                    DispatchQueue.main.async {
                        userDisconnectCB?(err)
                        self?.handleStreamDisconnect(epoch: epoch, error: err)
                    }
                }
            )
            activeSessionId = sid
            activeIsPrivate = isPrivate

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
                // v1.26.1 telemetry: snapshot landed in-window =
                // successful recovery. Capture the buffered count
                // before drain nils it.
                let recoveredCount = pendingSnapshotBuffer?.count ?? 0
                drainBufferAndSwitchToDirectWrite(snapshot: chunk.data, into: view)
                onSnapshotOutcome?(.recovered(bufferedChunks: recoveredCount))
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
                await MainActor.run { s.resolveSnapshotTimeout() }
            }
        }

        /// Snapshot-timeout resolution, extracted from the timer Task
        /// so it's unit-testable without a 2 s wait. Drains whatever
        /// accumulated and switches to direct write — the user sees
        /// the live chunks unprefixed (v1.25 baseline UX). Guarded on
        /// still-pending so a timeout racing a just-arrived snapshot
        /// doesn't double-drain or double-report. Emits the
        /// `.timedOut` telemetry outcome (v1.26.1).
        func resolveSnapshotTimeout() {
            guard pendingSnapshotBuffer != nil else { return }
            let missedCount = pendingSnapshotBuffer?.count ?? 0
            drainBufferAndSwitchToDirectWrite(snapshot: nil, into: view)
            onSnapshotOutcome?(.timedOut(bufferedChunks: missedCount))
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
            // R0 (S4, Gemini #3): a background >1 h leaves a STALE JWT in
            // streamConfig; fetch a fresh one before the private rejoin (public
            // resumes immediately, unchanged).
            fetchFreshTokenThenSubscribe()
        }

        // MARK: - reconnect (slice 4)

        private func handleStreamDisconnect(epoch: UInt64, error: Error?) {
            // The stream's onDisconnect fires for ANY shutdown —
            // including the one we trigger via `cancel()` /
            // `pause()`. Don't reconnect in those cases.
            if isCancelled || isPaused { return }
            // R0 (B3): ignore the (async) disconnect of a subscription we've
            // already replaced — e.g. a privacy flip tore down the old join
            // and resubscribed. Only the CURRENT epoch's disconnect reconnects.
            guard epoch == subscriptionEpoch else { return }
            // Clear the dead subscription handle so subscribeIfNeeded
            // proceeds when the reconnect timer fires.
            cancellable = nil
            activeSessionId = nil
            // R0 (S4): a PRIVATE join rejected by read-RLS / a bad or expired
            // token. Try ONE forced-refresh rejoin (covers a stale JWT after a
            // long background — Gemini #3); a SECOND consecutive rejection is a
            // real authz failure → surface it and fall back to the polled panel,
            // NOT a blind reconnect storm against a doomed join.
            if let streamError = error as? RemoteSessionEventStream.StreamError,
               case .joinRejected = streamError {
                if isPrivate, refreshAccessToken != nil, !authRetryUsed {
                    authRetryUsed = true
                    fetchFreshTokenThenSubscribe()
                } else {
                    reconnectTask?.cancel()
                    reconnectTask = nil
                    onFatalJoinRejection?()
                }
                return
            }
            scheduleReconnect()
        }

        /// R0 (S4, Gemini #3): fetch a FRESH GoTrue JWT (for a private join)
        /// BEFORE building the join frame, then subscribe — so a warm-resume /
        /// reconnect after a long background never rejoins on an expired token.
        /// For a public session (or when no provider is wired) it subscribes
        /// immediately, byte-identical to pre-S4.
        func fetchFreshTokenThenSubscribe() {
            guard isPrivate, let provider = refreshAccessToken else {
                subscribeIfNeeded()
                return
            }
            Task { [weak self] in
                let fresh = await provider()
                await MainActor.run {
                    guard let self = self, !self.isCancelled, !self.isPaused else { return }
                    if let fresh { self.adoptFreshToken(fresh) }
                    self.subscribeIfNeeded()
                }
            }
        }

        /// Rebuild the stream config + stream with a fresh token WITHOUT pushing
        /// onto a live join (we're about to (re)subscribe fresh). Distinct from
        /// `updateAccessToken`, which pushes onto an EXISTING live private join.
        private func adoptFreshToken(_ token: String) {
            if streamConfig.accessToken == token { return }
            streamConfig = RemoteSessionEventStream.Configuration(
                supabaseURL: streamConfig.supabaseURL,
                supabaseAnonKey: streamConfig.supabaseAnonKey,
                accessToken: token,
                heartbeatInterval: streamConfig.heartbeatInterval
            )
            stream = RemoteSessionEventStream(config: streamConfig)
        }

        // MARK: - R0 (B3): privacy-flip + token-refresh reconciliation

        /// React to the session's `realtime_private` flipping (e.g. the
        /// initial default-false subscribe → the loaded value, or the cutover).
        /// Realtime can't switch a live channel between public `term:` and
        /// private `pterm:` in place — they are DIFFERENT topics — so we tear
        /// the current join down and resubscribe. The old join's async
        /// `onDisconnect` carries a now-stale epoch, so it can't trigger a
        /// reconnect race. Not a terminal `cancel()`: we WANT to resubscribe.
        func reconcilePrivacy(_ newIsPrivate: Bool) {
            if isPrivate == newIsPrivate { return }
            isPrivate = newIsPrivate
            cancellable?.cancel()
            cancellable = nil
            activeSessionId = nil
            snapshotTimeoutTask?.cancel()
            snapshotTimeoutTask = nil
            pendingSnapshotBuffer = nil
            subscribeIfNeeded()
        }

        /// Push a refreshed user access_token. Rebuilds the stream config so a
        /// FUTURE (re)subscribe rejoins with the fresh token, AND pushes it onto
        /// the LIVE private join so Realtime re-evaluates the cached RLS
        /// decision immediately. No-op if unchanged; harmless on the public
        /// path (the subscription ignores tokens there).
        func updateAccessToken(_ token: String?) {
            if streamConfig.accessToken == token { return }
            streamConfig = RemoteSessionEventStream.Configuration(
                supabaseURL: streamConfig.supabaseURL,
                supabaseAnonKey: streamConfig.supabaseAnonKey,
                accessToken: token,
                heartbeatInterval: streamConfig.heartbeatInterval
            )
            stream = RemoteSessionEventStream(config: streamConfig)
            cancellable?.updateAccessToken(token)
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
                    // R0 (S4): refresh the private JWT before the rejoin so a
                    // reconnect after a long stall doesn't 401 on a stale token.
                    self.fetchFreshTokenThenSubscribe()
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
