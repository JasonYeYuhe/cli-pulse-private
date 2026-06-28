import Foundation

/// Resolves the user's Claude Code SUBSCRIPTION OAuth access token so a managed
/// `claude` session the helper spawns runs on the user's plan (e.g. Max) instead
/// of falling back to "Claude API" pay-per-token.
///
/// Why this is needed (proven 2026-06-20, feedback_managed_claude_agy_auth):
/// `claude` reads the macOS Keychain item `Claude Code-credentials` FIRST, but in
/// the LaunchAgent-spawned context that read doesn't reliably yield the
/// subscription (the keychain item's refresh token is often empty/expired on this
/// setup, and the GUI keychain ACL/session differs). The working refresh token
/// lives in the FILE `~/.claude/.credentials.json`. So the helper reads the file,
/// refreshes against the public Claude Code OAuth client, persists the ROTATED
/// refresh token back atomically, and injects the access token into the child.
///
/// Injection uses an inherited file descriptor
/// (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`) rather than a plain env var: the
/// env var would leak the Max bearer to every tool subprocess the agent runs
/// (and to same-user `ps eww`); the FD is read once by claude at startup.
///
/// Entirely best-effort: any failure returns nil and the caller leaves auth to
/// claude's own ambient resolution — i.e. no worse than before this existed.
public enum ClaudeOAuthInjector {

    /// Exact env var Claude Code reads the token FD from. The name matters —
    /// `CLAUDE_CODE_OAUTH_TOKEN_FD` does NOT work (feedback_managed_claude_agy_auth).
    public static let fdEnvVar = "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"

    /// Well-known public Claude Code OAuth client id — REQUIRED in the refresh
    /// body (a bare body without it 400s).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// console first, api as fallback (feedback_managed_claude_agy_auth).
    static let refreshEndpoints = [
        "https://console.anthropic.com/v1/oauth/token",
        "https://api.anthropic.com/v1/oauth/token",
    ]

    /// Refresh proactively this far before the stored expiry.
    static let expiryMarginSeconds: TimeInterval = 120

