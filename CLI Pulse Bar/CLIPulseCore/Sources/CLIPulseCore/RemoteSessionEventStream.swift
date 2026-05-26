import Foundation

/// Client-side seam for the v1.25 Phase 2c Realtime BROADCAST
/// subscriber. Sits on the iOS / Mac App side of the pipeline:
///
///   helper drain → `TerminalBroadcastPublisher` →
///   `SupabaseRealtimeBroadcastSink` → Supabase Realtime →
///   **`RemoteSessionEventStream.subscribeTerminal`** → xterm.js
///
/// Wire shape (vsn 2.0.0, array frames):
///
///   * **phx_join**:
///     `["<joinRef>", "<ref>", "realtime:term:<sid>", "phx_join", {"config":...}]`
///   * **heartbeat** (every ≤25 s):
///     `[null, "<ref>", "phoenix", "heartbeat", {}]`
///   * **broadcast received**:
///     `[null, null, "realtime:term:<sid>", "broadcast",
///       {"event":"stdout|stderr", "type":"broadcast",
///        "payload":{"session_id":"<sid>", "data_b64":"<b64>"}}]`
///
/// Slice 4b ships **subscribeTerminal only**. Slice 4c will add
/// `subscribeMetadata` (Postgres CDC) and `fetchTailSnapshot`
/// (cloud RPC + backend migration; owner-gated).
///
/// **Reconnect policy**: the stream **does not auto-reconnect**.
/// On disconnect (any error or peer close), `onDisconnect` fires
/// once and the subscription is dead. Per plan §4b + Codex M1,
/// the caller (iOS view layer) owns reconnect scheduling with
/// debounce + jittered exponential backoff. That keeps the
/// stream simple and avoids reconnect storms when the view is
/// already torn down.
public final class RemoteSessionEventStream: @unchecked Sendable {

    public struct Configuration: Sendable, Equatable {
        public let supabaseURL: String
        public let supabaseAnonKey: String
        /// Heartbeat cadence. Supabase Realtime times out at 30 s
        /// of silence; 25 s default leaves a comfortable margin.
        public let heartbeatInterval: TimeInterval

        public init(
            supabaseURL: String,
            supabaseAnonKey: String,
            heartbeatInterval: TimeInterval = 25
        ) {
            self.supabaseURL = supabaseURL
            self.supabaseAnonKey = supabaseAnonKey
            self.heartbeatInterval = heartbeatInterval
        }
    }

    public struct TerminalChunk: Sendable, Equatable {
        public let event: String   // "stdout" | "stderr"
        public let data: Data
        public init(event: String, data: Data) {
            self.event = event
            self.data = data
        }
    }

    public enum StreamError: Error, Equatable {
        case notConfigured
        case malformedURL
        case unexpectedFrame(String)
        case peerClosed(code: Int)
        case transport(String)
    }

    private let config: Configuration
    private let urlSession: URLSession

