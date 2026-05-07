import Foundation

/// Async wrapper around URLSession that posts to
/// `<supabase_url>/rest/v1/rpc/<name>` with a 2.5 s per-request
/// timeout (mirrors v1.12.2's M2 backport on the Python side).
///
/// Phase 4E Slice 3: `RemoteAgentCloud.tick()` and `EventUploader`
/// dispatch through this. Tests inject a `RPCCallable` closure
/// instead of constructing the live caller — the body of `call(_:_:)`
/// is exercised by `SupabaseRPCCallerTests` directly with a stub
/// session.

/// Protocol so RemoteAgentCloud + EventUploader can be tested
/// against a stub. Returned `Any` is the JSON body decoded via
/// `JSONSerialization.jsonObject(...)` (mirrors Python's
/// `requests.Response.json()`); callers cast appropriately.
public protocol RPCCallable: Sendable {
    /// Throws on transport / HTTP / decode failure. Returns the
    /// decoded JSON body — `[Any]` for list-returning RPCs (e.g.
    /// `remote_helper_pull_commands`), `[String: Any]` for object
    /// RPCs, or `NSNull` when the body is empty.
    func call(_ rpcName: String, params: [String: Any]) async throws -> Any
}

public enum SupabaseRPCError: Error, Equatable {
    /// Helper is unpaired or supabase_url / anon_key missing.
    case notConfigured
    /// HTTP transport error (timeout, connection refused, etc.).
    case transport(String)
    /// Server returned non-2xx. Body is the response payload (may
    /// contain `Device not found or unauthorized` when the user
    /// has Remote Control disabled — callers should swallow this
    /// and keep the daemon running).
    case http(status: Int, body: String)
    /// JSON-decode failure on the response body.
    case decode(String)
}

public actor SupabaseRPCCaller: RPCCallable {

    /// Per-request timeout. Matches v1.12.2 / Mac M2 backport: a
    /// single Supabase RPC must not stall the daemon's 1 s tick
    /// for longer than 2.5 s. Configurable for tests.
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
            // No on-disk cache: helper is sandbox-adjacent (LaunchAgent)
            // and Supabase RPC bodies are not idempotent.
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    public func call(_ rpcName: String, params: [String: Any]) async throws -> Any {
        let cfg = configProvider()
        guard cfg.isPaired else {
            throw SupabaseRPCError.notConfigured
        }
        guard let baseURL = URL(string: cfg.supabaseURL) else {
            throw SupabaseRPCError.notConfigured
        }
        let endpoint = baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("rpc")
            .appendingPathComponent(rpcName)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(cfg.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(cfg.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: params, options: [])
        } catch {
            throw SupabaseRPCError.transport("encode params: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SupabaseRPCError.transport("\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseRPCError.transport("non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseRPCError.http(status: http.statusCode, body: body)
        }
        if data.isEmpty {
            return NSNull()
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw SupabaseRPCError.decode("\(error)")
        }
    }
}
