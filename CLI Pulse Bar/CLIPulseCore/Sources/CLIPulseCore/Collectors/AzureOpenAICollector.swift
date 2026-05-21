// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/AzureOpenAI/{AzureOpenAIUsageFetcher,
// AzureOpenAISettingsReader,AzureOpenAIProviderDescriptor}.swift
// (https://github.com/steipete/CodexBar). The deployment-validation
// probe (v1-vs-legacy URL construction + `apiRoot` path de-dup +
// version-aligned ping body) is ported verbatim into pure testable
// statics; the fetch path is reimplemented on URLSession.
//
// CodexBar-parity Phase C-5 — add the (absent) Azure OpenAI provider
// as a `.statusOnly` collector. Azure exposes NO per-key quota/credits
// number, so CodexBar (and we) validate the deployment with a tiny
// "ping" chat-completion and surface the resolved model — there is no
// quantitative gauge.
//
// Divergences from upstream:
//   * `URLSession` instead of CodexBar's `ProviderHTTPClient`; no
//     CodexBarLog. Explicit 15s `timeoutInterval` (Gemini C-5 R1
//     MEDIUM — no central client to enforce a short timeout).
//   * Multi-field config from env (ProviderConfig stores only
//     `apiKey`): endpoint + deployment + api-version read from
//     AZURE_OPENAI_* (the VertexAI multi-field-from-env precedent).
//     The api key may also come from `config.apiKey`.
//   * statusOnly mapping: top-level `quota`/`remaining` are nil and
//     `today/week_usage` = 0 (no gauge); the status line carries the
//     "Deployment · Model" detail. CodexBar's `usedPercent:0` snapshot
//     becomes `dataKind: .statusOnly` rather than a 0%-gauge.
//   * Env-var surrounding-quote stripping NOT ported (YAGNI — matches
//     the DeepSeek/Crof/Venice collectors; central helper if ever
//     needed across the board).
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

