// Unit tests for the v1.23.0 Phase C-5 AzureOpenAICollector (new
// status-only deployment validator). Locks the Gemini C-5 R1
// adoptions: v1-vs-legacy URL construction, `apiRoot` path de-dup,
// deployment-name path-encoding, version-aligned ping body, and the
// statusOnly nil-gauge mapping. macOS-gated like the other collector
// tests.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class AzureOpenAICollectorTests: XCTestCase {
    private let collector = AzureOpenAICollector()
    private let endpoint = URL(string: "https://myrg.openai.azure.com")!

    // MARK: - URL construction (the porting risk)

    func test_url_legacy_path_and_query() throws {
        let url = try AzureOpenAICollector.chatCompletionsURL(
            endpoint: endpoint, deploymentName: "gpt-4o", apiVersion: "2024-10-21")
        XCTAssertEqual(
            url.absoluteString,
            "https://myrg.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-21")
    }

    func test_url_v1_has_no_query() throws {
        let url = try AzureOpenAICollector.chatCompletionsURL(
            endpoint: endpoint, deploymentName: "gpt-4o", apiVersion: "v1")
        XCTAssertEqual(
            url.absoluteString,
            "https://myrg.openai.azure.com/openai/v1/chat/completions")
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    func test_url_endpoint_already_ending_openai_is_not_doubled() throws {
        let withOpenAI = URL(string: "https://myrg.openai.azure.com/openai")!
        let url = try AzureOpenAICollector.chatCompletionsURL(
            endpoint: withOpenAI, deploymentName: "gpt-4o", apiVersion: "2024-10-21")
        XCTAssertEqual(
            url.absoluteString,
            "https://myrg.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-21")
        XCTAssertFalse(url.absoluteString.contains("/openai/openai"))
    }

    func test_url_deployment_name_is_percent_encoded() throws {
        // Gemini C-5 R1 HIGH: spaces/odd chars in the deployment name
        // must not break URL construction — appendingPathComponent encodes.
        let url = try AzureOpenAICollector.chatCompletionsURL(
            endpoint: endpoint, deploymentName: "my deployment", apiVersion: "2024-10-21")
        XCTAssertTrue(url.absoluteString.contains("/deployments/my%20deployment/"))
    }

    func test_usesV1API_matches_only_v1() {
        XCTAssertTrue(AzureOpenAICollector.usesV1API("v1"))
        XCTAssertTrue(AzureOpenAICollector.usesV1API("  V1 "))
        XCTAssertFalse(AzureOpenAICollector.usesV1API("2024-10-21"))
        XCTAssertFalse(AzureOpenAICollector.usesV1API(""))
    }

    // MARK: - Validation body (version-aligned token key)

    func test_validationBody_legacy_uses_max_tokens() throws {
        let data = try AzureOpenAICollector.validationRequestBody(
            deploymentName: "gpt-4o", apiVersion: "2024-10-21")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["max_tokens"] as? Int, 1)
        XCTAssertNil(obj["max_completion_tokens"])
        XCTAssertNil(obj["model"])  // legacy carries the deployment in the path, not the body
    }

    func test_validationBody_v1_uses_max_completion_tokens_and_model() throws {
        let data = try AzureOpenAICollector.validationRequestBody(
            deploymentName: "gpt-4o", apiVersion: "v1")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["max_completion_tokens"] as? Int, 1)
        XCTAssertEqual(obj["model"] as? String, "gpt-4o")
        XCTAssertNil(obj["max_tokens"])
    }

    // MARK: - Response parse

    func test_parseModel_reads_model() throws {
        let model = try AzureOpenAICollector.parseModel(Data("""
        {"model":"gpt-4o-2024-08-06","choices":[]}
        """.utf8))
        XCTAssertEqual(model, "gpt-4o-2024-08-06")
    }

    func test_parseModel_nil_when_absent_or_null() throws {
        XCTAssertNil(try AzureOpenAICollector.parseModel(Data("""
        {"choices":[]}
        """.utf8)))
        XCTAssertNil(try AzureOpenAICollector.parseModel(Data("{\"model\":null}".utf8)))
    }

    func test_parseModel_invalid_json_throws() {
        XCTAssertThrowsError(try AzureOpenAICollector.parseModel(Data("not json".utf8)))
    }

    // MARK: - status_text formatting

    func test_statusText_with_model() {
        XCTAssertEqual(
            AzureOpenAICollector.formatStatusText(deploymentName: "gpt-4o", model: "gpt-4o-2024-08-06"),
            "Deployment: gpt-4o · Model: gpt-4o-2024-08-06")
    }

    func test_statusText_without_model() {
        XCTAssertEqual(
            AzureOpenAICollector.formatStatusText(deploymentName: "gpt-4o", model: nil),
            "Deployment: gpt-4o")
        XCTAssertEqual(
            AzureOpenAICollector.formatStatusText(deploymentName: "gpt-4o", model: "   "),
            "Deployment: gpt-4o")
    }

    // MARK: - buildResult: statusOnly nil-gauge

    func test_buildResult_statusOnly_nil_gauge() {
        let r = AzureOpenAICollector.buildResult(
            endpointHost: "myrg.openai.azure.com", deploymentName: "gpt-4o", model: "gpt-4o-2024-08-06")
        XCTAssertEqual(r.dataKind, .statusOnly)
        let u = r.usage
        XCTAssertNil(u.quota)
        XCTAssertNil(u.remaining)
        XCTAssertEqual(u.today_usage, 0)
        XCTAssertEqual(u.week_usage, 0)
        XCTAssertTrue(u.tiers.isEmpty)
        XCTAssertNil(u.reset_time)
        XCTAssertEqual(u.plan_type, "myrg.openai.azure.com")
        XCTAssertEqual(u.status_text, "Deployment: gpt-4o · Model: gpt-4o-2024-08-06")
        XCTAssertEqual(u.metadata?.supports_quota, false)
    }

    // MARK: - Credential resolution (synthetic env)

    func test_resolveEndpoint_prepends_scheme_and_requires_host() {
        XCTAssertEqual(
            AzureOpenAICollector.resolveEndpoint(env: ["AZURE_OPENAI_ENDPOINT": "myrg.openai.azure.com"])?.host,
            "myrg.openai.azure.com")
        XCTAssertEqual(
            AzureOpenAICollector.resolveEndpoint(env: ["AZURE_OPENAI_ENDPOINT": "https://x.openai.azure.com"])?.host,
            "x.openai.azure.com")
        XCTAssertNil(AzureOpenAICollector.resolveEndpoint(env: ["AZURE_OPENAI_ENDPOINT": "   "]))
        XCTAssertNil(AzureOpenAICollector.resolveEndpoint(env: [:]))
    }

    func test_resolveAPIVersion_default_and_override() {
        XCTAssertEqual(AzureOpenAICollector.resolveAPIVersion(env: [:]), "2024-10-21")
        XCTAssertEqual(
            AzureOpenAICollector.resolveAPIVersion(env: ["AZURE_OPENAI_API_VERSION": "v1"]), "v1")
    }

    // MARK: - Availability matrix (env-injected seam)

    func test_isAvailable_requires_all_three() {
        let full = [
            "AZURE_OPENAI_API_KEY": "k",
            "AZURE_OPENAI_ENDPOINT": "https://x.openai.azure.com",
            "AZURE_OPENAI_DEPLOYMENT_NAME": "gpt-4o",
        ]
        let cfg = ProviderConfig(kind: .azureOpenAI)
        XCTAssertTrue(collector.isAvailable(config: cfg, env: full))

        // Missing any one ⇒ unavailable.
        XCTAssertFalse(collector.isAvailable(config: cfg, env: full.filter { $0.key != "AZURE_OPENAI_API_KEY" }))
        XCTAssertFalse(collector.isAvailable(config: cfg, env: full.filter { $0.key != "AZURE_OPENAI_ENDPOINT" }))
        XCTAssertFalse(collector.isAvailable(config: cfg, env: full.filter { $0.key != "AZURE_OPENAI_DEPLOYMENT_NAME" }))
        XCTAssertFalse(collector.isAvailable(config: cfg, env: [:]))
    }

    func test_isAvailable_apiKey_can_come_from_config() {
        let envNoKey = [
            "AZURE_OPENAI_ENDPOINT": "https://x.openai.azure.com",
            "AZURE_OPENAI_DEPLOYMENT_NAME": "gpt-4o",
        ]
        let cfg = ProviderConfig(kind: .azureOpenAI, apiKey: "config-key")
        XCTAssertTrue(collector.isAvailable(config: cfg, env: envNoKey))
        // No config key + no env key ⇒ unavailable even with endpoint+deployment.
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .azureOpenAI), env: envNoKey))
    }

    // MARK: - New ProviderKind case (per the new-ProviderKind checklist)

    func test_providerKind_azureOpenAI_case() {
        XCTAssertEqual(ProviderKind(rawValue: "Azure OpenAI"), .azureOpenAI)
        XCTAssertEqual(ProviderKind.azureOpenAI.rawValue, "Azure OpenAI")
        XCTAssertEqual(ProviderKind.azureOpenAI.iconName, "a.circle")
        XCTAssertTrue(ProviderKind.allCases.contains(.azureOpenAI))
        XCTAssertEqual(collector.kind, .azureOpenAI)
    }
}
#endif