    public static func credentialsFileURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".claude/.credentials.json")
    }

    // MARK: - Public entry point

    /// A fresh subscription access token (refreshing + persisting the rotated
    /// refresh token if the stored one is expired), or nil when there are no
    /// usable credentials / the refresh failed.
    public static func resolveAccessToken(
        fileURL: URL = credentialsFileURL(),
        now: Date = Date(),
        http: TokenHTTPClient = URLSessionTokenHTTPClient()
    ) -> String? {
        guard var creds = readCredentials(at: fileURL) else { return nil }

        // Still-valid stored token → use it directly (no network).
        if let token = creds.accessToken, !token.isEmpty,
           creds.expiresAt.timeIntervalSince(now) > expiryMarginSeconds {
            return token
        }

        // Expired/empty → need the refresh token to mint a new one.
        guard let rt = creds.refreshToken, !rt.isEmpty else {
            return nonEmpty(creds.accessToken)
        }
        guard let refreshed = refresh(refreshToken: rt, http: http) else {
            // Refresh failed: hand back the (possibly stale) stored token as a
            // last resort. If it's truly dead claude 401s and falls back to its
            // own auth — same as the pre-injection behaviour.
            return nonEmpty(creds.accessToken)
        }

        // The refresh token ROTATES server-side; persist the new one or the old
        // one is dead. If persist fails, log loudly — the next expired-token
        // spawn would otherwise refresh with a dead RT and fall back to ambient.
        let persisted = persist(
            accessToken: refreshed.accessToken,
            refreshToken: nonEmpty(refreshed.refreshToken) ?? creds.refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(refreshed.expiresIn)),
            to: fileURL,
            expectedPriorRefreshToken: rt
        )
        if !persisted {
            logError("could not persist the rotated Claude refresh token to \(fileURL.path); future refresh may fail")
        }
        return refreshed.accessToken
    }

    /// Best-effort error sink (helper stderr → helper.err.log). Overridable for tests.
    static var logError: (String) -> Void = { msg in
        FileHandle.standardError.write(Data("[ClaudeOAuthInjector] \(msg)\n".utf8))
    }

    // MARK: - Credentials file (preserves unknown fields)

    struct Credentials {
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Date
        /// Whole parsed root, kept so persist() rewrites the file without
        /// dropping scopes / subscriptionType / any future fields.
        var root: [String: Any]
    }

    static func readCredentials(at url: URL) -> Credentials? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let root = obj as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any]
        else { return nil }
        let rawExpiry = (oauth["expiresAt"] as? NSNumber)?.doubleValue
            ?? (oauth["expiresAt"] as? Double)
            ?? 0
        return Credentials(
            accessToken: oauth["accessToken"] as? String,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: epochToDate(rawExpiry),
            root: root
        )
    }

    /// Claude Code writes `expiresAt` in MILLISECONDS, but some variants use
    /// seconds. Disambiguate by magnitude: a real expiry is "now-ish", so a value
    /// >= 1e12 is ms (1e12 s ≈ year 33658), else seconds. Misreading a seconds
    /// value as ms would land in 1970 and force needless refreshes.
    static func epochToDate(_ raw: Double) -> Date {
        guard raw > 0 else { return Date(timeIntervalSince1970: 0) }
        let seconds = raw >= 1_000_000_000_000 ? raw / 1000.0 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    /// Persist the refreshed tokens. Re-reads the file FIRST so a concurrent
    /// `claude` write to other fields isn't clobbered by our pre-refresh snapshot
    /// (lost-update guard — atomic replace prevents torn JSON, not stale data).
    /// Returns false on any failure so the caller can log the (serious) loss of a
    /// rotated refresh token. Forces 0600 on the final path.
    @discardableResult
    static func persist(
        accessToken: String?, refreshToken: String?, expiresAt: Date, to url: URL,
        expectedPriorRefreshToken: String? = nil
    ) -> Bool {
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        var oauth = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
        // Conflict detection: if the on-disk refresh token changed since we read
        // it, a concurrent `claude` already refreshed + rotated it. Its token is
        // the valid one now — do NOT clobber it with ours (that would invalidate
        // the live login). Bail: this session still uses the access token we
        // obtained in-memory; the on-disk winner's credentials stay intact.
        if let expectedPriorRefreshToken,
           let currentRT = oauth["refreshToken"] as? String,
           !currentRT.isEmpty,
           currentRT != expectedPriorRefreshToken {
            return true
        }
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000.0)  // ms (Claude format)
        root["claudeAiOauth"] = oauth
        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".credentials.json.tmp-\(UUID().uuidString)")
        do {
            try out.write(to: tmp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            // replaceItemAt preserves the ORIGINAL file's metadata, so force 0600
            // on the final path (a previously-0644 file would otherwise stay 0644).
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    // MARK: - Refresh

    struct RefreshResult {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
    }

    static func refresh(refreshToken: String, http: TokenHTTPClient) -> RefreshResult? {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        for endpoint in refreshEndpoints {
            guard let url = URL(string: endpoint) else { continue }
            guard let resp = http.postJSON(url: url, body: bodyData, timeout: 10) else { continue }
            guard resp.status == 200,
                  let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
                  let access = obj["access_token"] as? String, !access.isEmpty
            else { continue }
            let expiresIn = (obj["expires_in"] as? NSNumber)?.intValue
                ?? (obj["expires_in"] as? Int)
                ?? 28800  // 8h default
            return RefreshResult(
                accessToken: access,
                refreshToken: obj["refresh_token"] as? String,
                expiresIn: expiresIn
            )
        }
        return nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

// MARK: - Injectable synchronous HTTP

/// Minimal synchronous POST-JSON surface so the spawn path (which is synchronous)
/// can refresh without an async hop, and tests can stub the network.
public protocol TokenHTTPClient {
    /// Returns (status, body) or nil on transport error / timeout.
    func postJSON(url: URL, body: Data, timeout: TimeInterval) -> (status: Int, data: Data)?
}

public struct URLSessionTokenHTTPClient: TokenHTTPClient {
    public init() {}
    public func postJSON(url: URL, body: Data, timeout: TimeInterval) -> (status: Int, data: Data)? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        req.timeoutInterval = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg)
        let sem = DispatchSemaphore(value: 0)
        var result: (status: Int, data: Data)?
        let task = session.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse {
                result = (http.statusCode, data ?? Data())
            }
            sem.signal()
        }
        task.resume()
        // Bound the wait so a hung refresh can't wedge a session spawn.
        if sem.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            return nil
        }
        return result
    }
}
