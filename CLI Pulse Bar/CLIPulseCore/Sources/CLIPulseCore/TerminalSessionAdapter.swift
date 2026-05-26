// v1.24 Phase 3 slice 3 — TerminalSessionAdapter.
// Owns the lifecycle wiring between a TerminalView (xterm.js
// frontend) and a LocalSessionControlClient (the helper RPC client
// that talks to ManagedSessionManager over UDS+JSON-RPC):
//
//   * Spawns a managed session via `start_session` RPC.
//   * Subscribes to that session's `output_delta` events; routes
//     payload bytes to `TerminalView.pushStdout`.
//   * Forwards `TerminalView` delegate callbacks back over RPC:
//     stdin → `send_input_raw` (raw bytes preserve Ctrl-C),
//     resize → `resize` (TIOCSWINSZ).
//   * On detach (window close / explicit teardown), cancels the
//     event subscription and `stop_session`s the helper-side PTY.
//
// macOS-only because TerminalView is macOS-only.

#if os(macOS)
import Foundation

@MainActor
public final class TerminalSessionAdapter: NSObject, TerminalViewDelegate, @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case idle
        case starting
        case running(sessionId: String)
        case stopping
        case stopped
        case failed(reason: String)
    }

    public let client: LocalSessionControlClient
    public let provider: String
    public weak var view: TerminalView?

    @Published public private(set) var state: State = .idle

    private var subscriptionTask: Task<Void, Never>?
    private var inFlightStdinTask: Task<Void, Never>?
    private var inFlightResizeTask: Task<Void, Never>?

    /// Designated initializer. The client + provider are bound at
    /// construction; the caller wires the view via `attach(to:)`
    /// after this object is alive so the delegate hookup happens
    /// on the actor.
    public init(client: LocalSessionControlClient = LocalSessionControlClient(),
                provider: String = "claude") {
        self.client = client
        self.provider = provider
    }

    /// Attach to a `TerminalView`, start the helper-side session,
    /// and begin streaming. Idempotent — calling twice while
    /// `state` is `.running` is a no-op. Returns the helper's
    /// `session_id` on success; throws the first underlying
    /// `SessionControlError` on failure.
    @discardableResult
    public func attach(to view: TerminalView) async throws -> String {
        if case let .running(sid) = state {
            self.view = view
            view.delegate = self
            return sid
        }
        self.view = view
        view.delegate = self
        state = .starting
        do {
            let result = try await client.startManagedSession(
                provider: provider,
                clientLabel: "in-app-terminal",
                cwdBasename: nil,
                cwdHmac: nil)
            let sid = result.sessionId
            state = .running(sessionId: sid)
            startEventSubscription(sessionId: sid)
            return sid
        } catch {
            state = .failed(reason: String(describing: error))
            throw error
        }
    }

    /// Tear down: cancel the subscription, attempt `stop_session`,
    /// drop the view reference. Safe to call from any state.
    public func detach() async {
        let snapshot = state
        subscriptionTask?.cancel()
        subscriptionTask = nil
        inFlightStdinTask?.cancel()
        inFlightStdinTask = nil
        inFlightResizeTask?.cancel()
        inFlightResizeTask = nil
        if case let .running(sid) = snapshot {
            state = .stopping
            try? await client.stopSession(sessionId: sid)
        }
        state = .stopped
        view = nil
    }

    private func startEventSubscription(sessionId: String) {
        subscriptionTask?.cancel()
        let stream = client.subscribeEvents(sessionId: sessionId)
        let view = self.view
        subscriptionTask = Task { @MainActor [weak self] in
            do {
                for try await event in stream {
                    if Task.isCancelled { return }
                    Self.deliver(event: event, to: view)
                }
            } catch {
                guard let self else { return }
                self.state = .failed(reason: "subscribe_events: \(error)")
            }
        }
    }

    /// Route a single helper event to the view. Exposed (static,
    /// view-optional) so tests can verify routing without a live
    /// subscription Task.
    static func deliver(event: LocalSessionEvent, to view: TerminalView?) {
        guard let view else { return }
        switch event {
        case .outputDelta(_, let payload, _):
            // Helper publishes UTF-8 strings; convert back to Data
            // for TerminalView's coalescer. (Future Phase 2c slice 3
            // Realtime BROADCAST path will deliver raw bytes via a
            // separate stream.)
            view.pushStdout(Data(payload.utf8))
        default:
            // `subscribed`, `keepalive`, `status_changed`, etc. —
            // the in-app terminal MVP ignores these; future polish
            // could surface lifecycle events as the window title.
            return
        }
    }

    // MARK: - TerminalViewDelegate

    public func terminalViewDidBecomeReady(_ view: TerminalView) {
        // No-op for MVP — the view is ready, the subscription is
        // already pumping. Future polish: fetch tail snapshot here
        // when re-attaching to an existing session that pre-dated
        // the window.
    }

    public func terminalView(_ view: TerminalView, didReceiveStdin data: String) {
        guard case let .running(sid) = state else { return }
        let payload = Data(data.utf8)
        // Latest writer wins — typing is so frequent we don't
        // serialize each keystroke into a queue, but we DO replace
        // any pending submission so a stuck network call can't
        // back-press the next key.
        inFlightStdinTask?.cancel()
        inFlightStdinTask = Task { [client] in
            try? await client.sendInputRaw(sessionId: sid, bytes: payload)
        }
    }

    public func terminalView(_ view: TerminalView, didResizeTo cols: Int, rows: Int) {
        guard case let .running(sid) = state else { return }
        inFlightResizeTask?.cancel()
        inFlightResizeTask = Task { [client] in
            try? await client.resize(sessionId: sid, cols: cols, rows: rows)
        }
    }
}
#endif
