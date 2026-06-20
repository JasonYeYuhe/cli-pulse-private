// v1.24 Phase 3 slice 3 — TerminalSessionAdapter.
// Owns the lifecycle wiring between a TerminalView (xterm.js
// frontend) and a LocalSessionControlClient (the helper RPC client
// that talks to ManagedSessionManager over UDS+JSON-RPC):
//
//   * Spawns a managed session via `start_session` RPC.
//   * Subscribes to that session's `output_raw` events (raw:true — ANSI
//     intact so the TUI renders); routes payload bytes to
//     `TerminalView.pushStdout`. Falls back to `output_delta` if raw is
//     unavailable (older helper).
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
    /// v-next P1-1: the user-chosen absolute working directory (NSOpenPanel).
    /// nil ⇒ the helper inherits the daemon's dir (prior behaviour). Sent
    /// only over the local UDS (same-Mac); the cloud row gets the basename.
    public let cwd: String?
    public weak var view: TerminalView?

    @Published public private(set) var state: State = .idle

    private var subscriptionTask: Task<Void, Never>?
    // stdin: a lossless, ordered, coalescing queue. Terminal keystrokes must
    // NEVER be dropped — the old cancel-and-replace dropped fast typing (the
    // task for an earlier keystroke got cancelled mid-send by the next one;
    // codex review 2026-06-19). Appends go into `pendingStdin`; a single drain
    // loop sends them in FIFO order, coalescing whatever accumulated during the
    // previous send. All state is @MainActor-isolated, so no lock is needed.
    private var pendingStdin = Data()
    private var stdinDraining = false
    private var inFlightResizeTask: Task<Void, Never>?

    /// Designated initializer. The client + provider are bound at
    /// construction; the caller wires the view via `attach(to:)`
    /// after this object is alive so the delegate hookup happens
    /// on the actor.
    public init(client: LocalSessionControlClient = LocalSessionControlClient(),
                provider: String = "claude",
                cwd: String? = nil) {
        self.client = client
        self.provider = provider
        self.cwd = cwd
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
            // v-next P1-1: pass the chosen absolute cwd (local UDS only). The
            // cloud-visible cwdBasename is derived from it so remote viewers
            // still see the project name without the full path.
            let result = try await client.startManagedSession(
                provider: provider,
                clientLabel: "in-app-terminal",
                cwdBasename: cwd.map { ($0 as NSString).lastPathComponent },
                cwdHmac: nil,
                cwd: cwd)
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
        // Drop any buffered keystrokes; the drain loop exits once state is no
        // longer .running.
        pendingStdin.removeAll(keepingCapacity: false)
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
        // Phase 1b: subscribe to the RAW (un-stripped) stream so the ANSI/VT
        // escapes survive and xterm.js renders the real TUI. The helper still
        // redacts; raw is local-broker-only (never the cloud).
        let stream = client.subscribeEvents(sessionId: sessionId, raw: true)
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
        case .outputRaw(_, let payload, _):
            // Phase 1b: the terminal subscribes with raw:true, so live output
            // arrives here with ANSI/VT escapes intact → xterm.js renders the TUI.
            view.pushStdout(Data(payload.utf8))
        case .outputDelta(_, let payload, _):
            // Fallback: if a raw subscription ever degrades to the redacted
            // stream (older helper without output_raw), still show the text.
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
        guard case .running = state else { return }
        // Enqueue every keystroke (lossless + ordered). A single drain loop
        // sends them FIFO; if one is already running, it'll pick these up.
        pendingStdin.append(Data(data.utf8))
        guard !stdinDraining else { return }
        stdinDraining = true
        Task { [weak self] in await self?.drainStdin() }
    }

    /// Drain buffered stdin to the helper in order, coalescing whatever
    /// accumulated during the previous send. @MainActor-isolated, so the
    /// only suspension point is the RPC await; buffer mutations never race.
    private func drainStdin() async {
        defer { stdinDraining = false }
        while !pendingStdin.isEmpty {
            guard case let .running(sid) = state else {
                pendingStdin.removeAll(keepingCapacity: false)
                return
            }
            let chunk = pendingStdin
            pendingStdin.removeAll(keepingCapacity: true)
            try? await client.sendInputRaw(sessionId: sid, bytes: chunk)
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