/// Validates an Azure OpenAI deployment via api-key auth and surfaces
/// the resolved model. Status-only — Azure exposes no per-key quota.
///
/// Probe: `POST {endpoint}/openai/deployments/{dep}/chat/completions
/// ?api-version={ver}` (legacy) or `…/openai/v1/chat/completions` (v1),
/// header `api-key: <key>`, body a 1-token "ping". 2xx ⇒ reachable.
/// Config: `config.apiKey` or `AZURE_OPENAI_API_KEY`; endpoint +
/// deployment + version from `AZURE_OPENAI_ENDPOINT` /
/// `AZURE_OPENAI_DEPLOYMENT_NAME` / `AZURE_OPENAI_API_VERSION`.
public struct AzureOpenAICollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.azureOpenAI

    static let apiKeyEnv = "AZURE_OPENAI_API_KEY"
    static let endpointEnv = "AZURE_OPENAI_ENDPOINT"
    static let deploymentEnv = "AZURE_OPENAI_DEPLOYMENT_NAME"
    static let apiVersionEnv = "AZURE_OPENAI_API_VERSION"
    static let defaultAPIVersion = "2024-10-21"

    public func isAvailable(config: ProviderConfig) -> Bool {
        isAvailable(config: config, env: ProcessInfo.processInfo.environment)
    }

    /// Testable seam — all three of key/endpoint/deployment must resolve.
    func isAvailable(config: ProviderConfig, env: [String: String]) -> Bool {
        resolveAPIKey(config: config, env: env) != nil
            && Self.resolveEndpoint(env: env) != nil
            && Self.resolveDeployment(env: env) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let env = ProcessInfo.processInfo.environment
        guard let apiKey = resolveAPIKey(config: config, env: env) else {
            throw CollectorError.missingCredentials(
                "Azure OpenAI: no API key (set AZURE_OPENAI_API_KEY or configure a key)")
        }
        guard let endpoint = Self.resolveEndpoint(env: env) else {
            throw CollectorError.missingCredentials(
                "Azure OpenAI: no endpoint (set AZURE_OPENAI_ENDPOINT)")
        }
        guard let deployment = Self.resolveDeployment(env: env) else {
            throw CollectorError.missingCredentials(
                "Azure OpenAI: no deployment (set AZURE_OPENAI_DEPLOYMENT_NAME)")
        }
        let apiVersion = Self.resolveAPIVersion(env: env)

        let model = try await fetchModel(
            apiKey: apiKey, endpoint: endpoint,
            deploymentName: deployment, apiVersion: apiVersion)
        return Self.buildResult(
            endpointHost: endpoint.host ?? endpoint.absoluteString,
            deploymentName: deployment, model: model)
    }

    // MARK: - Credential resolution

    private func resolveAPIKey(config: ProviderConfig, env: [String: String]) -> String? {
        if let k = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        return Self.cleaned(env[Self.apiKeyEnv])
    }

    static func resolveEndpoint(env: [String: String]) -> URL? {
        guard let raw = cleaned(env[endpointEnv]) else { return nil }
        return endpointURL(from: raw)
    }

    static func resolveDeployment(env: [String: String]) -> String? {
        cleaned(env[deploymentEnv])
    }

    static func resolveAPIVersion(env: [String: String]) -> String {
        cleaned(env[apiVersionEnv]) ?? defaultAPIVersion
    }

    /// Normalize a raw endpoint string into a URL with a host. Prepends
    /// `https://` when no scheme is present (vendored from CodexBar's
    /// `endpointURL(from:)`).
    static func endpointURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme),
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }
        return url
    }

    static func cleaned(_ raw: String?) -> String? {
        guard let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return nil
        }
        return v
    }

    // MARK: - URL construction (vendored verbatim — the porting risk)

    static func usesV1API(_ apiVersion: String) -> Bool {
        apiVersion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "v1"
    }

    /// Append `expectedComponents` to `endpoint`, skipping any suffix the
    /// endpoint already ends with (so an endpoint already containing
    /// `/openai` is not doubled). Built via `appendingPathComponent`,
    /// which both percent-encodes and avoids double-slashes (Gemini
    /// C-5 R1 HIGH/MEDIUM). Vendored from CodexBar.
    static func apiRoot(endpoint: URL, pathComponents expectedComponents: [String]) -> URL {
        let existing = endpoint.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        let expected = expectedComponents.map { $0.lowercased() }
        let sharedCount = stride(
            from: min(existing.count, expected.count), through: 0, by: -1)
            .first { count in
                count == 0 || Array(existing.suffix(count)) == Array(expected.prefix(count))
            } ?? 0
        return expected.dropFirst(sharedCount).reduce(endpoint) { url, component in
            url.appendingPathComponent(component)
        }
    }

    /// Build the chat/completions URL. v1 ⇒ `…/openai/v1/chat/completions`
    /// (no query); legacy ⇒ `…/openai/deployments/{dep}/chat/completions
    /// ?api-version={ver}`. `appendingPathComponent(deploymentName)`
    /// percent-encodes the deployment segment (Gemini C-5 R1 HIGH).
    static func chatCompletionsURL(
        endpoint: URL, deploymentName: String, apiVersion: String) throws -> URL
    {
        if usesV1API(apiVersion) {
            let base = apiRoot(endpoint: endpoint, pathComponents: ["openai", "v1"])
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
            guard let url = URLComponents(url: base, resolvingAgainstBaseURL: false)?.url else {
                throw CollectorError.invalidURL("azure openai v1 chat/completions")
            }
            return url
        }
        let base = apiRoot(endpoint: endpoint, pathComponents: ["openai"])
            .appendingPathComponent("deployments")
            .appendingPathComponent(deploymentName)
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw CollectorError.invalidURL("azure openai chat/completions")
        }
        components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
        guard let url = components.url else {
            throw CollectorError.invalidURL("azure openai chat/completions query")
        }
        return url
    }

    /// 1-token "ping" validation body. v1 carries `model` +
    /// `max_completion_tokens`; legacy carries `max_tokens` (Gemini
    /// C-5 R1 MEDIUM — strictly version-aligned). Vendored.
    static func validationRequestBody(deploymentName: String, apiVersion: String) throws -> Data {
        var payload: [String: Any] = [
            "messages": [["role": "user", "content": "ping"]],
        ]
        if usesV1API(apiVersion) {
            payload["model"] = deploymentName
            payload["max_completion_tokens"] = 1
        } else {
            payload["max_tokens"] = 1
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    // MARK: - Response

    struct ChatCompletionResponse: Decodable, Sendable {
        let model: String?
    }

    /// Decode the `model` field from a chat-completion response
    /// (nil-tolerant; testable).
    static func parseModel(_ data: Data) throws -> String? {
        do {
            return try JSONDecoder().decode(ChatCompletionResponse.self, from: data).model
        } catch {
            throw CollectorError.parseFailed("Azure OpenAI: \(error.localizedDescription)")
        }
    }

    // MARK: - Networking

    private func fetchModel(
        apiKey: String, endpoint: URL,
        deploymentName: String, apiVersion: String) async throws -> String?
    {
        let url = try Self.chatCompletionsURL(
            endpoint: endpoint, deploymentName: deploymentName, apiVersion: apiVersion)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.validationRequestBody(
            deploymentName: deploymentName, apiVersion: apiVersion)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CollectorError.httpError(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: "Azure OpenAI")
        }
        return try Self.parseModel(data)
    }

    // MARK: - Result building (.statusOnly — no gauge)

    static func formatStatusText(deploymentName: String, model: String?) -> String {
        let cleanedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanedModel, !cleanedModel.isEmpty {
            return "Deployment: \(deploymentName) · Model: \(cleanedModel)"
        }
        return "Deployment: \(deploymentName)"
    }

    static func buildResult(
        endpointHost: String, deploymentName: String, model: String?) -> CollectorResult
    {
        let usage = ProviderUsage(
            provider: ProviderKind.azureOpenAI.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: nil, remaining: nil,
            plan_type: endpointHost,
            reset_time: nil,
            tiers: [],
            status_text: formatStatusText(deploymentName: deploymentName, model: model),
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Azure OpenAI", category: "cloud",
                supports_exact_cost: false, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .statusOnly)
    }
}
#endif
