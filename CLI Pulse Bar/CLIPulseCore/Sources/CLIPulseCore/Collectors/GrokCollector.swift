// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Grok/GrokWebBillingFetcher.swift
// (https://github.com/steipete/CodexBar). The gRPC-web framing, the
// schema-agnostic protobuf scanner, the GetGrokCreditsConfig empty-frame
// request, and the usedPercent/reset heuristic are ported; the fetch is
// reimplemented on URLSession + CLI Pulse's G1 `CookieResolver` seam.
//
// CodexBar-parity Phase C-23 — add the (absent) Grok (xAI) provider. The LAST
// of the 48-provider catalog ⇒ 48/48 parity. gRPC-web + protobuf.
//
// Divergences from upstream:
//   * `URLSession`; no CodexBarLog. Auth is the SANDBOX-SAFE web billing path
//     (cookie / Bearer), NOT the `grok agent stdio` subprocess (App-Sandbox /
//     MAS-blocked) — Gemini C-23 Q1.
//   * a usedPercent that can't be located ⇒ `.statusOnly` "Connected" (auth
//     worked, schema drifted) instead of upstream's hard `.parseFailed` —
//     Gemini C-23 Q5 graceful fallback.
//   * reset varint accepts BOTH unix-seconds [1.7e9,2.1e9] AND unix-millis
//     [1.7e12,2.1e12] (÷1000) — Gemini C-23 R1 LOW (ms-timestamp drift).
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

