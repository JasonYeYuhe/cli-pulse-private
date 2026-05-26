// v1.25 Phase 4 slice 1 — SwiftUI wrapper around `RemoteTerminalView`.
// Drops into the iOS Sessions detail view; subscribes to the
// session's Realtime broadcast channel on appear, tears down on
// disappear. **Read-only in this slice** (no input wiring).

#if os(iOS) || os(visionOS)
import SwiftUI
import UIKit

/// UIViewRepresentable that hosts an xterm.js terminal viewport
/// inside SwiftUI. Owns a `RemoteSessionEventStream` subscription
/// keyed by `sessionId`; output chunks land on the embedded
/// `RemoteTerminalView`'s coalescer and render in the WebView.
///
/// **Reconnect**: not in this slice. If the WS drops, `onDisconnect`
/// fires on the coordinator and the view shows the last buffer
/// state. Slice 4 of Phase 4 adds debounced + jittered exponential
/// backoff reconnect per Codex M1.
///
/// **Lifecycle**: not in this slice either. Background → no special
/// handling; foreground → the same subscription continues if it's
/// still alive. Slice 4 of Phase 4 adds scenePhase-driven
/// disconnect-on-background + resubscribe-on-foreground per
/// Gemini HIGH (plan §4e).
///
/// **scrollback cap**: enforced JS-side in `index.html`
/// (`scrollback: 5000` today, plan §4e wants 500 on iOS;
/// honored in slice 4).
public struct RemoteTerminalViewRepresentable: UIViewRepresentable {

    public let sessionId: String
    public let streamConfig: RemoteSessionEventStream.Configuration
    /// Caller-supplied callback fired when the WS subscription
    /// ends (any error, peer close, or `coordinator.cancel()`).
    /// Optional — most callers don't need to react.
    public let onDisconnect: ((Error?) -> Void)?
    /// v1.25 Phase 4 slice 2: caller-supplied keystroke forwarder.
    /// Fired once per xterm.js `onData` event with raw UTF-8 bytes
    /// (control sequences encoded inline). Typically wired to
    /// `RemoteSessionControlClient.sendInputRaw` so the helper writes
    /// these bytes verbatim to the PTY. Optional — slice 1 left this
    /// nil to ship the read-only path first.
    public let onStdin: ((Data) -> Void)?
    /// v1.25 Phase 4 slice 2: caller-supplied viewport-resize
    /// forwarder. Fired when xterm.js's ResizeObserver picks up a
    /// layout change (phone rotation, soft-keyboard show/hide).
    /// Typically wired to `RemoteSessionControlClient.resize` so the
    /// helper PTY `ioctl(TIOCSWINSZ)`s and the child gets SIGWINCH.
    public let onResize: ((Int, Int) -> Void)?

    public init(
        sessionId: String,
        streamConfig: RemoteSessionEventStream.Configuration,
        onDisconnect: ((Error?) -> Void)? = nil,
        onStdin: ((Data) -> Void)? = nil,
        onResize: ((Int, Int) -> Void)? = nil
    ) {
        self.sessionId = sessionId
        self.streamConfig = streamConfig
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
        context.coordinator.subscribeIfNeeded()
        return view
    }

    public func updateUIView(_ uiView: RemoteTerminalView, context: Context) {
        // If the session id changed on us (e.g. user navigated from
        // session A to session B without unmounting), tear the old
        // subscription down and reconnect to the new topic. Cheap
        // cancel-before-replace; matches Codex M1 guidance for
        // rapid session switches.
        if context.coordinator.activeSessionId != sessionId {
            context.coordinator.cancel()
            context.coordinator.sessionId = sessionId
            uiView.clear()
            context.coordinator.subscribeIfNeeded()
        }
    }

    public static func dismantleUIView(
        _ uiView: RemoteTerminalView, coordinator: Coordinator
    ) {
        coordinator.cancel()
    }

    /// Coordinator owns the live `RemoteSessionEventStream`
    /// subscription. Lifetimes:
    ///   * Subscription is created when the UIView is created and
    ///     when the session id changes.
    ///   * Subscription is cancelled on dismantle OR when the
    ///     session id changes (cancel-before-replace).
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
            cancellable?.cancel()
        }

        func subscribeIfNeeded() {
            if activeSessionId == sessionId, cancellable != nil { return }
            let sid = sessionId
            let weakView = view  // captured by handlers
            let disconnectCB = onDisconnect
            cancellable = stream.subscribeTerminal(
                sessionId: sid,
                onChunk: { chunk in
                    DispatchQueue.main.async {
                        weakView?.pushStdout(chunk.data)
                    }
                },
                onDisconnect: { err in
                    DispatchQueue.main.async {
                        disconnectCB?(err)
                    }
                }
            )
            activeSessionId = sid
        }

        func cancel() {
            cancellable?.cancel()
            cancellable = nil
            activeSessionId = nil
        }

        // MARK: - RemoteTerminalViewDelegate

        public func remoteTerminalViewDidBecomeReady(_ view: RemoteTerminalView) {
            // No-op in slice 1. Slice 2 will surface "ready" to the
            // host so input controls can light up.
        }

        public func remoteTerminalView(
            _ view: RemoteTerminalView,
            didReceiveStdin data: String
        ) {
            // v1.25 Phase 4 slice 2: hand off to the host's
            // `sendInputRaw` callback. xterm.js's `onData` emits
            // raw UTF-8 strings (including control bytes encoded
            // as their ASCII equivalents), so `Data(data.utf8)`
            // round-trips byte-equal. Empty strings (which xterm.js
            // never sends but defensive) are skipped — sink would
            // throw `notConfigured` on empty payloads.
            guard let onStdin = onStdin, !data.isEmpty else { return }
            onStdin(Data(data.utf8))
        }

        public func remoteTerminalView(
            _ view: RemoteTerminalView,
            didResizeTo cols: Int, rows: Int
        ) {
            // v1.25 Phase 4 slice 2: hand off to the host's
            // `resize` callback. xterm.js's ResizeObserver can fire
            // mid-layout with 0×0; guard so we don't queue a bad
            // command. The receiver should also clamp on its end.
            guard let onResize = onResize, cols > 0, rows > 0 else { return }
            onResize(cols, rows)
        }
    }
}

#endif
