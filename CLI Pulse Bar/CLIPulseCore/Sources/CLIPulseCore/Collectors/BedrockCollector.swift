// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Bedrock/{BedrockAWSSigner,BedrockUsageStats,
// BedrockSettingsReader}.swift (https://github.com/steipete/CodexBar). The
// SigV4 signer, the Cost Explorer GetCostAndUsage call, and the
// Bedrock-service cost aggregation are ported; the fetch is reimplemented on
// URLSession and mapped to `.statusOnly`.
//
// CodexBar-parity Phase C-19 — add the (absent) AWS Bedrock provider. AWS
// env-var creds + SigV4 → Cost Explorer → current-month Bedrock spend.
// Sandbox-safe (env creds + HTTPS + CryptoKit), stable AWS APIs.
//
// Divergences from upstream:
//   * `URLSession`; no CodexBarLog. DROPS the daily-report machinery (CLI
//     Pulse has no per-provider daily UI) — keeps the monthly total only.
//   * **12h result cache** (Gemini C-19 R1 CRITICAL): AWS Cost Explorer bills
//     ~$0.01 per GetCostAndUsage call. The shared collector TaskGroup can
//     refresh often, so an unguarded collector would silently rack up AWS
//     fees. A 12h actor cache caps the billed call to ~2/day.
//   * env-only creds (no ProviderConfig field — 3 values; LLM-Proxy precedent).
//     NOTE: a MAS app launched from Finder may not inherit shell env vars ⇒
//     this provider is effectively CLI/DEVID-oriented (graceful unavailable
//     on MAS when the creds aren't readable).
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
import CryptoKit