/// Reports Grok (xAI) credit usage via the grok.com gRPC-web billing RPC.
///
/// `POST grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig` (empty gRPC-web
/// frame body — the RPC takes no args). Auth: a grok.com session `Cookie:`
/// (auto-import / manual paste / env `GROK_COOKIE`) OR a Bearer token from env
/// `GROK_TOKEN`. The response is a schema-less protobuf scanned heuristically
/// for a used-percent (fixed32, path ends `1`, 0–100) + a reset timestamp.
public struct GrokCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.grok

    static let endpoint = "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"
    private static let cookieEnvVars = ["GROK_COOKIE"]
    private static let tokenEnvVar = "GROK_TOKEN"
    private static let cookieDomains = ["grok.com"]

    public func isAvailable(config: ProviderConfig) -> Bool {
        if config.cookieSource == .automatic { return true }
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        let env = ProcessInfo.processInfo.environment
        if !(env[Self.cookieEnvVars[0]] ?? "").isEmpty { return true }
        if !(env[Self.tokenEnvVar] ?? "").isEmpty { return true }
        return false
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let auth = try await resolveAuth(config: config)
        let data = try await Self.fetchOnce(auth: auth)
        let snapshot = try Self.parseGRPCWebResponse(data)
        return Self.buildResult(snapshot)
    }

    // MARK: - Auth

    enum Auth: Equatable { case cookie(String); case bearer(String) }

    private func resolveAuth(config: ProviderConfig) async throws -> Auth {
        // [] ⇒ grab ALL grok.com cookies (session cookie name is dynamic).
        let resolution = await CookieResolver.resolve(
            config: config,
            envVarNames: Self.cookieEnvVars,
            domains: Self.cookieDomains,
            knownSessionCookieNames: [])
        if let header = resolution.headerValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !header.isEmpty {
            return .cookie(header)
        }
        if let token = ProcessInfo.processInfo.environment[Self.tokenEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return .bearer(token)
        }
        throw CollectorError.missingCredentials(
            "Grok: sign in at grok.com (cookie auto-import) or set GROK_TOKEN")
    }

    // MARK: - Networking (gRPC-web unary, empty request frame)

    static func fetchOnce(auth: Auth) async throws -> Data {
        guard let url = URL(string: Self.endpoint) else { throw CollectorError.invalidURL("grok") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        // gRPC-web frame: 1-byte flag (0 = data) + 4-byte big-endian length (0).
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        switch auth {
        case let .cookie(header): request.setValue(header, forHTTPHeaderField: "Cookie")
        case let .bearer(token): request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.missingCredentials(
                "Grok: session expired/invalid (sign in at grok.com or refresh GROK_TOKEN)")
        }
        guard status == 200 else { throw CollectorError.httpError(status: status, provider: "Grok") }
        // grpc-status can ride on the HTTP headers AND/OR the trailer frame.
        try Self.validateGRPCStatusFields(Self.grpcHeaderFields(from: http?.allHeaderFields ?? [:]))
        try Self.validateGRPCWebTrailers(data)
        return data
    }

    // MARK: - gRPC-web framing

    /// Extracts the payloads of data frames (flag bit 0x80 clear). 5-byte
    /// prefix = 1 flag byte + 4 big-endian length bytes.
    static func grpcWebDataFrames(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var frames: [Data] = []
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if flags & 0x80 == 0 { frames.append(Data(bytes[start..<end])) }
            index = end
        }
        return frames
    }

    static func validateGRPCWebTrailers(_ data: Data) throws {
        try Self.validateGRPCStatusFields(Self.grpcWebTrailerFields(from: data))
    }

    static func validateGRPCStatusFields(_ fields: [String: String]) throws {
        guard let rawStatus = fields["grpc-status"], let status = Int(rawStatus), status != 0 else { return }
        if status == 16 {
            throw CollectorError.missingCredentials(
                "Grok: unauthenticated (sign in at grok.com or refresh GROK_TOKEN)")
        }
        throw CollectorError.parseFailed("Grok: RPC status \(status) \(fields["grpc-message"] ?? "")")
    }

    static func grpcHeaderFields(from headers: [AnyHashable: Any]) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in headers {
            let normalizedKey = String(describing: key)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalizedKey.hasPrefix("grpc-") else { continue }
            fields[normalizedKey] = String(describing: value)
                .trimmingCharacters(in: .whitespacesAndNewlines).removingPercentEncoding ?? ""
        }
        return fields
    }

    static func grpcWebTrailerFields(from data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var fields: [String: String] = [:]
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if flags & 0x80 != 0, let text = String(data: Data(bytes[start..<end]), encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let key = line[..<separator]
                        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let value = line[line.index(after: separator)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines).removingPercentEncoding ?? ""
                    fields[key] = value
                }
            }
            index = end
        }
        return fields
    }

    // MARK: - Heuristic protobuf scan → snapshot

    struct Snapshot: Sendable, Equatable {
        let usedPercent: Double?
        let resetsAt: Date?
    }

    static func parseGRPCWebResponse(_ data: Data, now: Date = Date()) throws -> Snapshot {
        let payloads = Self.grpcWebDataFrames(from: data)
        guard !payloads.isEmpty else { throw CollectorError.parseFailed("Grok: empty gRPC-web payload") }

        var scan = ProtobufScan()
        for payload in payloads { scan.merge(Self.scanProtobuf(payload, depth: 0)) }

        // used-percent = the fixed32 (Float) whose field-path ends in `1`,
        // value 0–100, shallowest then earliest.
        let parsedPercent = scan.fixed32Fields
            .filter { $0.path.last == 1 && $0.value.isFinite && $0.value >= 0 && $0.value <= 100 }
            .min { lhs, rhs in
                lhs.path.count == rhs.path.count ? lhs.order < rhs.order : lhs.path.count < rhs.path.count
            }
            .map { Double($0.value) }

        // reset = a future unix-ts varint; accept seconds OR millis. Prefer [1,5,1].
        let resetFields = scan.varintFields.compactMap { field -> (path: [UInt64], date: Date)? in
            let raw = field.value
            if raw >= 1_700_000_000, raw <= 2_100_000_000 {
                return (field.path, Date(timeIntervalSince1970: TimeInterval(raw)))
            }
            if raw >= 1_700_000_000_000, raw <= 2_100_000_000_000 {
                return (field.path, Date(timeIntervalSince1970: TimeInterval(raw) / 1000))
            }
            return nil
        }
        let futureResetFields = resetFields.filter { $0.date > now }
        let reset = futureResetFields.filter { $0.path == [1, 5, 1] }.map(\.date).min()
            ?? futureResetFields.map(\.date).min()

        // "No usage yet": reset present + a [1,6,…] varint, no fixed32 ⇒ 0% used.
        let noUsageYet = parsedPercent == nil
            && scan.fixed32Fields.isEmpty
            && reset != nil
            && scan.varintFields.contains { $0.path.starts(with: [1, 6]) }
        let percent = parsedPercent ?? (noUsageYet ? 0 : nil)
        return Snapshot(usedPercent: percent, resetsAt: reset)
    }

    struct ProtobufScan {
        struct Fixed32Field { var path: [UInt64]; var value: Float; var order: Int }
        struct VarintField { var path: [UInt64]; var value: UInt64 }
        var fixed32Fields: [Fixed32Field] = []
        var varintFields: [VarintField] = []
        mutating func merge(_ other: ProtobufScan) {
            fixed32Fields.append(contentsOf: other.fixed32Fields)
            varintFields.append(contentsOf: other.varintFields)
        }
    }

    static func scanProtobuf(_ data: Data, depth: Int) -> ProtobufScan {
        Self.scanProtobuf(data, depth: depth, path: [], order: 0).scan
    }

    private static func scanProtobuf(
        _ data: Data, depth: Int, path: [UInt64], order: Int) -> (scan: ProtobufScan, order: Int)
    {
        let bytes = [UInt8](data)
        var scan = ProtobufScan()
        var index = 0
        var nextOrder = order
        while index < bytes.count {
            let fieldStart = index
            guard let key = Self.readVarint(bytes, index: &index), key != 0 else {
                index = fieldStart + 1
                continue
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            let fieldPath = path + [fieldNumber]
            switch wireType {
            case 0:
                if let value = Self.readVarint(bytes, index: &index) {
                    scan.varintFields.append(ProtobufScan.VarintField(path: fieldPath, value: value))
                } else {
                    index = fieldStart + 1
                }
            case 1:
                guard index + 8 <= bytes.count else { return (scan, nextOrder) }
                index += 8
            case 2:
                guard let length = Self.readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index) else {
                    index = fieldStart + 1
                    continue
                }
                let start = index
                let end = index + Int(length)
                if depth < 4 {
                    let nested = Self.scanProtobuf(
                        Data(bytes[start..<end]), depth: depth + 1, path: fieldPath, order: nextOrder)
                    scan.merge(nested.scan)
                    nextOrder = nested.order
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return (scan, nextOrder) }
                let bitPattern = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                scan.fixed32Fields.append(ProtobufScan.Fixed32Field(
                    path: fieldPath, value: Float(bitPattern: bitPattern), order: nextOrder))
                nextOrder += 1
                index += 4
            default:
                index = fieldStart + 1
            }
        }
        return (scan, nextOrder)
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    // MARK: - Result building (.quota usedPercent window; .statusOnly fallback)

    static func buildResult(_ snapshot: Snapshot) -> CollectorResult {
        let resetISO = snapshot.resetsAt.map { sharedISO8601Formatter.string(from: $0) }
        guard let used = snapshot.usedPercent else {
            // Auth succeeded but no usable usage field ⇒ status-only.
            let usage = ProviderUsage(
                provider: ProviderKind.grok.rawValue, today_usage: 0, week_usage: 0,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                quota: nil, remaining: nil, plan_type: "Grok", reset_time: resetISO, tiers: [],
                status_text: "Connected", trend: [], recent_sessions: [], recent_errors: [],
                metadata: ProviderMetadata(display_name: "Grok", category: "cloud",
                                           supports_exact_cost: false, supports_quota: false))
            return CollectorResult(usage: usage, dataKind: .statusOnly)
        }
        let clamped = max(0.0, min(100.0, used))
        let remaining = Int((100.0 - clamped).rounded())
        let usage = ProviderUsage(
            provider: ProviderKind.grok.rawValue, today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: remaining, plan_type: "Grok", reset_time: resetISO,
            tiers: [TierDTO(name: "Credits", quota: 100, remaining: remaining, reset_time: resetISO)],
            status_text: "\(remaining)% left",
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "Grok", category: "cloud",
                                       supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }
}
#endif
