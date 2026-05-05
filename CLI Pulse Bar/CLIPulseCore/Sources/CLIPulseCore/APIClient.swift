import Foundation
import CryptoKit
import os

private let apiLogger = Logger(subsystem: "com.clipulse", category: "APIClient")

public actor APIClient {
    private let supabaseURL: String
    private let supabaseAnonKey: String

    private var accessToken: String?
    private var refreshToken: String?
    public private(set) var userId: String?

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Called after a successful token refresh with (newAccessToken, newRefreshToken).
    /// Set by AppState to persist rotated tokens to Keychain.
    public var onTokenRefreshed: (@Sendable (String, String) -> Void)?

    public init(
        token: String? = nil,
        supabaseURL: String? = nil,
        supabaseAnonKey: String? = nil
    ) {
        self.accessToken = token
        self.supabaseURL = supabaseURL
            ?? Bundle.main.infoDictionary?["SUPABASE_URL"] as? String
            ?? ProcessInfo.processInfo.environment["CLI_PULSE_SUPABASE_URL"]
            ?? "https://gkjwsxotmwrgqsvfijzs.supabase.co"
        self.supabaseAnonKey = supabaseAnonKey
            ?? Bundle.main.infoDictionary?["SUPABASE_ANON_KEY"] as? String
            ?? ProcessInfo.processInfo.environment["CLI_PULSE_SUPABASE_ANON_KEY"]
            ?? ""
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    public func updateToken(_ token: String?) {
        self.accessToken = token
    }

    public func updateRefreshToken(_ token: String?) {
        self.refreshToken = token
    }

    public func setTokenRefreshHandler(_ handler: @escaping @Sendable (String, String) -> Void) {
        self.onTokenRefreshed = handler
    }

    public func getToken() -> String? {
        return accessToken
    }

    public func getRefreshToken() -> String? {
        return refreshToken
    }

    // MARK: - Token Refresh

    /// Attempt to refresh the access token using the stored refresh token.
    /// Returns the new access token and refresh token, or throws on failure.
    public func refreshAccessToken() async throws -> (accessToken: String, refreshToken: String) {
        guard let currentRefreshToken = refreshToken else {
            throw APIError.tokenExpired
        }
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=refresh_token") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try encoder.encode(RefreshTokenRequest(refresh_token: currentRefreshToken))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            // Refresh failed — token is invalid
            self.accessToken = nil
            self.refreshToken = nil
            throw APIError.tokenExpired
        }

        let auth = try decode(SupabaseAuthResponse.self, from: data)
        let newAccess = auth.access_token
        let newRefresh = auth.refresh_token ?? currentRefreshToken

        self.accessToken = newAccess
        self.refreshToken = newRefresh

        // Notify so caller can persist to Keychain
        onTokenRefreshed?(newAccess, newRefresh)

        return (newAccess, newRefresh)
    }

    // MARK: - Sign Out (server-side token revocation)

    public func signOutServer() async {
        // Capture token before clearing to avoid race with new sign-in
        let tokenToRevoke = accessToken
        self.accessToken = nil
        self.refreshToken = nil
        self.userId = nil

        guard let tokenToRevoke, let url = URL(string: "\(supabaseURL)/auth/v1/logout") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(tokenToRevoke)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    // MARK: - UUID Validation

    private static func isValidUUID(_ string: String) -> Bool {
        UUID(uuidString: string) != nil
    }

    private static func sanitizeParam(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private struct EmptyBody: Codable {}

    private struct RefreshTokenRequest: Encodable {
        let refresh_token: String
    }

    private struct AppleSignInRequest: Encodable {
        let provider: String
        let id_token: String
        let nonce: String?
        let name: String?
    }

    private struct SendOTPRequest: Encodable {
        let email: String
        let create_user: Bool
    }

    private struct VerifyOTPRequest: Encodable {
        let email: String
        let token: String
        let type: String
    }

    private struct PasswordSignInRequest: Encodable {
        let email: String
        let password: String
    }

    private struct PairingCodeRequest: Encodable {
        let code: String
        let user_id: String
        let created_at: String
        let expires_at: String
    }

    private struct AcknowledgeAlertRequest: Encodable {
        let acknowledged_at: String
        let is_read: Bool
    }

    private struct ResolveAlertRequest: Encodable {
        let is_resolved: Bool
    }

    private struct SnoozeAlertRequest: Encodable {
        let snoozed_until: String
    }

    private struct SupabaseUserMetadata: Decodable {
        let name: String?
    }

    private struct SupabaseUser: Decodable {
        let id: String
        let email: String?
        let user_metadata: SupabaseUserMetadata?
    }

    private struct SupabaseAuthResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let user: SupabaseUser?
    }

    private struct SupabaseProfileRecord: Decodable {
        let paired: Bool?
        let name: String?
        let email: String?
    }

    private struct DashboardSummaryPayload: Decodable {
        let today_usage: Int?
        let today_cost: Double?
        let active_sessions: Int?
        let online_devices: Int?
        let unresolved_alerts: Int?
        let today_sessions: Int?
    }

    private struct ProviderSummaryPayload: Decodable {
        let provider: String?
        let today_usage: Int?
        let total_usage: Int?
        let estimated_cost: Double?         // 7-day cost (historical name kept for backward compat)
        let estimated_cost_today: Double?   // v1.10.6+ today cost from daily_usage_metrics
        let estimated_cost_30_day: Double?  // v1.10.6+ 30-day cost from daily_usage_metrics
        let quota: Int?
        let remaining: Int?
        let plan_type: String?
        let reset_time: String?
        let tiers: [TierDTO]?
    }

    private struct SessionDevicePayload: Decodable {
        let name: String?
    }

    private struct SessionRecordPayload: Decodable {
        let id: String?
        let name: String?
        let provider: String?
        let project: String?
        let devices: SessionDevicePayload?
        let started_at: String?
        let last_active_at: String?
        let status: String?
        let total_usage: Int?
        let estimated_cost: Double?
        let requests: Int?
        let error_count: Int?
        let collection_confidence: String?
    }

    private struct DeviceRecordPayload: Decodable {
        let id: String?
        let name: String?
        let type: String?
        let system: String?
        let status: String?
        let last_seen_at: String?
        let helper_version: String?
        let cpu_usage: Int?
        let memory_usage: Int?
    }

    private struct AlertRecordPayload: Decodable {
        let id: String?
        let type: String?
        let severity: String?
        let title: String?
        let message: String?
        let created_at: String?
        let is_read: Bool?
        let is_resolved: Bool?
        let acknowledged_at: String?
        let snoozed_until: String?
        let related_project_id: String?
        let related_project_name: String?
        let related_session_id: String?
        let related_session_name: String?
        let related_provider: String?
        let related_device_name: String?
        let source_kind: String?
        let source_id: String?
        let grouping_key: String?
        let suppression_key: String?
    }

    private struct SettingsPayload: Decodable {
        let notifications_enabled: Bool?
        let push_policy: String?
        let digest_notifications_enabled: Bool?
        let digest_interval_minutes: Int?
        let usage_spike_threshold: Int?
        let project_budget_threshold_usd: Double?
        let session_too_long_threshold_minutes: Int?
        let offline_grace_period_minutes: Int?
        let repeated_failure_threshold: Int?
        let alert_cooldown_minutes: Int?
        let data_retention_days: Int?
        let track_git_activity: Bool?
        let remote_control_enabled: Bool?
    }

    private struct UserTierPayload: Decodable {
        let tier: String?
    }

    private struct ValidateReceiptRequest: Encodable {
        let transactionJWS: String
        let productId: String
    }

    private struct ValidateReceiptResponse: Decodable {
        let verified: Bool
        let tier: String?
        let error: String?
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private func fetchProfile(select: String) async throws -> SupabaseProfileRecord? {
        let safeUserId = Self.sanitizeParam(userId ?? "")
        let profiles: [SupabaseProfileRecord] = try await restGet(
            "/rest/v1/profiles?id=eq.\(safeUserId)&select=\(select)"
        )
        return profiles.first
    }

    // MARK: - Auth (Sign in with Apple via Supabase)

    public func signInWithApple(identityToken: String, nonce: String? = nil, fullName: String?, email: String?) async throws -> AuthResponse {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=id_token") else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        request.httpBody = try encoder.encode(
            AppleSignInRequest(
                provider: "apple",
                id_token: identityToken,
                nonce: nonce,
                name: fullName
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
        }

        let auth = try decode(SupabaseAuthResponse.self, from: data)
        let token = auth.access_token
        let refresh = auth.refresh_token
        let user = auth.user

        self.accessToken = token
        self.refreshToken = refresh
        self.userId = user?.id

        let profile = try await fetchProfile(select: "paired")
        let paired = profile?.paired ?? false

        let name = fullName ?? user?.user_metadata?.name ?? ""
        let userEmail = email ?? user?.email ?? ""

        return AuthResponse(
            access_token: token,
            refresh_token: refresh,
            user: UserDTO(id: user?.id ?? "", name: name, email: userEmail),
            paired: paired
        )
    }

    /// Send an OTP code to the user's email
    public func sendOTP(email: String) async throws {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/otp") else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        request.httpBody = try encoder.encode(SendOTPRequest(email: email, create_user: true))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
        }
    }

    /// Verify the OTP code and sign the user in
    public func verifyOTP(email: String, code: String) async throws -> AuthResponse {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/verify") else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        request.httpBody = try encoder.encode(VerifyOTPRequest(email: email, token: code, type: "email"))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: errorBody)
        }

        let auth = try decode(SupabaseAuthResponse.self, from: data)
        let token = auth.access_token
        let refresh = auth.refresh_token
        let user = auth.user

        self.accessToken = token
        self.refreshToken = refresh
        self.userId = user?.id

        let profile = try await fetchProfile(select: "paired,name,email")
        let paired = profile?.paired ?? false
        let profileName = profile?.name ?? ""
        let profileEmail = profile?.email ?? email

        return AuthResponse(
            access_token: token,
            refresh_token: refresh,
            user: UserDTO(id: user?.id ?? "", name: profileName, email: profileEmail),
            paired: paired
        )
    }

    /// Password-based sign in (for demo / review account)
    public func signInWithPassword(email: String, password: String) async throws -> AuthResponse {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=password") else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        request.httpBody = try encoder.encode(PasswordSignInRequest(email: email, password: password))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: errorBody)
        }

        let auth = try decode(SupabaseAuthResponse.self, from: data)
        let token = auth.access_token
        let refresh = auth.refresh_token
        let user = auth.user

        self.accessToken = token
        self.refreshToken = refresh
        self.userId = user?.id

        let profile = try await fetchProfile(select: "paired,name,email")
        let paired = profile?.paired ?? false
        let profileName = profile?.name ?? ""
        let profileEmail = profile?.email ?? email

        return AuthResponse(
            access_token: token,
            refresh_token: refresh,
            user: UserDTO(id: user?.id ?? "", name: profileName, email: profileEmail),
            paired: paired
        )
    }

    public func me(retried: Bool = false) async throws -> AuthResponse {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/user") else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        // Handle 401 by attempting token refresh (once only)
        if http?.statusCode == 401, !retried {
            let _ = try await refreshAccessToken()
            return try await me(retried: true)
        }
        guard let httpOK = http, (200...299).contains(httpOK.statusCode) else {
            throw APIError.httpError(status: http?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }

        let user = try decode(SupabaseUser.self, from: data)
        self.userId = user.id

        let profile = try await fetchProfile(select: "paired,name,email")
        let paired = profile?.paired ?? false
        let name = profile?.name ?? user.user_metadata?.name ?? ""
        let email = profile?.email ?? user.email ?? ""

        return AuthResponse(
            access_token: accessToken ?? "",
            refresh_token: refreshToken,
            user: UserDTO(id: user.id, name: name, email: email),
            paired: paired
        )
    }

    // MARK: - Dashboard

    public func dashboard() async throws -> DashboardSummary {
        let summary: DashboardSummaryPayload = try await rpc("dashboard_summary")

        let todayUsage = summary.today_usage ?? 0
        let todayCost = summary.today_cost ?? 0
        let activeSessions = summary.active_sessions ?? 0
        let onlineDevices = summary.online_devices ?? 0
        let unresolvedAlerts = summary.unresolved_alerts ?? 0

        // Codex review on PR #17 manual verify: the previous code
        // mapped `summary.today_sessions` (server-side count of
        // sessions started today) into `total_requests_today`,
        // which the Overview UI labels "Requests". With Jason's
        // 2 sessions today the card showed "Requests=2" — the
        // number was a session count masquerading as a request
        // count. Stop the misleading mapping: the local refresh
        // path computes request counts from session records
        // (`DataRefreshManager` line ~511, sums each session's
        // `requests` field) and is the authoritative source. When
        // the server-only path runs without local data, leave the
        // metric at 0 rather than misrepresenting sessions as
        // requests.
        let totalRequestsToday = 0

        return DashboardSummary(
            total_usage_today: todayUsage,
            total_estimated_cost_today: todayCost,
            cost_status: "Estimated",
            total_requests_today: totalRequestsToday,
            active_sessions: activeSessions,
            online_devices: onlineDevices,
            unresolved_alerts: unresolvedAlerts,
            provider_breakdown: [],
            top_projects: [],
            trend: [],
            recent_activity: [],
            risk_signals: [],
            alert_summary: AlertSummaryDTO(critical: 0, warning: 0, info: unresolvedAlerts)
        )
    }

    // MARK: - Providers

    public func providers() async throws -> [ProviderUsage] {
        let providers: [ProviderSummaryPayload] = try await rpc("provider_summary")
        return providers.map { provider in
            let name = provider.provider ?? ""
            // v1.9.4: attach a minimal metadata so cloud-only rows (provider
            // present on server but not locally collected) still render as
            // quota providers. Previously nil-metadata made `isQuotaProvider`
            // false in the UI, causing the card to fall back to raw
            // `today_usage` (which for quota providers is a utilization %).
            // `supports_quota: true` is a safe default because the server's
            // `provider_summary` RPC only emits providers that have a quota
            // or credit model.
            let meta = ProviderMetadata(
                display_name: name,
                category: "cloud",
                supports_exact_cost: false,
                supports_quota: true
            )
            return ProviderUsage(
                provider: name,
                today_usage: provider.today_usage ?? 0,
                week_usage: provider.total_usage ?? 0,
                estimated_cost_today: provider.estimated_cost_today ?? 0,
                estimated_cost_week: provider.estimated_cost ?? 0,
                estimated_cost_30_day: provider.estimated_cost_30_day ?? 0,
                cost_status_today: "Estimated",
                cost_status_week: "Estimated",
                quota: provider.quota,
                remaining: provider.remaining,
                plan_type: provider.plan_type,
                reset_time: provider.reset_time,
                tiers: provider.tiers ?? [],
                status_text: "Operational",
                trend: [],
                recent_sessions: [],
                recent_errors: [],
                metadata: meta
            )
        }
    }

    // MARK: - Sessions

    public func sessions() async throws -> [SessionRecord] {
        let safeUserId = Self.sanitizeParam(userId ?? "")
        let rows: [SessionRecordPayload] = try await restGet(
            "/rest/v1/sessions?user_id=eq.\(safeUserId)&select=*,devices(name)&order=last_active_at.desc&limit=50"
        )
        return rows.map { row in
            return SessionRecord(
                id: row.id ?? "",
                name: row.name ?? "",
                provider: row.provider ?? "",
                project: row.project ?? "",
                device_name: row.devices?.name ?? "",
                started_at: row.started_at ?? "",
                last_active_at: row.last_active_at ?? "",
                status: row.status ?? "Running",
                total_usage: row.total_usage ?? 0,
                estimated_cost: row.estimated_cost ?? 0,
                cost_status: "Estimated",
                requests: row.requests ?? 0,
                error_count: row.error_count ?? 0,
                collection_confidence: row.collection_confidence
            )
        }
    }

    // MARK: - Devices

    public func devices() async throws -> [DeviceRecord] {
        let safeUserId = Self.sanitizeParam(userId ?? "")
        let rows: [DeviceRecordPayload] = try await restGet(
            "/rest/v1/devices?user_id=eq.\(safeUserId)&select=*&order=last_seen_at.desc"
        )
        return rows.map { row in
            DeviceRecord(
                id: row.id ?? "",
                name: row.name ?? "",
                type: row.type ?? "macOS",
                system: row.system ?? "",
                status: row.status ?? "Offline",
                last_sync_at: row.last_seen_at,
                helper_version: row.helper_version ?? "",
                current_session_count: 0,
                cpu_usage: row.cpu_usage,
                memory_usage: row.memory_usage
            )
        }
    }

    // MARK: - Alerts

    public func alerts() async throws -> [AlertRecord] {
        let safeUserId = Self.sanitizeParam(userId ?? "")
        let rows: [AlertRecordPayload] = try await restGet(
            "/rest/v1/alerts?user_id=eq.\(safeUserId)&select=*&order=created_at.desc&limit=50"
        )
        return rows.map { row in
            AlertRecord(
                id: row.id ?? "",
                type: row.type ?? "",
                severity: row.severity ?? "Info",
                title: row.title ?? "",
                message: row.message ?? "",
                created_at: row.created_at ?? "",
                is_read: row.is_read ?? false,
                is_resolved: row.is_resolved ?? false,
                acknowledged_at: row.acknowledged_at,
                snoozed_until: row.snoozed_until,
                related_project_id: row.related_project_id,
                related_project_name: row.related_project_name,
                related_session_id: row.related_session_id,
                related_session_name: row.related_session_name,
                related_provider: row.related_provider,
                related_device_name: row.related_device_name,
                source_kind: row.source_kind,
                source_id: row.source_id,
                grouping_key: row.grouping_key,
                suppression_key: row.suppression_key
            )
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public func acknowledgeAlert(id: String) async throws -> SuccessResponse {
        let safeId = Self.sanitizeParam(id)
        let safeUserId = Self.sanitizeParam(userId ?? "")
        try await restPatch(
            "/rest/v1/alerts?id=eq.\(safeId)&user_id=eq.\(safeUserId)",
            body: AcknowledgeAlertRequest(
                acknowledged_at: Self.isoFormatter.string(from: Date()),
                is_read: true
            )
        )
        return SuccessResponse(ok: true)
    }

    public func resolveAlert(id: String) async throws -> SuccessResponse {
        let safeId = Self.sanitizeParam(id)
        let safeUserId = Self.sanitizeParam(userId ?? "")
        try await restPatch(
            "/rest/v1/alerts?id=eq.\(safeId)&user_id=eq.\(safeUserId)",
            body: ResolveAlertRequest(is_resolved: true)
        )
        return SuccessResponse(ok: true)
    }

    public func snoozeAlert(id: String, minutes: Int) async throws -> SuccessResponse {
        let safeId = Self.sanitizeParam(id)
        let safeUserId = Self.sanitizeParam(userId ?? "")
        let snoozeUntil = Self.isoFormatter.string(from: Date().addingTimeInterval(Double(minutes) * 60))
        try await restPatch(
            "/rest/v1/alerts?id=eq.\(safeId)&user_id=eq.\(safeUserId)",
            body: SnoozeAlertRequest(snoozed_until: snoozeUntil)
        )
        return SuccessResponse(ok: true)
    }

    // MARK: - Settings

    public func settings() async throws -> SettingsSnapshot {
        let safeUserId = Self.sanitizeParam(userId ?? "")
        let rows: [SettingsPayload] = try await restGet("/rest/v1/user_settings?user_id=eq.\(safeUserId)&select=*")
        let settings = rows.first
        return SettingsSnapshot(
            notifications_enabled: settings?.notifications_enabled ?? true,
            push_policy: settings?.push_policy ?? "Warnings + Critical",
            digest_enabled: settings?.digest_notifications_enabled ?? true,
            digest_interval_hours: max(1, (settings?.digest_interval_minutes ?? 60) / 60),
            usage_spike_threshold: settings?.usage_spike_threshold ?? 500,
            project_budget_threshold_usd: settings?.project_budget_threshold_usd ?? 0.25,
            session_too_long_threshold_minutes: settings?.session_too_long_threshold_minutes ?? 180,
            offline_grace_period_minutes: settings?.offline_grace_period_minutes ?? 5,
            repeated_failure_threshold: settings?.repeated_failure_threshold ?? 3,
            alert_cooldown_minutes: settings?.alert_cooldown_minutes ?? 30,
            data_retention_days: settings?.data_retention_days ?? 7,
            track_git_activity: settings?.track_git_activity ?? false,
            remote_control_enabled: settings?.remote_control_enabled ?? false
        )
    }

    /// Update user settings on the server.
    public func updateSettings(_ patch: SettingsPatch) async throws {
        guard let uid = userId, Self.isValidUUID(uid) else { throw APIError.invalidResponse }
        let safeUid = Self.sanitizeParam(uid)
        _ = try await restPatch("/rest/v1/user_settings?user_id=eq.\(safeUid)", body: patch)
    }

    /// Encodable patch for user settings — only include fields you want to change.
    public struct SettingsPatch: Encodable {
        public var notifications_enabled: Bool?
        public var push_policy: String?
        public var usage_spike_threshold: Int?
        public var project_budget_threshold_usd: Double?
        public var session_too_long_threshold_minutes: Int?
        public var offline_grace_period_minutes: Int?
        public var data_retention_days: Int?
        public var webhook_url: String?
        public var webhook_enabled: Bool?
        public var webhook_event_filter: WebhookEventFilter?
        public var track_git_activity: Bool?
        public var remote_control_enabled: Bool?

        public init(
            notifications_enabled: Bool? = nil,
            push_policy: String? = nil,
            usage_spike_threshold: Int? = nil,
            project_budget_threshold_usd: Double? = nil,
            session_too_long_threshold_minutes: Int? = nil,
            offline_grace_period_minutes: Int? = nil,
            data_retention_days: Int? = nil,
            webhook_url: String? = nil,
            webhook_enabled: Bool? = nil,
            webhook_event_filter: WebhookEventFilter? = nil,
            track_git_activity: Bool? = nil,
            remote_control_enabled: Bool? = nil
        ) {
            self.notifications_enabled = notifications_enabled
            self.push_policy = push_policy
            self.usage_spike_threshold = usage_spike_threshold
            self.project_budget_threshold_usd = project_budget_threshold_usd
            self.session_too_long_threshold_minutes = session_too_long_threshold_minutes
            self.offline_grace_period_minutes = offline_grace_period_minutes
            self.data_retention_days = data_retention_days
            self.webhook_url = webhook_url
            self.webhook_enabled = webhook_enabled
            self.webhook_event_filter = webhook_event_filter
            self.track_git_activity = track_git_activity
            self.remote_control_enabled = remote_control_enabled
        }
    }

    // MARK: - Webhook

    /// Invoke the send-webhook Edge Function for a given alert.
    public func sendWebhook(alert: AlertRecord) async throws {
        guard let uid = userId else { return }
        guard let url = URL(string: "\(supabaseURL)/functions/v1/send-webhook") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(&request)
        let body: [String: Any] = [
            "user_id": uid,
            "alert": [
                "type": alert.type,
                "severity": alert.severity,
                "title": alert.title,
                "message": alert.message,
                "related_provider": alert.related_provider ?? "",
                "grouping_key": alert.grouping_key ?? "",
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await dataWithRetry(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
    }

    // MARK: - Pairing

    public func pairingCode() async throws -> PairingInfo {
        let code = "PULSE-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).uppercased())"
        let now = Self.isoFormatter.string(from: Date())
        let expires = Self.isoFormatter.string(from: Date().addingTimeInterval(600))

        guard let uid = userId, Self.isValidUUID(uid) else { throw APIError.invalidResponse }
        guard let url = URL(string: "\(supabaseURL)/rest/v1/pairing_codes") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(&request)
        request.httpBody = try encoder.encode(
            PairingCodeRequest(
                code: code,
                user_id: uid,
                created_at: now,
                expires_at: expires
            )
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        // The native Swift Login Item (CLIPulseHelper) is the primary helper.
        // Provide the pairing code for the app to pass to the embedded helper.
        // Legacy Python install command kept as fallback for non-App-Store builds.
        #if os(macOS)
        return PairingInfo(
            code: code,
            install_command: "open -a 'CLI Pulse Bar' --args --pair \(code)"
        )
        #else
        return PairingInfo(
            code: code,
            install_command: code
        )
        #endif
    }

    // MARK: - Account Deletion

    /// Delete the authenticated user's account.
    ///
    /// Calls the `delete_user_account` RPC (SECURITY DEFINER, owner postgres,
    /// authenticated via `auth.uid()`), which deletes the row from
    /// `public.profiles` (cascading to ~20 child tables: alerts, sessions,
    /// devices, app_push_tokens, subscriptions, remote_sessions, …) and then
    /// from `auth.users`. Both rows are gone after a successful call.
    ///
    /// iter10 hotfix (2026-04-29): the previous version of this method
    /// uncritically sent whatever access token happened to be in
    /// `self.accessToken`. On real device, if the user had been idle long
    /// enough for the JWT to expire (Supabase default: 1 hour), `auth.uid()`
    /// inside the RPC returned NULL → "Not authenticated" exception → HTTP
    /// 4xx → client throw → AppState.deleteAccount swallowed the error
    /// without surfacing it (iOSSettingsTab didn't bind to lastError) → the
    /// user thought delete worked but the account still existed server-side.
    /// The eager refresh below rules out the stale-JWT failure mode; the
    /// AppState/UI layer adds the missing error surfacing.
    ///
    /// iter11 hotfix (2026-04-29): the iter10 version of the eager refresh
    /// used `try?`, swallowing tokenExpired failures. `refreshAccessToken`
    /// nils both `accessToken` and `refreshToken` on failure (intentional —
    /// session is dead), so swallowing meant the RPC then ran without
    /// Authorization, the server returned 4xx, AppState reported failure
    /// and "preserved the session" — but the in-memory tokens were already
    /// nil. The user ended up with a UI that looked signed in while the
    /// API client had no auth: every subsequent call would fail.
    /// The fix: on refresh failure, propagate `tokenExpired`. AppState's
    /// catch arm signs the user out cleanly (via `signOut()`) and stashes
    /// a "Session expired" message into `lastError` after `signOut`, so
    /// the login screen explains what happened.
    public func deleteAccount() async throws {
        // Eagerly refresh the access token if we have a refresh token. The
        // happy path replaces the access token with a fresh one before the
        // delete RPC runs, ruling out the stale-JWT silent-failure mode.
        if refreshToken != nil {
            do {
                _ = try await refreshAccessToken()
            } catch {
                // Refresh failed → session is dead and `refreshAccessToken`
                // has already nil'd `accessToken` / `refreshToken`. Don't
                // try to push the RPC through with no auth header — bail
                // out with the tokenExpired marker so the caller can put
                // the UI back into a coherent signed-out state.
                throw APIError.tokenExpired
            }
        }

        guard let url = URL(string: "\(supabaseURL)/rest/v1/rpc/delete_user_account") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(&request)
        request.httpBody = try encoder.encode(EmptyBody())
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        // Revoke server-side token after account deletion
        await signOutServer()
    }

    // MARK: - Server Tier

    public func serverTier() async -> String {
        do {
            let response: UserTierPayload = try await rpc("get_user_tier")
            return response.tier ?? "free"
        } catch {
            return "free"
        }
    }

    /// Evaluate budget alerts server-side. Returns number of new alerts created.
    public func evaluateBudgetAlerts() async throws -> Int {
        struct BudgetResult: Decodable { let alerts_created: Int? }
        let result: BudgetResult = try await rpc("evaluate_budget_alerts")
        return result.alerts_created ?? 0
    }

    // MARK: - Teams

    public func createTeam(name: String) async throws -> TeamDTO {
        struct Params: Encodable { let p_name: String }
        struct Result: Decodable { let team_id: String; let name: String }
        let result: Result = try await rpc("create_team", params: Params(p_name: name))
        return TeamDTO(id: result.team_id, name: result.name, owner_id: userId ?? "", created_at: sharedISO8601Formatter.string(from: Date()), member_count: 1, role: "owner")
    }

    public func teamDetails(teamId: String) async throws -> TeamDetailDTO {
        struct Params: Encodable { let p_team_id: String }
        return try await rpc("team_details", params: Params(p_team_id: teamId))
    }

    public func myTeams() async throws -> [TeamDTO] {
        let data: Data = try await rpcRaw("my_teams")
        return try JSONDecoder().decode([TeamDTO].self, from: data)
    }

    public func inviteMember(teamId: String, email: String) async throws {
        struct Params: Encodable { let p_team_id: String; let p_email: String; let p_role: String }
        let _: [String: String] = try await rpc("invite_member", params: Params(p_team_id: teamId, p_email: email, p_role: "member"))
    }

    public func acceptInvite(inviteId: String) async throws {
        struct Params: Encodable { let p_invite_id: String }
        let _: [String: String] = try await rpc("accept_invite", params: Params(p_invite_id: inviteId))
    }

    public func removeMember(teamId: String, userId: String) async throws {
        struct Params: Encodable { let p_team_id: String; let p_user_id: String }
        let _: [String: String] = try await rpc("remove_member", params: Params(p_team_id: teamId, p_user_id: userId))
    }

    public func updateMemberRole(teamId: String, userId: String, role: String) async throws {
        struct Params: Encodable { let p_team_id: String; let p_user_id: String; let p_role: String }
        let _: [String: String] = try await rpc("update_member_role", params: Params(p_team_id: teamId, p_user_id: userId, p_role: role))
    }

    public func teamUsageSummary(teamId: String) async throws -> TeamUsageSummaryDTO {
        struct Params: Encodable { let p_team_id: String }
        return try await rpc("team_usage_summary", params: Params(p_team_id: teamId))
    }

    // MARK: - Remote Agent Sessions / Approvals (v0.26)

    /// Fetch every still-pending remote permission request across the user's devices.
    /// Returns an empty array when none are pending.
    public func remoteListPendingApprovals() async throws -> [RemotePermissionRequest] {
        let result: [RemotePermissionRequest] = try await rpc("remote_app_list_pending_approvals")
        return result
    }

    /// Approve or deny a remote permission request. `scope` is silently
    /// downgraded to `.once` server-side for Codex (Phase 1 limitation).
    public func remoteDecidePermission(
        requestId: String,
        decision: RemotePermissionDecisionAction,
        scope: RemotePermissionScope = .once,
        decidedByDeviceId: String? = nil
    ) async throws {
        struct Params: Encodable {
            let p_request_id: String
            let p_decision: String
            let p_scope: String
            let p_decided_by_device_id: String?
        }
        let _: [String: String] = try await rpc(
            "remote_app_decide_permission",
            params: Params(
                p_request_id: requestId,
                p_decision: decision.rawValue,
                p_scope: scope.rawValue,
                p_decided_by_device_id: decidedByDeviceId
            )
        )
    }

    /// Register or transfer-ownership of an APNs push token to the
    /// authenticated user. Idempotent: same user re-registering the same
    /// token just refreshes `last_seen_at`. Different user registering
    /// the same token (e.g. user B logs into the same iPhone after user A
    /// logged out) atomically transfers the row to user B — by design,
    /// this stops user A's pending approvals from pushing to that device.
    /// See `app_push_tokens` schema (v0.32) for the unique(token) invariant.
    public func registerAppPushToken(
        token: String,
        platform: String,
        bundleId: String
    ) async throws {
        struct Params: Encodable {
            let p_platform: String
            let p_bundle_id: String
            let p_token: String
        }
        let _: [String: String] = try await rpc(
            "register_app_push_token",
            params: Params(p_platform: platform, p_bundle_id: bundleId, p_token: token)
        )
    }

    /// Delete an APNs push token. Server-side enforces "only the calling
    /// user can delete their own row". Called by the app on logout.
    public func unregisterAppPushToken(token: String) async throws {
        struct Params: Encodable { let p_token: String }
        let _: [String: String] = try await rpc(
            "unregister_app_push_token",
            params: Params(p_token: token)
        )
    }

    /// Send a control command (prompt / stop / interrupt) to a managed session.
    /// Returns the new command id.
    ///
    /// Does NOT accept `.start` — that lifecycle command goes through
    /// `remoteRequestSessionStart(...)` so it can atomically create the
    /// `remote_sessions` row alongside the queued command. The server
    /// `remote_app_send_command` RPC enforces this restriction too.
    public func remoteSendCommand(
        sessionId: String,
        kind: RemoteCommandKind,
        payload: String = ""
    ) async throws -> String {
        struct Params: Encodable {
            let p_session_id: String
            let p_kind: String
            let p_payload: String
        }
        struct Result: Decodable { let command_id: String }
        let result: Result = try await rpc(
            "remote_app_send_command",
            params: Params(p_session_id: sessionId, p_kind: kind.rawValue, p_payload: payload)
        )
        return result.command_id
    }

    /// List the caller's active remote sessions (pending or running),
    /// joined with `devices.name` so the UI can label which Mac each
    /// session belongs to. Returns `[]` when Remote Control is disabled
    /// or when the user has no managed sessions.
    public func remoteListSessions() async throws -> [RemoteSession] {
        let result: [RemoteSession] = try await rpc("remote_app_list_sessions")
        return result
    }

    /// List the event tail (`stdout` / `stderr` / `status` / `info`) for
    /// a managed session. Pagination is by the bigserial `id` column
    /// (server-authoritative monotonic insert order) — pass the largest
    /// id you've seen as `afterId` to fetch only newer rows. Returns
    /// `[]` when Remote Control is disabled, when the session doesn't
    /// belong to the caller, or when there are no rows past `afterId`.
    /// `limit` is clamped server-side to `[1, 500]`.
    public func remoteListSessionEvents(
        sessionId: String,
        afterId: Int = 0,
        limit: Int = 200
    ) async throws -> [RemoteSessionEvent] {
        struct Params: Encodable {
            let p_session_id: String
            let p_after_id: Int
            let p_limit: Int
        }
        let result: [RemoteSessionEvent] = try await rpc(
            "remote_app_list_session_events",
            params: Params(
                p_session_id: sessionId,
                p_after_id: afterId,
                p_limit: limit
            )
        )
        return result
    }

    /// Request that the helper paired with `deviceId` spawn a new managed
    /// Claude session. Atomically creates the `remote_sessions` row and
    /// enqueues the `start` command for the helper poll loop.
    /// Returns the new session id (so the caller can immediately select
    /// the row in the UI before the next list refresh).
    ///
    /// `cwdBasename` / `cwdHmac` are advisory metadata only — the helper
    /// does NOT try to resolve a basename to a full filesystem path
    /// (Phase 1 privacy posture: no full paths leave the device).
    /// iter 1 only accepts provider == 'claude'.
    public func remoteRequestSessionStart(
        deviceId: String,
        cwdBasename: String = "",
        cwdHmac: String? = nil,
        clientLabel: String? = nil
    ) async throws -> (sessionId: String, commandId: String) {
        struct Params: Encodable {
            let p_device_id: String
            let p_provider: String
            let p_cwd_basename: String
            let p_cwd_hmac: String?
            let p_client_label: String?
        }
        struct Result: Decodable {
            let session_id: String
            let command_id: String
        }
        let result: Result = try await rpc(
            "remote_app_request_session_start",
            params: Params(
                p_device_id: deviceId,
                p_provider: "claude",
                p_cwd_basename: cwdBasename,
                p_cwd_hmac: cwdHmac,
                p_client_label: clientLabel
            )
        )
        return (result.session_id, result.command_id)
    }

    // MARK: - OAuth (Google / GitHub via Supabase)

    /// Build the Supabase OAuth authorization URL for a given provider with PKCE.
    /// Returns (authorizationURL, codeVerifier).
    ///
    /// iter8 hotfix (2026-04-29): we deliberately do NOT pass a client-generated
    /// `state` query parameter. Supabase GoTrue's PKCE flow manages OAuth state
    /// internally — it stores a server-generated `flow_state.auth_code` token
    /// and uses *that* as the OAuth state with the upstream provider (Google /
    /// GitHub). Passing our own `state=...` collides with that internal state
    /// management and causes Supabase to bounce the callback back with
    /// `error_description=OAuth state parameter is invalid` (the user observed
    /// this on real device). PKCE's `code_verifier` already provides full CSRF
    /// protection: the verifier is generated and stored only on the originating
    /// device, so even if an attacker intercepts the auth code, they cannot
    /// complete the token exchange. supabase-js / supabase-swift behave the same
    /// way — neither adds a custom state parameter to the authorize URL.
    public func oauthAuthorizeURL(provider: String, redirectTo: String) -> (URL, String)? {
        // Generate PKCE code verifier + challenge
        guard let verifier = generateCodeVerifier(),
              let challenge = sha256Base64URL(verifier) else { return nil }

        var components = URLComponents(string: "\(supabaseURL)/auth/v1/authorize")
        components?.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_to", value: redirectTo),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components?.url else { return nil }
        return (url, verifier)
    }

    /// Exchange an OAuth authorization code for a Supabase session (PKCE flow).
    public func exchangeOAuthCode(code: String, codeVerifier: String) async throws -> AuthResponse {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=pkce") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        struct PKCEExchange: Encodable {
            let auth_code: String
            let code_verifier: String
        }
        request.httpBody = try encoder.encode(PKCEExchange(auth_code: code, code_verifier: codeVerifier))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
        }

        let auth = try decode(SupabaseAuthResponse.self, from: data)
        let token = auth.access_token
        let refresh = auth.refresh_token
        let user = auth.user

        self.accessToken = token
        self.refreshToken = refresh
        self.userId = user?.id

        let profile = try await fetchProfile(select: "paired,name,email")
        let paired = profile?.paired ?? false
        let name = profile?.name ?? user?.user_metadata?.name ?? ""
        let userEmail = profile?.email ?? user?.email ?? ""

        return AuthResponse(
            access_token: token,
            refresh_token: refresh,
            user: UserDTO(id: user?.id ?? "", name: name, email: userEmail),
            paired: paired
        )
    }

    /// Exchange a Google ID token for a Supabase session (same as Apple flow).
    public func signInWithGoogle(idToken: String, nonce: String? = nil, name: String?, email: String?) async throws -> AuthResponse {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=id_token") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        struct GoogleSignInRequest: Encodable {
            let provider: String
            let id_token: String
            let nonce: String?
            let name: String?
        }
        request.httpBody = try encoder.encode(GoogleSignInRequest(provider: "google", id_token: idToken, nonce: nonce, name: name))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
        }

        let auth = try decode(SupabaseAuthResponse.self, from: data)
        let token = auth.access_token
        let refresh = auth.refresh_token
        let user = auth.user

        self.accessToken = token
        self.refreshToken = refresh
        self.userId = user?.id

        let profile = try await fetchProfile(select: "paired,name,email")
        let paired = profile?.paired ?? false
        let userName = name ?? profile?.name ?? user?.user_metadata?.name ?? ""
        let userEmail = email ?? profile?.email ?? user?.email ?? ""

        return AuthResponse(
            access_token: token,
            refresh_token: refresh,
            user: UserDTO(id: user?.id ?? "", name: userName, email: userEmail),
            paired: paired
        )
    }

    // MARK: - Identity Linking

    private struct SupabaseIdentityRecord: Decodable {
        let identity_id: String?
        let id: String?
        let provider: String
        let email: String?
        let created_at: String?
        let identity_data: SupabaseIdentityData?
    }

    private struct SupabaseIdentityData: Decodable {
        let email: String?
    }

    private struct SupabaseUserWithIdentities: Decodable {
        let identities: [SupabaseIdentityRecord]?
    }

    /// Fetch the current user's linked identities (provider, email, identity_id).
    public func userIdentities() async throws -> [UserIdentity] {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/user") else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        guard let token = accessToken else { throw APIError.tokenExpired }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        let user = try decode(SupabaseUserWithIdentities.self, from: data)
        return (user.identities ?? []).compactMap { raw in
            let identityID = raw.identity_id ?? raw.id
            guard let identityID else { return nil }
            return UserIdentity(
                id: identityID,
                provider: raw.provider,
                email: raw.identity_data?.email ?? raw.email,
                createdAt: raw.created_at
            )
        }
    }

    /// Build a Supabase link-identity authorization URL for an OAuth provider (Google, GitHub).
    /// Requires a valid current session. Returns (authorizationURL, codeVerifier).
    ///
    /// iter8 hotfix (2026-04-29): mirroring `oauthAuthorizeURL`, we no longer
    /// pass a client-generated `state` query parameter. Supabase manages PKCE
    /// state server-side via the `flow_state` table; PKCE's `code_verifier`
    /// already provides CSRF protection. See `oauthAuthorizeURL` for details.
    public func linkIdentityAuthorizeURL(provider: String, redirectTo: String) async throws -> (URL, String) {
        guard let verifier = generateCodeVerifier(),
              let challenge = sha256Base64URL(verifier) else {
            throw APIError.invalidResponse
        }
        var components = URLComponents(string: "\(supabaseURL)/auth/v1/user/identities/authorize")
        components?.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_to", value: redirectTo),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "skip_http_redirect", value: "true"),
        ]
        guard let url = components?.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        guard let token = accessToken else { throw APIError.tokenExpired }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        struct AuthorizeResponse: Decodable { let url: String }
        let payload = try decode(AuthorizeResponse.self, from: data)
        guard let authURL = URL(string: payload.url) else { throw APIError.invalidResponse }
        return (authURL, verifier)
    }

    /// Exchange a link-identity PKCE code. Updates the session to reflect the newly linked identity.
    /// Unlike exchangeOAuthCode, this does not fetch the profile or return an AuthResponse —
    /// identity linking preserves the current user, so the caller just needs updated tokens.
    public func exchangeOAuthCodeForLink(code: String, codeVerifier: String) async throws {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=pkce") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        struct PKCEExchange: Encodable { let auth_code: String; let code_verifier: String }
        request.httpBody = try encoder.encode(PKCEExchange(auth_code: code, code_verifier: codeVerifier))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        let auth = try decode(SupabaseAuthResponse.self, from: data)
        self.accessToken = auth.access_token
        if let refresh = auth.refresh_token {
            self.refreshToken = refresh
        }
        onTokenRefreshed?(auth.access_token, auth.refresh_token ?? refreshToken ?? "")
    }

    /// Link an Apple identity to the current user using an Apple identity token.
    /// Requires a valid current session.
    public func linkAppleIdentity(identityToken: String, nonce: String?) async throws {
        guard let token = accessToken else { throw APIError.tokenExpired }
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=id_token") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        struct LinkAppleRequest: Encodable {
            let provider: String
            let id_token: String
            let nonce: String?
            let link_identity: Bool
        }
        request.httpBody = try encoder.encode(LinkAppleRequest(
            provider: "apple",
            id_token: identityToken,
            nonce: nonce,
            link_identity: true
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        if let auth = try? decode(SupabaseAuthResponse.self, from: data) {
            self.accessToken = auth.access_token
            if let refresh = auth.refresh_token {
                self.refreshToken = refresh
            }
            onTokenRefreshed?(auth.access_token, auth.refresh_token ?? refreshToken ?? "")
        }
    }

    /// Unlink a given identity from the current user.
    public func unlinkIdentity(identityId: String) async throws {
        guard let token = accessToken else { throw APIError.tokenExpired }
        let encodedID = Self.sanitizeParam(identityId)
        guard let url = URL(string: "\(supabaseURL)/auth/v1/user/identities/\(encodedID)") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    // PKCE helpers
    /// Returns nil if `SecRandomCopyBytes` fails — callers must treat that as a
    /// hard failure rather than fall back to the all-zero buffer, which would
    /// produce a deterministic, attacker-known verifier/state.
    private func generateCodeVerifier() -> String? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        guard status == errSecSuccess else { return nil }
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func sha256Base64URL(_ input: String) -> String? {
        guard let data = input.data(using: .utf8) else { return nil }
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Receipt Validation

    /// Validate a StoreKit 2 JWS signed transaction server-side.
    /// Returns the verified tier from the server, or nil on failure.
    public func validateReceipt(transactionJWS: String, productId: String) async -> (verified: Bool, tier: String) {
        do {
            guard let url = URL(string: "\(supabaseURL)/functions/v1/validate-receipt") else {
                return (false, "free")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            applyHeaders(&request)
            request.httpBody = try encoder.encode(
                ValidateReceiptRequest(transactionJWS: transactionJWS, productId: productId)
            )
            let (data, response) = try await dataWithRetry(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return (false, "free")
            }
            let result = try decode(ValidateReceiptResponse.self, from: data)
            return (result.verified, result.tier ?? "free")
        } catch {
            return (false, "free")
        }
    }

    // MARK: - Provider Quota Sync

    #if os(macOS)
    /// Push locally collected provider quotas to Supabase (upsert into provider_quotas table).
    /// Non-throwing — sync failures are logged but not propagated.
    public func syncProviderQuotas(_ results: [CollectorResult]) async {
        guard let userId else { return }
        let rawQuotaResults = results.filter { $0.dataKind == .quota || $0.dataKind == .credits }
        guard !rawQuotaResults.isEmpty else { return }

        // v1.9.4: de-duplicate by `provider` key. The upstream scan path
        // sometimes returns the same provider twice (e.g. main-app Claude
        // result + helper-bridged Claude result land in the merged list).
        // Postgres' `ON CONFLICT DO UPDATE` errors out (SQLSTATE 21000 —
        // "cannot affect row a second time") if a single bulk upsert contains
        // two rows with the same conflict target. Keep the last occurrence
        // for each provider since it's typically the freshest merged result.
        var seen: Set<String> = []
        var quotaResults: [CollectorResult] = []
        for r in rawQuotaResults.reversed() {
            if seen.insert(r.usage.provider).inserted {
                quotaResults.append(r)
            }
        }
        quotaResults.reverse()

        guard let url = URL(string: "\(supabaseURL)/rest/v1/provider_quotas") else { return }

        var rows: [[String: Any]] = []
        for r in quotaResults {
            let u = r.usage
            var row: [String: Any] = [
                "user_id": userId,
                "provider": u.provider,
                "remaining": u.remaining ?? 0,
                "updated_at": sharedISO8601Formatter.string(from: Date()),
            ]
            if let q = u.quota { row["quota"] = q }
            if let pt = u.plan_type { row["plan_type"] = pt }
            if let rt = u.reset_time { row["reset_time"] = rt }

            let tiersArr: [[String: Any]] = u.tiers.map { t in
                var d: [String: Any] = ["name": t.name, "quota": t.quota, "remaining": t.remaining]
                if let rt = t.reset_time { d["reset_time"] = rt }
                return d
            }
            row["tiers"] = tiersArr
            rows.append(row)
        }

        guard let body = try? JSONSerialization.data(withJSONObject: rows) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200...299).contains(status) {
                // v1.9.4: log response body (truncated) + provider list so
                // transient 500s don't leave us guessing. Body typically
                // carries a Postgres error message from PostgREST.
                let bodyStr = String(data: data.prefix(512), encoding: .utf8) ?? "<non-utf8>"
                let providers = quotaResults.map { $0.usage.provider }.joined(separator: ",")
                apiLogger.warning("[syncProviderQuotas] failed: HTTP \(status), providers=[\(providers)], body=\(bodyStr, privacy: .public)")
            }
        } catch {
            apiLogger.warning("[syncProviderQuotas] error: \(error.localizedDescription)")
        }
    }

    // MARK: - Daily Usage Sync

    /// Push precise daily usage data from CostUsageScanner to Supabase.
    ///
    /// v1.10.5: previously excluded today's date to avoid "incomplete" data,
    /// but after the Mac App Store sandbox broke `LocalScanner` process
    /// enumeration, `sessions` became empty — and the iPhone/Watch/Android
    /// dashboards were sourcing "Usage Today" from sessions. Including today
    /// in the upsert (keyed on user_id + metric_date + provider + model) lets
    /// the server-side dashboard_summary read today's real cost from this
    /// table instead. Every refresh overwrites the row with the latest scan,
    /// so partial-day values auto-correct as the day progresses.
    public func syncDailyUsage(_ scanResult: CostUsageScanResult) async {
        guard let userId else { return }
        guard !scanResult.entries.isEmpty else { return }

        // Skip the synthetic `__claude_msg__` model bucket — it carries raw
        // message-event counts, not real model usage, and would pollute the
        // server-side per-model analytics with a fake model row.
        let completedEntries = scanResult.entries.filter { $0.model != "__claude_msg__" }
        guard !completedEntries.isEmpty else { return }

        let metrics: [[String: Any]] = completedEntries.map { entry in
            [
                "metric_date": entry.date,
                "provider": entry.provider,
                "model": entry.model,
                "input_tokens": entry.inputTokens,
                "cached_tokens": entry.cachedTokens,
                "output_tokens": entry.outputTokens,
                "cost": entry.costUSD ?? 0.0,
            ]
        }

        guard let url = URL(string: "\(supabaseURL)/rest/v1/rpc/upsert_daily_usage") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // v0.3.1: send our paired device_id so the row lands under
        // (user_id, device_id, ...) and doesn't race-clobber rows from
        // a Win/Linux Tauri client running on the same account.
        // HelperConfig.deviceId is populated whenever the user has gone
        // through register_helper. If somehow nil (rare — pre-pair
        // transient), omit the param and the server falls back to the
        // sentinel UUID, which keeps legacy single-device users
        // working as before.
        var body: [String: Any] = ["metrics": metrics]
        if let deviceId = HelperConfig.load()?.deviceId, !deviceId.isEmpty {
            body["p_device_id"] = deviceId
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200...299).contains(status) {
                apiLogger.warning("[syncDailyUsage] failed: HTTP \(status)")
            }
        } catch {
            apiLogger.warning("[syncDailyUsage] error: \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: - Daily Usage Fetch (cross-platform — iOS/Android pull history from Supabase)

    /// Fetch daily usage data from Supabase (for iOS/Android display).
    public func fetchDailyUsage(days: Int = 30) async -> [DailyUsage] {
        guard userId != nil else { return [] }
        guard let url = URL(string: "\(supabaseURL)/rest/v1/rpc/get_daily_usage") else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["days": days])

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else { return [] }

            guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return items.compactMap { item -> DailyUsage? in
                guard let date = item["metric_date"] as? String,
                      let provider = item["provider"] as? String,
                      let model = item["model"] as? String else { return nil }
                return DailyUsage(
                    date: date,
                    provider: provider,
                    model: model,
                    inputTokens: (item["input_tokens"] as? Int) ?? 0,
                    cachedTokens: (item["cached_tokens"] as? Int) ?? 0,
                    outputTokens: (item["output_tokens"] as? Int) ?? 0,
                    cost: (item["cost"] as? Double) ?? 0
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - Yield Score

    /// Fetch raw daily yield rows from Supabase (rollup table `yield_score_daily`).
    /// Caller aggregates with `YieldScoreAggregator.summarize` over the desired range.
    /// Returns an empty array on failure (network, auth, parse) — yield is non-essential.
    public func fetchYieldScoreDaily(days: Int = 90) async -> [YieldScoreRow] {
        guard let userId else { return [] }
        let safeUserId = Self.sanitizeParam(userId)
        let calendar = Calendar(identifier: .gregorian)
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: Date()) else { return [] }
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"
        isoFormatter.timeZone = TimeZone(identifier: "UTC")
        let cutoffStr = isoFormatter.string(from: cutoff)
        let path = "/rest/v1/yield_score_daily?user_id=eq.\(safeUserId)&day=gte.\(cutoffStr)&select=provider,day,total_cost,weighted_commit_count,raw_commit_count,ambiguous_commit_count&order=day.desc"
        do {
            let rows: [YieldScoreRow] = try await restGet(path)
            return rows
        } catch {
            return []
        }
    }

    // MARK: - Health

    public func health() async throws -> Bool {
        // Use the auth health endpoint which doesn't require authentication
        guard let url = URL(string: "\(supabaseURL)/auth/v1/health") else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (200...299).contains(status)
    }

    // MARK: - Supabase REST Helpers

    private func restGet<Response: Decodable>(_ path: String, retried: Bool = false) async throws -> Response {
        guard let url = URL(string: supabaseURL + path) else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(&request)
        let (data, response) = try await dataWithRetry(for: request)
        let http = response as? HTTPURLResponse
        // Auto-retry on 401 with token refresh
        if http?.statusCode == 401, !retried {
            let _ = try await refreshAccessToken()
            return try await restGet(path, retried: true)
        }
        guard let httpOK = http, (200...299).contains(httpOK.statusCode) else {
            throw APIError.httpError(status: http?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try decode(Response.self, from: data)
    }

    @discardableResult
    private func restPatch<Body: Encodable>(_ path: String, body: Body, retried: Bool = false) async throws -> Data {
        guard let url = URL(string: supabaseURL + path) else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        applyHeaders(&request)
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await dataWithRetry(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 401, !retried {
            let _ = try await refreshAccessToken()
            return try await restPatch(path, body: body, retried: true)
        }
        guard let httpOK = http, (200...299).contains(httpOK.statusCode) else {
            throw APIError.httpError(status: http?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func restPatch<Response: Decodable, Body: Encodable>(
        _ path: String,
        body: Body,
        responseType: Response.Type,
        retried: Bool = false
    ) async throws -> Response {
        let data = try await restPatch(path, body: body, retried: retried)
        return try decode(responseType, from: data)
    }

    private func rpc<Response: Decodable>(_ function: String, retried: Bool = false) async throws -> Response {
        try await rpc(function, params: EmptyBody(), retried: retried)
    }

    /// RPC that returns raw Data (useful for jsonb-returning functions).
    private func rpcRaw(_ function: String, retried: Bool = false) async throws -> Data {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/rpc/\(function)") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(&request)
        request.httpBody = try encoder.encode(EmptyBody())
        let (data, response) = try await dataWithRetry(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 401, !retried {
            let _ = try await refreshAccessToken()
            return try await rpcRaw(function, retried: true)
        }
        guard let httpOK = http, (200...299).contains(httpOK.statusCode) else {
            throw APIError.httpError(status: http?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func rpc<Response: Decodable, Params: Encodable>(
        _ function: String,
        params: Params,
        retried: Bool = false
    ) async throws -> Response {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/rpc/\(function)") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(&request)
        request.httpBody = try encoder.encode(params)
        let (data, response) = try await dataWithRetry(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 401, !retried {
            let _ = try await refreshAccessToken()
            return try await rpc(function, params: params, retried: true)
        }
        guard let httpOK = http, (200...299).contains(httpOK.statusCode) else {
            throw APIError.httpError(status: http?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try decode(Response.self, from: data)
    }

    /// Execute a URLRequest with automatic retry on transient network errors.
    private func dataWithRetry(for request: URLRequest, maxRetries: Int = 2) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await session.data(for: request)
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
                lastError = error
                if attempt < maxRetries {
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                }
            }
        }
        throw lastError ?? APIError.invalidResponse
    }

    private func applyHeaders(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}

public enum APIError: LocalizedError, Equatable {
    case invalidResponse
    case httpError(status: Int, body: String)
    case tokenExpired

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let status, let body):
            return "HTTP \(status): \(body)"
        case .tokenExpired:
            return "Session expired. Please sign in again."
        }
    }
}
