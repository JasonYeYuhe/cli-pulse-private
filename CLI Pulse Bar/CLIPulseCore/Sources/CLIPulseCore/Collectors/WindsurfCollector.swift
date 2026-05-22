// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Windsurf/WindsurfWebFetcher.swift
// (https://github.com/steipete/CodexBar). The Connect-RPC protobuf codec
// (hand-rolled reader/writer + field numbers), the GetPlanStatus request, and
// the daily/weekly quota mapping are ported; the fetch is reimplemented on
// URLSession.
//
// CodexBar-parity Phase C-21 — add the (absent) Windsurf (Cognition/Devin)
// provider. Connect-RPC PROTOBUF endpoint. Unverifiable without a live Devin
// session, but the protobuf codec is unit-testable (encode/decode round-trip).
//
// Divergences from upstream:
//   * `URLSession`; no CodexBarLog. SKIP the Chromium-localStorage LevelDB
//     auto-read (DEVID-only + file-lock-prone, Gemini C-21 R1 LOW) — auth via a
//     manual JSON session bundle (config.manualCookieHeader) or 4 env vars.
//   * nested protobuf messages decoded with a FRESH ProtoReader per
//     length-delimited slice (Gemini C-21 R1 HIGH).
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

#if os(macOS)
import Foundation

