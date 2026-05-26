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

    public init(
        sessionId: String,
        streamConfig: RemoteSessionEventStream.Configuration,
        scenePhase: ScenePhase = .active,
        onDisconnect: ((Error?) -> Void)? = nil,
        onStdin: ((Data) -> Void)? = nil,
        onResize: ((Int, Int) -> Void)? = nil
    ) {
        self.sessionId = sessionId
        self.streamConfig = streamConfig
        self.scenePhase = scenePhase
        self.onDisconnect = onDisconnect
        self.onStdin = onStdin
        self.onResize = onResize
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionId: sessionId,
            streamConfig: streamConfig,
            onDisconnect: onDisconnect,
            onStdin: onStdin,
            onResize: onResize
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

        init(
            sessionId: String,
            streamConfig: RemoteSessionEventStream.Configuration,
            onDisconnect: ((Error?) -> Void)?,
            onStdin: ((Data) -> Void)? = nil,
            onResize: ((Int, Int) -> Void)? = nil
        ) {
            self.sessionId = sessionId
            self.streamConfig = streamConfig
            self.onDisconnect = onDisconnect
            self.onStdin = onStdin
            self.onResize = onResize
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
                        self?.reconnectAttempt = 0
                        weakView?.pushStdout(chunk.data)
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