    public init(config: Configuration, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    /// Subscribes to the broadcast topic `realtime:term:<sessionId>`.
    /// `onChunk` fires once per `stdout` / `stderr` broadcast frame
    /// the helper publishes. `onDisconnect` fires exactly once when
    /// the connection ends (network failure, peer close, or
    /// `cancel()` on the returned token). Both callbacks may be
    /// invoked from background queues; the caller is responsible
    /// for thread-confinement on the consumer side (typically
    /// `MainActor` hop before touching UI).
    @discardableResult
    public func subscribeTerminal(
        sessionId: String,
        onChunk: @escaping @Sendable (TerminalChunk) -> Void,
        onDisconnect: @escaping @Sendable (Error?) -> Void
    ) -> Cancellable {
        let sub = TerminalSubscription(
            sessionId: sessionId,
            config: config,
            urlSession: urlSession,
            onChunk: onChunk,
            onDisconnect: onDisconnect
        )
        sub.start()
        return sub
    }

    /// Returned from `subscribeTerminal`; call `cancel()` to tear
    /// down the WebSocket and stop heartbeat scheduling.
    /// Idempotent — calling twice is safe.
    public protocol Cancellable: Sendable {
        func cancel()
    }

    // MARK: - URL builder

    /// Builds the Supabase Realtime WebSocket URL. Exposed as a
    /// static helper so unit tests can pin the wire shape without
    /// constructing the full stream actor.
    public static func makeWebSocketURL(config: Configuration) throws -> URL {
        if config.supabaseURL.isEmpty || config.supabaseAnonKey.isEmpty {
            throw StreamError.notConfigured
        }
        // Swap http→ws / https→wss so we can reuse the same project
        // URL that the REST client uses.
        let httpURL = config.supabaseURL
        let wsURL: String
        if httpURL.hasPrefix("https://") {
            wsURL = "wss://" + String(httpURL.dropFirst("https://".count))
        } else if httpURL.hasPrefix("http://") {
            wsURL = "ws://" + String(httpURL.dropFirst("http://".count))
        } else {
            throw StreamError.malformedURL
        }
        guard var comps = URLComponents(string: wsURL) else {
            throw StreamError.malformedURL
        }
        // Strip any trailing slash on the path before appending so
        // we don't end up with `//realtime/...`.
        var path = comps.path
        if path.hasSuffix("/") { path.removeLast() }
        comps.path = path + "/realtime/v1/websocket"
        comps.queryItems = [
            URLQueryItem(name: "apikey", value: config.supabaseAnonKey),
            URLQueryItem(name: "vsn", value: "2.0.0"),
        ]
        guard let url = comps.url else {
            throw StreamError.malformedURL
        }
        return url
    }

    // MARK: - Frame encoders (static, unit-testable)

    /// Phoenix vsn-2.0.0 array frame for joining a broadcast topic.
    ///
    /// `realtime:<topic>` is the Phoenix convention; the helper-side
    /// `SupabaseRealtimeBroadcastSink` POSTs to topic `term:<sid>`
    /// (no `realtime:` prefix in HTTP body — the server adds it
    /// internally for routing).
    public static func encodePhxJoinFrame(
        joinRef: String,
        ref: String,
        sessionId: String
    ) throws -> Data {
        let frame: [Any] = [
            joinRef,
            ref,
            "realtime:term:\(sessionId)",
            "phx_join",
            [
                "config": [
                    "broadcast": [
                        "ack": false,
                        "self": false,  // we only want chunks from the helper, not our own
                    ],
                    "presence": ["enabled": false],
                    "postgres_changes": [] as [Any],
                    "private": false,
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: frame, options: [])
    }

    /// Phoenix heartbeat — `phoenix` is the system topic; `null`
    /// joinRef because heartbeats are connection-scoped, not
    /// channel-scoped.
    public static func encodeHeartbeatFrame(ref: String) throws -> Data {
        let frame: [Any] = [
            NSNull(),
            ref,
            "phoenix",
            "heartbeat",
            [:] as [String: Any],
        ]
        return try JSONSerialization.data(withJSONObject: frame, options: [])
    }

    // MARK: - Incoming frame decoder (static, unit-testable)

    /// Parses a raw vsn-2.0.0 array frame into structured fields.
    /// Returns nil for non-broadcast / system frames the subscriber
    /// doesn't need to surface (heartbeat replies, phx_reply etc.).
    /// Throws on completely malformed wire shape.
    public static func decodeBroadcastChunk(from data: Data) throws -> TerminalChunk? {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw StreamError.unexpectedFrame("not JSON: \(error)")
        }
        guard let arr = obj as? [Any], arr.count >= 5 else {
            throw StreamError.unexpectedFrame("not a vsn-2.0.0 array frame")
        }
        guard let event = arr[3] as? String else {
            throw StreamError.unexpectedFrame("event field not a string")
        }
        // We only care about broadcast frames; everything else
        // (phx_reply, phx_close, heartbeat ack) is ignored.
        guard event == "broadcast" else {
            return nil
        }
        guard let outer = arr[4] as? [String: Any] else {
            throw StreamError.unexpectedFrame("broadcast payload not a dict")
        }
        // Supabase wraps the user's event under payload.event and
        // the user's payload under payload.payload. Defensive: in
        // some Phoenix versions the user's event lands at the
        // outer level — accept either.
        let innerEvent = (outer["event"] as? String) ?? event
        let innerPayload: [String: Any]
        if let nested = outer["payload"] as? [String: Any] {
            innerPayload = nested
        } else {
            innerPayload = outer
        }
        guard let b64 = innerPayload["data_b64"] as? String,
              let bytes = Data(base64Encoded: b64)
        else {
            throw StreamError.unexpectedFrame("payload missing data_b64")
        }
        return TerminalChunk(event: innerEvent, data: bytes)
    }
}

// MARK: - Subscription

private final class TerminalSubscription: RemoteSessionEventStream.Cancellable, @unchecked Sendable {

    private let sessionId: String
    private let config: RemoteSessionEventStream.Configuration
    private let urlSession: URLSession
    private let onChunk: @Sendable (RemoteSessionEventStream.TerminalChunk) -> Void
    private let onDisconnect: @Sendable (Error?) -> Void

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var disconnectFired = false
    private var refCounter: UInt64 = 0
    private let joinRef: String = String(UInt64.random(in: 1...UInt64.max))

    init(
        sessionId: String,
        config: RemoteSessionEventStream.Configuration,
        urlSession: URLSession,
        onChunk: @escaping @Sendable (RemoteSessionEventStream.TerminalChunk) -> Void,
        onDisconnect: @escaping @Sendable (Error?) -> Void
    ) {
        self.sessionId = sessionId
        self.config = config
        self.urlSession = urlSession
        self.onChunk = onChunk
        self.onDisconnect = onDisconnect
    }

    func start() {
        do {
            let url = try RemoteSessionEventStream.makeWebSocketURL(config: config)
            let wsTask = urlSession.webSocketTask(with: url)
            lock.lock()
            task = wsTask
            lock.unlock()
            wsTask.resume()
            // Send phx_join immediately, then start receive + heartbeat loops.
            Task { await self.joinAndPump(wsTask) }
        } catch {
            fireDisconnect(error)
        }
    }

    func cancel() {
        lock.lock()
        let t = task
        let hb = heartbeatTask
        task = nil
        heartbeatTask = nil
        lock.unlock()
        hb?.cancel()
        t?.cancel(with: .normalClosure, reason: nil)
        fireDisconnect(nil)
    }

    // MARK: - private

    private func nextRef() -> String {
        lock.lock(); defer { lock.unlock() }
        refCounter += 1
        return String(refCounter)
    }

    private func fireDisconnect(_ err: Error?) {
        lock.lock()
        let already = disconnectFired
        disconnectFired = true
        lock.unlock()
        if !already {
            onDisconnect(err)
        }
    }

    private func joinAndPump(_ task: URLSessionWebSocketTask) async {
        // Send phx_join.
        do {
            let frame = try RemoteSessionEventStream.encodePhxJoinFrame(
                joinRef: joinRef,
                ref: nextRef(),
                sessionId: sessionId
            )
            try await task.send(.data(frame))
        } catch {
            fireDisconnect(error)
            return
        }

        // Start heartbeat task.
        let interval = config.heartbeatInterval
        let hb: Task<Void, Never> = Task { [weak self] in
            await self?.heartbeatLoop(interval: interval)
            return ()
        }
        lock.lock(); heartbeatTask = hb; lock.unlock()

        // Receive loop runs inline (won't return until disconnect).
        await receiveLoop(task)
    }

    private func heartbeatLoop(interval: TimeInterval) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }
            lock.lock()
            let t = task
            let cancelled = (t == nil)
            lock.unlock()
            if cancelled { return }
            do {
                let frame = try RemoteSessionEventStream.encodeHeartbeatFrame(
                    ref: nextRef()
                )
                try await t?.send(.data(frame))
            } catch {
                fireDisconnect(error)
                return
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                fireDisconnect(error)
                return
            }
            let data: Data
            switch message {
            case .data(let d):
                data = d
            case .string(let s):
                data = Data(s.utf8)
            @unknown default:
                continue
            }
            do {
                if let chunk = try RemoteSessionEventStream.decodeBroadcastChunk(from: data) {
                    onChunk(chunk)
                }
            } catch {
                // Malformed frame: log via fire-and-forget (no
                // disconnect — Realtime sends many system frames
                // we ignore by design). The static decoder only
                // throws on completely garbled wire shape, which
                // should not happen on a connected channel.
                continue
            }
        }
    }
}
