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
    /// P2: the latest OSC 0/2 title the CLI set (nil = never set / cleared).
    /// Owners can surface it in the window title bar.
    @Published public private(set) var terminalTitle: String?

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
    /// P1-4: set while re-attaching to an already-running session so live
    /// output is held until the tail snapshot has been painted (see
    /// `ReattachPaintBuffer`). `nil` for freshly-spawned sessions (no snapshot
    /// to wait on) → live output passes straight through.
    private var reattachBuffer: ReattachPaintBuffer?

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

    /// Attach to an ALREADY-running managed session WITHOUT spawning a new one
    /// (P1-4). Used when the user opens a terminal window for a session that's
    /// already in the Sessions list. Race-safe reattach paint: subscribe to the
    /// live raw stream FIRST (buffering live bytes), THEN fetch the tail
    /// snapshot and paint it, THEN release the buffered bytes in order — so no
    /// output emitted during attach is dropped. See `ReattachPaintBuffer`.
    ///
    /// Idempotent when already attached to the same `sessionId`. Never spawns;
    /// the session's lifetime is owned by the helper, not this window.
    @discardableResult
    public func attachExisting(to view: TerminalView, sessionId: String) async -> String {
        if case let .running(sid) = state, sid == sessionId {
            self.view = view
            view.delegate = self
            return sid
        }
        self.view = view
        view.delegate = self
        // The session is already running on the helper — adopt its id directly.
        state = .running(sessionId: sessionId)
        reattachBuffer = ReattachPaintBuffer()
        // 1. Subscribe FIRST so the buffer captures anything emitted from now on.
        startEventSubscription(sessionId: sessionId)
        // 2. Fetch the tail snapshot, then 3. flush (snapshot + buffered live).
        //    A failed/empty snapshot still releases the buffer so live flows.
        let snapshot = (try? await client.getTailSnapshot(sessionId: sessionId,
                                                          maxBytes: 65536)) ?? Data()
        // If a newer attach (e.g. a reconnect) superseded this one while the
        // snapshot was in flight, bail before painting so two attachExisting
        // calls don't interleave their buffer flushes on the same adapter
        // (deep-review concurrency catch). The newer attach already replaced the
        // subscription + reattach buffer and will paint its own snapshot.
        if Task.isCancelled { return sessionId }
        paintReattachSnapshot(snapshot)
        // Deep-review merge-blocker fix: if the view's single initial `resize`
        // fired into a not-yet-wired delegate during the work above (page-load
        // vs attach race, widened by the liveness preflight on this path), the
        // PTY would be stranded at the spawn default while xterm renders at its
        // fitted width. Proactively deliver the current geometry now. If the
        // view isn't ready yet, `terminalViewDidBecomeReady` will do it.
        if view.isReady { pushCurrentGeometry() }
        return sessionId
    }

    /// Proactively deliver the terminal's CURRENT fitted geometry to the helper
    /// PTY. The JS side emits its initial `resize` exactly once after
    /// `fitAddon.fit()`; if that one message fires before the delegate is wired
    /// it lands in a nil delegate and is lost (and index.html then early-returns
    /// on every later ResizeObserver tick because the size is unchanged), so the
    /// PTY stays at the spawn default (120x40) while xterm renders at its fitted
    /// width → a misaligned TUI until a manual resize. So once attached + ready,
    /// read the fitted cols/rows from xterm and send the resize ourselves —
    /// idempotent with any resize the JS path already delivered.
    func pushCurrentGeometry() {
        guard case let .running(sid) = state, let view else { return }
        let js = "(function(){var t=window.__CLIPulseTerminal&&window.__CLIPulseTerminal.term;"
               + "return (t&&t.cols>0&&t.rows>0)?[t.cols,t.rows]:null;})()"
        view.webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let nums = result as? [NSNumber], nums.count == 2 else { return }
            let cols = nums[0].intValue, rows = nums[1].intValue
            guard cols > 0, rows > 0 else { return }
            Task { @MainActor [weak self] in
                guard let self, case .running = self.state else { return }
                try? await self.client.resize(sessionId: sid, cols: cols, rows: rows)
            }
        }
    }

    /// Write the tail snapshot then release the reattach buffer's held live
    /// bytes, in order. No-op if not currently re-attaching.
    private func paintReattachSnapshot(_ snapshot: Data) {
        guard reattachBuffer != nil else { return }
        let writes = reattachBuffer!.flush(afterSnapshot: snapshot)
        if let view {
            for chunk in writes { view.pushStdout(chunk) }
        }
        // Buffer stays non-nil but in passthrough (isBuffering == false) so
        // `deliverLive` keeps routing through it cheaply; cleared on detach.
    }

    /// Tear down: cancel the subscription, drop buffered I/O, drop the view.
    ///
    /// - Parameter stopSession: when `true` (default — preserves every existing
    ///   caller), also `stop_session`s the helper-side PTY. When `false`,
    ///   DETACH-only (P1-3): the managed session keeps running on the helper
    ///   and stays re-attachable; only this view/subscription is torn down.
    ///   Killing the CLI is then a separate explicit action.
    public func detach(stopSession: Bool = true) async {
        let snapshot = state
        subscriptionTask?.cancel()
        subscriptionTask = nil
        // Drop any buffered keystrokes; the drain loop exits once state is no
        // longer .running.
        pendingStdin.removeAll(keepingCapacity: false)
        inFlightResizeTask?.cancel()
        inFlightResizeTask = nil
        reattachBuffer = nil
        view = nil
        if stopSession, case let .running(sid) = snapshot {
            state = .stopping
            try? await client.stopSession(sessionId: sid)
        }
        // Always land in `.stopped`: this adapter is no longer attached to a
        // live view/subscription. For stopSession == false the HELPER session
        // keeps running (detach-not-kill) and stays re-attachable, but the
        // adapter's OWN state must reflect its disconnected reality — otherwise
        // a reused adapter's `attachExisting` early-return (state == .running)
        // would skip re-subscribing and the re-attached view would receive no
        // live output. Gemini 3.1 Pro review ("zombie adapter trap").
        state = .stopped
    }

    private func startEventSubscription(sessionId: String) {
        subscriptionTask?.cancel()
        // Phase 1b: subscribe to the RAW (un-stripped) stream so the ANSI/VT
        // escapes survive and xterm.js renders the real TUI. The helper still
        // redacts; raw is local-broker-only (never the cloud).
        let stream = client.subscribeEvents(sessionId: sessionId, raw: true)
        subscriptionTask = Task { @MainActor [weak self] in
            do {
                for try await event in stream {
                    if Task.isCancelled { return }
                    self?.deliverLive(event)
                }
            } catch {
                // Cancellation (detach / window close) is intentional, NOT a
                // failure — don't flip to .failed or a closing window would
                // flash a spurious "disconnected" state. Only a real mid-stream
                // transport error surfaces as .failed (a live terminal observing
                // .state can then show a disconnected banner — deep review).
                if Task.isCancelled || error is CancellationError { return }
                guard let self else { return }
                self.state = .failed(reason: "subscribe_events: \(error)")
            }
        }
    }

    /// Route a single helper event's output bytes to the view, honouring the
    /// reattach buffer if one is active (P1-4). Non-output events are ignored
    /// (the in-app terminal MVP doesn't surface lifecycle events). Internal so
    /// tests can verify routing + buffering + nil-view safety without a live
    /// subscription Task.
    func deliverLive(_ event: LocalSessionEvent) {
        let payload: String
        switch event {
        case .outputRaw(_, let p, _):
            // raw:true stream — ANSI/VT intact → xterm.js renders the TUI.
            payload = p
        case .outputDelta(_, let p, _):
            // Fallback: a raw subscription that degrades to the redacted stream
            // (older helper without output_raw) still shows the text.
            payload = p
        default:
            // `subscribed`, `heartbeat`, `sessionStatus`, etc. — ignored.
            return
        }
        let bytes = Data(payload.utf8)
        if reattachBuffer != nil {
            // Re-attaching: hold (or pass, post-flush) per the buffer.
            if let now = reattachBuffer!.intake(bytes) {
                view?.pushStdout(now)
            }
        } else {
            view?.pushStdout(bytes)
        }
    }

    // MARK: - TerminalViewDelegate

    public func terminalViewDidBecomeReady(_ view: TerminalView) {
        // Deliver the initial geometry to the PTY (deep-review merge-blocker):
        // `ready` fires after the JS-side `fitAddon.fit()`, so xterm's cols/rows
        // are now known. This is the delegate-driven path for when `ready`
        // arrives AFTER the delegate is wired; `attachExisting` covers the case
        // where `ready` fired earlier (during the liveness preflight) by calling
        // `pushCurrentGeometry()` itself once `isReady` is true.
        pushCurrentGeometry()
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

    public func terminalView(_ view: TerminalView, didSetTitle title: String) {
        // P2: surface the CLI's OSC title for the window title bar.
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        terminalTitle = trimmed.isEmpty ? nil : trimmed
    }
}
#endif
