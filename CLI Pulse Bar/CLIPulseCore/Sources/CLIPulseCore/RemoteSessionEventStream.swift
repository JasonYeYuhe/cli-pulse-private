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
        /// R0 (B3): the signed-in user's Supabase access_token (JWT). Attached
        /// to the phx_join payload ONLY for PRIVATE (`pterm:`) joins so the
        /// realtime.messages read-RLS can scope by owner. nil → the public
        /// (`term:`) anon path, byte-identical to pre-R0 behavior. Re-sent on
        /// token refresh via `Cancellable.updateAccessToken`.
        public let accessToken: String?
        /// Heartbeat cadence. Supabase Realtime times out at 30 s
        /// of silence; 25 s default leaves a comfortable margin.
        public let heartbeatInterval: TimeInterval

        public init(
            supabaseURL: String,
            supabaseAnonKey: String,
            accessToken: String? = nil,
            heartbeatInterval: TimeInterval = 25
        ) {
            self.supabaseURL = supabaseURL
            self.supabaseAnonKey = supabaseAnonKey
            self.accessToken = accessToken
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
        /// R0 (S4): a PRIVATE join was rejected by read-RLS / a bad or expired
        /// token (phx_reply `status:"error"`). Delivered via `onDisconnect` so
        /// the Coordinator can refresh-and-retry once, then surface a fatal
        /// fallback instead of hanging on a permanently blank terminal.
        case joinRejected(reason: String)
    }

    /// R0 (S4): result of `decodeJoinReply` — a phx_reply to our channel's join.
    public enum JoinReply: Equatable {
        /// Join (or a later access_token push) accepted.
        case ok
        /// Join rejected (RLS / auth); `reason` is the server's phx_reply reason.
        case error(reason: String)
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
        isPrivate: Bool = false,
        onChunk: @escaping @Sendable (TerminalChunk) -> Void,
        onDisconnect: @escaping @Sendable (Error?) -> Void
    ) -> Cancellable {
        let sub = TerminalSubscription(
            sessionId: sessionId,
            isPrivate: isPrivate,
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
        /// R0 (B3): push a refreshed user access_token onto a live PRIVATE
        /// join. Realtime caches the per-subscriber RLS decision until a new
        /// token arrives, so a public-fallback subscription ignores this
        /// (no-op). Safe to call before the socket is up — the token is
        /// stored and used on the next (re)join.
        func updateAccessToken(_ token: String?)
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

    /// The broadcast topic name for a session, WITHOUT the Phoenix
    /// `realtime:` prefix. R0: a PRIVATE session uses the distinct `pterm:`
    /// prefix (RLS-governed) — a single `term:` topic can't be made
    /// private-only because public joins always bypass RLS. A non-private
    /// session keeps the legacy public `term:` topic for old helpers.
    public static func topic(for sessionId: String, isPrivate: Bool) -> String {
        (isPrivate ? "pterm:" : "term:") + sessionId
    }

    /// Phoenix vsn-2.0.0 array frame for joining a broadcast topic.
    ///
    /// `realtime:<topic>` is the Phoenix convention; the helper-side
    /// broadcast sink POSTs to the bare topic (`term:<sid>` /
    /// `pterm:<sid>` — the server adds the `realtime:` prefix internally
    /// for routing).
    ///
    /// R0 (B3): for a PRIVATE join we set `config.private = true` and attach
    /// the user's `access_token` at the payload top level (sibling of
    /// `config`) so Realtime evaluates the realtime.messages read-RLS as the
    /// owner. For a PUBLIC join the frame is byte-identical to pre-R0
    /// (`private:false`, NO `access_token`) → zero regression while the R0
    /// flag is off.
    public static func encodePhxJoinFrame(
        joinRef: String,
        ref: String,
        sessionId: String,
        isPrivate: Bool = false,
        accessToken: String? = nil
    ) throws -> Data {
        var payload: [String: Any] = [
            "config": [
                "broadcast": [
                    "ack": false,
                    "self": false,  // we only want chunks from the helper, not our own
                ],
                "presence": ["enabled": false],
                "postgres_changes": [] as [Any],
                "private": isPrivate,
            ],
        ]
        // Token only on the private path, and only when present — keeps the
        // public frame identical to today.
        if isPrivate, let accessToken, !accessToken.isEmpty {
            payload["access_token"] = accessToken
        }
        let frame: [Any] = [
            joinRef,
            ref,
            "realtime:\(topic(for: sessionId, isPrivate: isPrivate))",
            "phx_join",
            payload,
        ]
        return try JSONSerialization.data(withJSONObject: frame, options: [])
    }

    /// Phoenix `access_token` frame — pushes a refreshed user JWT onto a live
    /// PRIVATE channel so Realtime re-evaluates the cached RLS decision. Sent
    /// on token refresh (the realtime topic must match the live join).
    public static func encodeAccessTokenFrame(
        joinRef: String,
        ref: String,
        sessionId: String,
        accessToken: String
    ) throws -> Data {
        let frame: [Any] = [
            joinRef,
            ref,
            "realtime:\(topic(for: sessionId, isPrivate: true))",
            "access_token",
            ["access_token": accessToken],
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

    /// Inner event names a terminal broadcast frame may carry. The producer
    /// (helper `realtime_broadcast.py`, `ALLOWED_EVENTS`) only ever emits these
    /// three; any other inner event on the still-public `term:` channel is an
    /// injection attempt or protocol drift and is rejected rather than blindly
    /// surfaced to the local terminal.
    public static let allowedInnerEvents: Set<String> = ["stdout", "stderr", "tail_snapshot_result"]

    /// Hard ceiling on the decoded byte count of a single terminal chunk. The
    /// producer coalesces stdout/stderr to `MAX_MESSAGE_BYTES = 48 KiB`
    /// pre-base64 and caps snapshots at 8 KiB, so 256 KiB is comfortable
    /// headroom while still rejecting an abusive multi-megabyte frame BEFORE it
    /// is base64-decoded/allocated — cheap DoS protection on the public path.
    public static let maxDecodedChunkBytes = 256 * 1024

    /// Parses a raw vsn-2.0.0 array frame into structured fields.
    /// Returns nil for non-broadcast / system frames the subscriber
    /// doesn't need to surface (heartbeat replies, phx_reply etc.).
    /// Throws on completely malformed wire shape, a disallowed inner event,
    /// or an over-ceiling payload.
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
        // Strict allow-list: never surface an inner event the producer can't emit.
        guard allowedInnerEvents.contains(innerEvent) else {
            throw StreamError.unexpectedFrame("disallowed inner event: \(innerEvent)")
        }
        let innerPayload: [String: Any]
        if let nested = outer["payload"] as? [String: Any] {
            innerPayload = nested
        } else {
            innerPayload = outer
        }
        guard let b64 = innerPayload["data_b64"] as? String else {
            throw StreamError.unexpectedFrame("payload missing data_b64")
        }
        // Reject an over-ceiling frame BEFORE allocating: base64 of N bytes is
        // ~ceil(N/3)*4 chars, so a base64 string longer than that for the
        // ceiling can only decode to something too large.
        guard b64.utf8.count <= (maxDecodedChunkBytes + 2) / 3 * 4 else {
            throw StreamError.unexpectedFrame("oversized chunk: base64 length \(b64.utf8.count)")
        }
        guard let bytes = Data(base64Encoded: b64) else {
            throw StreamError.unexpectedFrame("payload data_b64 not valid base64")
        }
        guard bytes.count <= maxDecodedChunkBytes else {
            throw StreamError.unexpectedFrame("oversized chunk: \(bytes.count) bytes")
        }
        return TerminalChunk(event: innerEvent, data: bytes)
    }

    /// R0 (S4): a Phoenix `phx_reply` to OUR channel's join (or a later
    /// access_token push), matched by `ourJoinRef`. Returns nil for any other
    /// frame (broadcasts, heartbeat replies with a `null`/different joinRef,
    /// presence). A PRIVATE join rejected by read-RLS / a bad token replies
    /// `status:"error"` — the caller surfaces it and stops hanging on a blank
    /// terminal instead of ignoring the reply (the pre-S4 behavior). Mirrors the
    /// Android `decodeJoinReply`.
    public static func decodeJoinReply(from data: Data, ourJoinRef: String) -> JoinReply? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let arr = obj as? [Any], arr.count >= 5 else {
            return nil
        }
        guard (arr[3] as? String) == "phx_reply" else { return nil }
        // Only our channel's replies carry our joinRef in slot 0; heartbeat
        // acks (phoenix topic) carry a null joinRef.
        guard (arr[0] as? String) == ourJoinRef else { return nil }
        guard let payload = arr[4] as? [String: Any] else { return nil }
        switch payload["status"] as? String {
        case "ok":
            return .ok
        case "error":
            let response = payload["response"] as? [String: Any]
            let reason = (response?["reason"] as? String) ?? ""
            return .error(reason: reason.isEmpty ? "join rejected" : reason)
        default:
            return nil
        }
    }
}

// MARK: - Subscription

private final class TerminalSubscription: RemoteSessionEventStream.Cancellable, @unchecked Sendable {

    private let sessionId: String
    private let isPrivate: Bool
    private let config: RemoteSessionEventStream.Configuration
    private let urlSession: URLSession
    private let onChunk: @Sendable (RemoteSessionEventStream.TerminalChunk) -> Void
    private let onDisconnect: @Sendable (Error?) -> Void

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var disconnectFired = false
    private var refCounter: UInt64 = 0
    /// R0 (B3): the current user access_token (mutable — refresh re-sends it on
    /// the live private channel). Seeded from config; guarded by `lock`.
    private var accessToken: String?
    private let joinRef: String = String(UInt64.random(in: 1...UInt64.max))

    init(
        sessionId: String,
        isPrivate: Bool,
        config: RemoteSessionEventStream.Configuration,
        urlSession: URLSession,
        onChunk: @escaping @Sendable (RemoteSessionEventStream.TerminalChunk) -> Void,
        onDisconnect: @escaping @Sendable (Error?) -> Void
    ) {
        self.sessionId = sessionId
        self.isPrivate = isPrivate
        self.config = config
        self.urlSession = urlSession
        self.accessToken = config.accessToken
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

    func updateAccessToken(_ token: String?) {
        // Store the token (used on any future rejoin). For a LIVE private
        // channel, also push an access_token frame so Realtime re-evaluates
        // the cached RLS decision right away. Public subscriptions are a no-op
        // (no token in play). Best-effort: a failed push isn't fatal — the
        // next reconnect rejoins with the stored token.
        lock.lock()
        accessToken = token
        let t = task
        lock.unlock()
        guard isPrivate, let t, let token, !token.isEmpty else { return }
        let ref = nextRef()
        let sid = sessionId
        let jref = joinRef
        Task {
            do {
                let frame = try RemoteSessionEventStream.encodeAccessTokenFrame(
                    joinRef: jref, ref: ref, sessionId: sid, accessToken: token)
                try await t.send(.data(frame))
            } catch {
                // Non-fatal; reconnect will rejoin with the stored token.
            }
        }
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
        // Send phx_join. Snapshot the current token under lock so a refresh
        // racing the join uses one consistent value.
        do {
            lock.lock()
            let token = accessToken
            lock.unlock()
            let frame = try RemoteSessionEventStream.encodePhxJoinFrame(
                joinRef: joinRef,
                ref: nextRef(),
                sessionId: sessionId,
                isPrivate: isPrivate,
                accessToken: token
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
            // R0 (S4): a phx_reply error on OUR join = a rejected PRIVATE join
            // (read-RLS / bad or expired token). Surface it as a disconnect so
            // the Coordinator can refresh-and-retry once, then fall back — a
            // public `term:` join always replies `ok`, so this is inert pre-cutover.
            if case .error(let reason)? = RemoteSessionEventStream.decodeJoinReply(
                from: data, ourJoinRef: joinRef) {
                fireDisconnect(RemoteSessionEventStream.StreamError.joinRejected(reason: reason))
                return
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
