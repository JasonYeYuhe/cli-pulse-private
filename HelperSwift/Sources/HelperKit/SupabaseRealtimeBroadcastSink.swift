import Foundation

/// Concrete `TerminalBroadcastSink` that POSTs redacted terminal
/// chunks to the Supabase Realtime HTTP broadcast endpoint
/// `<supabase_url>/realtime/v1/api/broadcast`. v1.25 Phase 2c
/// slice 3 of the in-app-terminal plan (§Phase 2c — "Supabase
/// Realtime BROADCAST seam").
///
/// **Wire shape (mirrors Mac TerminalView's `window.pushChunk(b64)`
/// JS bridge for iOS subscriber parity):**
///
/// ```
/// POST <supabase_url>/realtime/v1/api/broadcast
/// apikey: <supabase_anon_key>
/// Authorization: Bearer <supabase_anon_key>
/// Content-Type: application/json
///
/// {
///   "messages": [{
///     "topic":   "term:<session_id>",
///     "event":   "stdout"|"stderr",
///     "payload": {
///       "session_id": "<session_id>",
///       "data_b64":   "<base64 of redactedBytes>"
///     }
///   }]
/// }
/// ```
///
/// The publisher above this sink has already run `Redactor.redact`
/// over `redactedBytes` (Codex HIGH H4 — redact-at-write invariant
/// pinned by `TerminalBroadcastPublisherTests`). This sink MUST NOT
/// re-encode raw bytes through any side path.
///
/// Auth: mirrors `SupabaseRPCCaller` — `apikey` + `Authorization:
/// Bearer` headers, both set to the project anon key. Realtime's
/// broadcast HTTP endpoint accepts the anon key for non-private
/// topics. **Topic confidentiality rests on the server-generated
/// UUID `session_id`** (effectively unguessable); payload
/// confidentiality rests on `Redactor.redact` upstream. The helper
/// pairing JWT (`helper_secret`) is NOT sent here because Realtime
/// broadcast is a project-level endpoint — per-device authorization
/// belongs to the RPC path that opens the session, not the streaming
/// path.
///
/// Failure modes:
///   * Helper unpaired (anon key / URL empty) → `SinkError.notConfigured`.
///   * Transport (timeout, connection refused, DNS) → `.transport`.
///   * Non-2xx response → `.http(status:, body:)`.
///
/// Any `throw` from `publish` propagates to
/// `TerminalBroadcastPublisher.drain`, which counts the chunk as
/// `droppedSinceStart` and continues — **the publisher never
/// retries the same chunk** (back-pressuring the drain loop is
/// worse than losing one chunk; reconnect-snapshot is the recovery
/// path).
public struct SupabaseRealtimeBroadcastSink: TerminalBroadcastSink {

    public enum SinkError: Error, Equatable {
        case notConfigured
        case transport(String)
        case http(status: Int, body: String)
    }

    /// Per-request timeout. Matches `SupabaseRPCCaller`'s 2.5 s
    /// default so a stalled Realtime POST can't park the publisher's
    /// drain task longer than one daemon tick.
    public let requestTimeout: TimeInterval

    private let configProvider: @Sendable () -> HelperConfigStore.CloudConfig
    private let session: URLSession

    public init(
        configProvider: @escaping @Sendable () -> HelperConfigStore.CloudConfig,
        requestTimeout: TimeInterval = 2.5,
        session: URLSession? = nil
    ) {
        self.configProvider = configProvider
        self.requestTimeout = requestTimeout
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = requestTimeout
            cfg.timeoutIntervalForResource = requestTimeout
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    public func publish(
        sessionId: String,
        channel: String,
        event: String,
        redactedBytes: Data
    ) async throws {
        let cfg = configProvider()
        guard cfg.isPaired else {
            throw SinkError.notConfigured
        }
        guard let baseURL = URL(string: cfg.supabaseURL) else {
            throw SinkError.notConfigured
        }
        let endpoint = baseURL
            .appendingPathComponent("realtime")
            .appendingPathComponent("v1")
            .appendingPathComponent("api")
            .appendingPathComponent("broadcast")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(cfg.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(cfg.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let dataB64 = redactedBytes.base64EncodedString()
        let body: [String: Any] = [
            "messages": [[
                "topic": channel,
                "event": event,
                "payload": [
                    "session_id": sessionId,
                    "data_b64": dataB64,
                ],
            ]],
        ]

        do {
            req.httpBody = try JSONSerialization.data(
                withJSONObject: body, options: []
            )
        } catch {
            throw SinkError.transport("encode body: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SinkError.transport("\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SinkError.transport("non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw SinkError.http(status: http.statusCode, body: bodyStr)
        }
    }
}