/// Reports current-month AWS Bedrock spend via Cost Explorer (SigV4-signed).
///
/// Creds from env `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (+ optional
/// `AWS_SESSION_TOKEN`); region `AWS_REGION`/`AWS_DEFAULT_REGION`. Result is
/// cached 12h to bound the (billed) Cost Explorer calls.
public struct BedrockCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.bedrock

    static let costExplorerURL = "https://ce.us-east-1.amazonaws.com"
    static let budgetEnv = "CLIPULSE_BEDROCK_BUDGET"
    static let cacheTTL: TimeInterval = 12 * 3600
    static let maxPages = 10

    public func isAvailable(config _: ProviderConfig) -> Bool {
        Self.creds() != nil
    }

    public func collect(config _: ProviderConfig) async throws -> CollectorResult {
        guard let creds = Self.creds() else {
            throw CollectorError.missingCredentials(
                "AWS Bedrock: set AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY")
        }
        // Serve from the 12h cache when fresh — Cost Explorer bills per call.
        if let cached = await Self.cache.value(maxAge: Self.cacheTTL) {
            return cached
        }
        let spend = try await Self.fetchMonthlyBedrockSpend(creds: creds)
        let result = Self.buildResult(spend: spend, region: creds.region, budget: Self.budget())
        await Self.cache.store(result)
        return result
    }

    // MARK: - Credentials (env-only)

    struct Creds: Sendable {
        let accessKeyID: String
        let secretAccessKey: String
        let sessionToken: String?
        let region: String
    }

    static func creds(env: [String: String] = ProcessInfo.processInfo.environment) -> Creds? {
        func clean(_ v: String?) -> String? {
            guard var s = v?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
                s = String(s.dropFirst().dropLast())
            }
            return s.isEmpty ? nil : s
        }
        guard let access = clean(env["AWS_ACCESS_KEY_ID"]),
              let secret = clean(env["AWS_SECRET_ACCESS_KEY"]) else { return nil }
        let region = clean(env["AWS_REGION"]) ?? clean(env["AWS_DEFAULT_REGION"]) ?? "us-east-1"
        return Creds(accessKeyID: access, secretAccessKey: secret,
                     sessionToken: clean(env["AWS_SESSION_TOKEN"]), region: region)
    }

    static func budget(env: [String: String] = ProcessInfo.processInfo.environment) -> Double? {
        guard let raw = env[budgetEnv]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let v = Double(raw), v > 0 else { return nil }
        return v
    }

    // MARK: - 12h cache (caps billed Cost Explorer calls)

    private actor Cache {
        private var stored: (at: Date, result: CollectorResult)?
        func value(maxAge: TimeInterval) -> CollectorResult? {
            guard let s = stored, Date().timeIntervalSince(s.at) < maxAge else { return nil }
            return s.result
        }
        func store(_ result: CollectorResult) { stored = (Date(), result) }
    }
    private static let cache = Cache()

    // MARK: - Cost Explorer (paginated GetCostAndUsage, current month)

    private static func fetchMonthlyBedrockSpend(creds: Creds) async throws -> Double {
        let (start, end) = currentMonthRange()
        var total = 0.0
        var nextToken: String?
        var seen = Set<String>()
        for _ in 0..<maxPages {
            let data = try await callCostExplorer(creds: creds, start: start, end: end, nextToken: nextToken)
            total += try parseTotalCost(data)
            nextToken = nextPageToken(from: data)
            guard let token = nextToken else { break }
            guard seen.insert(token).inserted else { break }   // loop-guard
        }
        return total
    }

    private static func callCostExplorer(
        creds: Creds, start: String, end: String, nextToken: String?) async throws -> Data
    {
        guard let url = URL(string: costExplorerURL) else { throw CollectorError.invalidURL("bedrock ce") }
        var body: [String: Any] = [
            "TimePeriod": ["Start": start, "End": end],
            "Granularity": "MONTHLY",
            "Metrics": ["UnblendedCost"],
            "GroupBy": [["Type": "DIMENSION", "Key": "SERVICE"]],
        ]
        if let nextToken { body["NextPageToken"] = nextToken }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSInsightsIndexService.GetCostAndUsage", forHTTPHeaderField: "X-Amz-Target")
        AWSSigner.sign(request: &request, creds: creds, region: "us-east-1", service: "ce")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.missingCredentials("AWS Bedrock: credentials rejected by Cost Explorer")
        }
        guard status == 200 else { throw CollectorError.httpError(status: status, provider: "AWS Bedrock") }
        return data
    }

    static func parseTotalCost(_ data: Data) throws -> Double {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["ResultsByTime"] as? [[String: Any]] else {
            throw CollectorError.parseFailed("AWS Bedrock: missing ResultsByTime")
        }
        var total = 0.0
        for result in results {
            guard let groups = result["Groups"] as? [[String: Any]] else { continue }
            for group in groups {
                guard let keys = group["Keys"] as? [String],
                      let service = keys.first,
                      service.localizedCaseInsensitiveContains("bedrock"),
                      let metrics = group["Metrics"] as? [String: Any],
                      let unblended = metrics["UnblendedCost"] as? [String: Any],
                      let amountStr = unblended["Amount"] as? String,
                      let amount = Double(amountStr) else { continue }
                total += amount
            }
        }
        return max(0, total)
    }

    static func nextPageToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (json["NextPageToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    static func currentMonthRange(now: Date = Date()) -> (start: String, end: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        return (f.string(from: monthStart), f.string(from: tomorrow))
    }

    // MARK: - Result building (.statusOnly month-to-date spend)

    static func buildResult(spend: Double, region: String, budget: Double?) -> CollectorResult {
        let cost = max(0, spend)
        var status = String(format: "$%.2f this month", cost)
        if let budget, budget > 0 {
            let pct = Int((min(100, max(0, cost / budget * 100))).rounded())
            status += String(format: " · %d%% of $%.0f", pct, budget)
        }
        let usage = ProviderUsage(
            provider: ProviderKind.bedrock.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: cost,
            cost_status_today: "Unavailable", cost_status_week: "Exact",
            quota: nil, remaining: nil,
            plan_type: region, reset_time: nil, tiers: [],
            status_text: status,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "AWS Bedrock", category: "cloud",
                supports_exact_cost: true, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .statusOnly)
    }

    // MARK: - SigV4 signer (ported verbatim from BedrockAWSSigner; CryptoKit)

    enum AWSSigner {
        static func sign(request: inout URLRequest, creds: Creds, region: String, service: String,
                         date: Date = Date()) {
            let amzDate = isoDate(date)
            let dateStamp = stamp(date)
            request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
            if let token = creds.sessionToken {
                request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
            }
            request.setValue(request.url?.host ?? "", forHTTPHeaderField: "Host")
            let bodyHash = sha256Hex(request.httpBody ?? Data())
            request.setValue(bodyHash, forHTTPHeaderField: "x-amz-content-sha256")

            let headers: [(String, String)] = (request.allHTTPHeaderFields ?? [:])
                .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
                .sorted { $0.0 < $1.0 }
            let signedKeys = headers.map(\.0).joined(separator: ";")
            let canonicalHeaders = headers.map { "\($0.0):\($0.1)" }.joined(separator: "\n")

            let url = request.url!
            let path = url.path.isEmpty ? "/" : url.path
            let canonicalRequest = [
                request.httpMethod ?? "GET",
                uriEncodePath(path),
                canonicalQuery(url),
                canonicalHeaders + "\n",
                signedKeys,
                bodyHash,
            ].joined(separator: "\n")

            let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
            let stringToSign = [
                "AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(Data(canonicalRequest.utf8)),
            ].joined(separator: "\n")
            let signature = signatureHex(
                secret: creds.secretAccessKey, dateStamp: dateStamp,
                region: region, service: service, stringToSign: stringToSign)
            request.setValue(
                "AWS4-HMAC-SHA256 Credential=\(creds.accessKeyID)/\(scope), "
                + "SignedHeaders=\(signedKeys), Signature=\(signature)",
                forHTTPHeaderField: "Authorization")
        }

        static func signatureHex(secret: String, dateStamp: String, region: String,
                                 service: String, stringToSign: String) -> String {
            let kDate = hmac(key: Data("AWS4\(secret)".utf8), Data(dateStamp.utf8))
            let kRegion = hmac(key: kDate, Data(region.utf8))
            let kService = hmac(key: kRegion, Data(service.utf8))
            let kSigning = hmac(key: kService, Data("aws4_request".utf8))
            return hmac(key: kSigning, Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        static func hmac(key: Data, _ data: Data) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        }
        static func sha256Hex(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        private static func canonicalQuery(_ url: URL) -> String {
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  !items.isEmpty else { return "" }
            return items.map { "\(uriEncode($0.name))=\(uriEncode($0.value ?? ""))" }.sorted().joined(separator: "&")
        }
        private static func uriEncode(_ s: String) -> String {
            var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        private static func uriEncodePath(_ p: String) -> String {
            p.split(separator: "/", omittingEmptySubsequences: false).map { uriEncode(String($0)) }
                .joined(separator: "/")
        }
        private static func isoDate(_ d: Date) -> String { fmt("yyyyMMdd'T'HHmmss'Z'", d) }
        private static func stamp(_ d: Date) -> String { fmt("yyyyMMdd", d) }
        private static func fmt(_ pattern: String, _ d: Date) -> String {
            let f = DateFormatter(); f.dateFormat = pattern
            f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: d)
        }
    }
}
#endif