/// Reports Windsurf daily/weekly quota windows via the Devin SeatManagement
/// Connect-RPC (protobuf). Auth: a 4-field Devin session bundle (manual JSON
/// paste in `config.manualCookieHeader`, or env `WINDSURF_SESSION_TOKEN` +
/// `WINDSURF_AUTH1_TOKEN` + `WINDSURF_ACCOUNT_ID` + `WINDSURF_PRIMARY_ORG_ID`).
public struct WindsurfCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.windsurf

    static let planStatusURL =
        "https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus"

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveAuth(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let auth = resolveAuth(config: config) else {
            throw CollectorError.missingCredentials(
                "Windsurf: paste a Devin session bundle or set WINDSURF_SESSION_TOKEN + auth1/account/org")
        }
        let data = try await fetchPlanStatus(auth: auth)
        let status = try Self.decodeResponse(data)
        return Self.buildResult(status)
    }

    // MARK: - Auth

    struct Auth: Sendable, Equatable {
        let sessionToken: String
        let auth1Token: String
        let accountID: String
        let primaryOrgID: String
    }

    private func resolveAuth(config: ProviderConfig) -> Auth? {
        if let bundle = config.manualCookieHeader, let a = Self.parseSessionBundle(bundle) { return a }
        let env = ProcessInfo.processInfo.environment
        func e(_ k: String) -> String? {
            let v = env[k]?.trimmingCharacters(in: .whitespacesAndNewlines); return (v?.isEmpty == false) ? v : nil
        }
        guard let s = e("WINDSURF_SESSION_TOKEN"), let a1 = e("WINDSURF_AUTH1_TOKEN"),
              let acc = e("WINDSURF_ACCOUNT_ID"), let org = e("WINDSURF_PRIMARY_ORG_ID") else { return nil }
        return Auth(sessionToken: s, auth1Token: a1, accountID: acc, primaryOrgID: org)
    }

    /// Parses a Devin session-bundle JSON (flexible snake/camel keys). Ported.
    static func parseSessionBundle(_ raw: String) -> Auth? {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func value(_ keys: [String]) -> String? {
            for k in keys {
                if let s = (dict[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    return s
                }
            }
            return nil
        }
        guard let s = value(["devin_session_token", "devinSessionToken", "sessionToken"]),
              let a1 = value(["devin_auth1_token", "devinAuth1Token", "auth1Token"]),
              let acc = value(["devin_account_id", "devinAccountId", "accountID", "accountId"]),
              let org = value(["devin_primary_org_id", "devinPrimaryOrgId", "primaryOrgID", "primaryOrgId"])
        else { return nil }
        return Auth(sessionToken: s, auth1Token: a1, accountID: acc, primaryOrgID: org)
    }

    // MARK: - Networking (Connect unary protobuf)

    private func fetchPlanStatus(auth: Auth) async throws -> Data {
        guard let url = URL(string: Self.planStatusURL) else { throw CollectorError.invalidURL("windsurf") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("https://windsurf.com", forHTTPHeaderField: "Origin")
        request.setValue("https://windsurf.com/profile", forHTTPHeaderField: "Referer")
        request.setValue(auth.sessionToken, forHTTPHeaderField: "x-auth-token")
        request.setValue(auth.sessionToken, forHTTPHeaderField: "x-devin-session-token")
        request.setValue(auth.auth1Token, forHTTPHeaderField: "x-devin-auth1-token")
        request.setValue(auth.accountID, forHTTPHeaderField: "x-devin-account-id")
        request.setValue(auth.primaryOrgID, forHTTPHeaderField: "x-devin-primary-org-id")
        request.httpBody = Self.encodeRequest(authToken: auth.sessionToken, includeTopUpStatus: true)

        let (data, response) = try await URLSession.shared.data(for: request)
        let s = (response as? HTTPURLResponse)?.statusCode ?? 0
        if s == 401 || s == 403 { throw CollectorError.missingCredentials("Windsurf: session expired/invalid") }
        guard s == 200 else { throw CollectorError.httpError(status: s, provider: "Windsurf") }
        return data
    }

    // MARK: - Protobuf decode → snapshot

    struct PlanStatus: Sendable, Equatable {
        var planName: String?
        var dailyRemainingPercent: Int?
        var weeklyRemainingPercent: Int?
        var dailyResetUnix: Int64?
        var weeklyResetUnix: Int64?
        var planEndUnix: Int64?
    }

    static func encodeRequest(authToken: String, includeTopUpStatus: Bool) -> Data {
        var d = Data()
        Proto.appendKey(1, .lengthDelimited, &d); Proto.appendString(authToken, &d)
        Proto.appendKey(2, .varint, &d); Proto.appendVarint(includeTopUpStatus ? 1 : 0, &d)
        return d
    }

    static func decodeResponse(_ data: Data) throws -> PlanStatus? {
        var reader = Proto.Reader(data)
        var status: PlanStatus?
        while let f = try reader.next() {
            if f.number == 1, f.wire == .lengthDelimited {
                status = try decodePlanStatus(reader.readData())   // fresh reader inside
            } else { try reader.skip(f.wire) }
        }
        return status
    }

    private static func decodePlanStatus(_ data: Data) throws -> PlanStatus {
        var reader = Proto.Reader(data)
        var s = PlanStatus()
        while let f = try reader.next() {
            switch (f.number, f.wire) {
            case (1, .lengthDelimited): s.planName = try decodePlanName(reader.readData())
            case (3, .lengthDelimited): s.planEndUnix = try decodeTimestampSeconds(reader.readData())
            case (14, .varint): s.dailyRemainingPercent = Int(try reader.readVarint())
            case (15, .varint): s.weeklyRemainingPercent = Int(try reader.readVarint())
            case (17, .varint): s.dailyResetUnix = Int64(try reader.readVarint())
            case (18, .varint): s.weeklyResetUnix = Int64(try reader.readVarint())
            default: try reader.skip(f.wire)
            }
        }
        return s
    }

    private static func decodePlanName(_ data: Data) throws -> String? {
        var reader = Proto.Reader(data)
        var name: String?
        while let f = try reader.next() {
            if f.number == 2, f.wire == .lengthDelimited { name = try reader.readString() }
            else { try reader.skip(f.wire) }
        }
        return name
    }

    private static func decodeTimestampSeconds(_ data: Data) throws -> Int64? {
        var reader = Proto.Reader(data)
        var seconds: Int64?
        while let f = try reader.next() {
            if f.number == 1, f.wire == .varint { seconds = Int64(try reader.readVarint()) }
            else { try reader.skip(f.wire) }
        }
        return seconds
    }

    // MARK: - Result building (.quota daily + weekly remaining-% windows)

    static func buildResult(_ status: PlanStatus?) -> CollectorResult {
        func iso(_ unix: Int64?) -> String? {
            guard let unix, unix > 0 else { return nil }
            return sharedISO8601Formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
        }
        let plan = (status?.planName?.isEmpty == false) ? status!.planName! : "Windsurf"

        guard let status, status.dailyRemainingPercent != nil || status.weeklyRemainingPercent != nil else {
            let usage = ProviderUsage(
                provider: ProviderKind.windsurf.rawValue, today_usage: 0, week_usage: 0,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                quota: nil, remaining: nil, plan_type: plan, reset_time: nil, tiers: [],
                status_text: "Connected", trend: [], recent_sessions: [], recent_errors: [],
                metadata: ProviderMetadata(display_name: "Windsurf", category: "ide",
                                           supports_exact_cost: false, supports_quota: false))
            return CollectorResult(usage: usage, dataKind: .statusOnly)
        }

        func clampPct(_ p: Int?) -> Int { max(0, min(100, p ?? 0)) }
        let daily = clampPct(status.dailyRemainingPercent)
        let weekly = clampPct(status.weeklyRemainingPercent)
        let dailyResetISO = iso(status.dailyResetUnix)
        var tiers: [TierDTO] = []
        if status.dailyRemainingPercent != nil {
            tiers.append(TierDTO(name: "Daily", quota: 100, remaining: daily, reset_time: dailyResetISO))
        }
        if status.weeklyRemainingPercent != nil {
            tiers.append(TierDTO(name: "Weekly", quota: 100, remaining: weekly, reset_time: iso(status.weeklyResetUnix)))
        }
        var parts: [String] = []
        if status.dailyRemainingPercent != nil { parts.append("Daily \(daily)% left") }
        if status.weeklyRemainingPercent != nil { parts.append("Weekly \(weekly)% left") }

        let usage = ProviderUsage(
            provider: ProviderKind.windsurf.rawValue, today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: status.dailyRemainingPercent != nil ? daily : weekly,
            plan_type: plan, reset_time: dailyResetISO, tiers: tiers,
            status_text: parts.joined(separator: " · "),
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "Windsurf", category: "ide",
                                       supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }
}

// MARK: - Minimal protobuf reader/writer (ported; reusable)

enum Proto {
    enum Wire: UInt64 { case varint = 0, fixed64 = 1, lengthDelimited = 2, startGroup = 3, endGroup = 4, fixed32 = 5 }
    struct Field { let number: Int; let wire: Wire }
    enum ProtoError: Error { case truncated, badWireType, badKey, invalidUTF8 }

    struct Reader {
        private let bytes: [UInt8]
        private var i = 0
        init(_ data: Data) { bytes = Array(data) }

        mutating func next() throws -> Field? {
            guard i < bytes.count else { return nil }
            let key = try readVarint()
            let number = Int(key >> 3)
            guard number > 0 else { throw ProtoError.badKey }
            guard let wire = Wire(rawValue: key & 0x07) else { throw ProtoError.badWireType }
            return Field(number: number, wire: wire)
        }
        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift >= 64 { throw ProtoError.truncated }
            }
            throw ProtoError.truncated
        }
        mutating func readData() throws -> Data {
            let len = Int(try readVarint())
            guard len >= 0, i + len <= bytes.count else { throw ProtoError.truncated }
            defer { i += len }
            return Data(bytes[i..<(i + len)])
        }
        mutating func readString() throws -> String {
            guard let s = String(data: try readData(), encoding: .utf8) else { throw ProtoError.invalidUTF8 }
            return s
        }
        mutating func skip(_ wire: Wire) throws {
            switch wire {
            case .varint: _ = try readVarint()
            case .fixed64: guard i + 8 <= bytes.count else { throw ProtoError.truncated }; i += 8
            case .lengthDelimited: _ = try readData()
            case .fixed32: guard i + 4 <= bytes.count else { throw ProtoError.truncated }; i += 4
            case .startGroup, .endGroup: throw ProtoError.badWireType
            }
        }
    }

    static func appendVarint(_ value: UInt64, _ data: inout Data) {
        var v = value
        while v >= 0x80 { data.append(UInt8((v & 0x7F) | 0x80)); v >>= 7 }
        data.append(UInt8(v))
    }
    static func appendKey(_ field: Int, _ wire: Wire, _ data: inout Data) {
        appendVarint(UInt64((field << 3) | Int(wire.rawValue)), &data)
    }
    static func appendString(_ s: String, _ data: inout Data) {
        let e = Data(s.utf8); appendVarint(UInt64(e.count), &data); data.append(e)
    }
}
#endif
