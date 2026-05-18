// 1:1 XCTest port of steipete/CodexBar
// Tests/CodexBarTests/GeminiStatusProbeAPITests.swift (swift-testing →
// XCTest). The 2 curl-fallback tests + their `LoaderCalls` helper are
// NOT ported — the curl fallback API was removed from the vendored probe
// (Gemini review Q1). `#if os(macOS)`: uses setenv + the macOS-only
// GeminiTestEnvironment + Process credential-extraction paths; the test
// target only runs on macOS. See GeminiStatusProbe.swift for the MIT
// attribution of the code under test.

#if os(macOS)
import Foundation
import XCTest
@testable import CLIPulseCore

final class GeminiStatusProbeAPITests: XCTestCase {
    func test_missing_credentials_throws_not_logged_in() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.notLoggedIn) {
            _ = try await probe.fetch()
        }
    }

    func test_rejects_api_key_auth_type() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeSettings(authType: "api-key")

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.unsupportedAuthType("API key")) {
            _ = try await probe.fetch()
        }
    }

    func test_rejects_vertex_auth_type() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeSettings(authType: "vertex-ai")

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.unsupportedAuthType("Vertex AI")) {
            _ = try await probe.fetch()
        }
    }

    func test_refreshes_expired_token_and_updates_stored_credentials() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"))

        let binURL = try env.writeFakeGeminiCLI()
        let previousValue = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousValue {
                setenv("GEMINI_CLI_PATH", previousValue, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                // Fail the refresh if the client_id did not come from the test stub.
                // This guards against the probe accidentally extracting OAuth creds
                // from an unrelated Gemini install on the developer's machine.
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard body.contains("client_id=test-client-id") else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 400, body: Data())
                }
                let json = GeminiAPITestHelpers.jsonData([
                    "access_token": "new-token",
                    "expires_in": 3600,
                    "id_token": GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
                ])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudresourcemanager.googleapis.com":
                let json = GeminiAPITestHelpers.jsonData(["projects": []])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    let auth = request.value(forHTTPHeaderField: "Authorization")
                    if auth != "Bearer new-token" {
                        return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                    }
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistStandardTierResponse())
                }
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                let auth = request.value(forHTTPHeaderField: "Authorization")
                if auth != "Bearer new-token" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.sampleQuotaResponse())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 2, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch()
        XCTAssertEqual(snapshot.accountPlan, "Paid")

        let updated = try env.readCredentials()
        XCTAssertEqual(updated["access_token"] as? String, "new-token")
    }

    func test_refreshes_when_stored_gemini_credentials_only_have_refresh_token() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: nil,
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let binURL = try env.writeFakeGeminiCLI()
        let previousValue = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousValue {
                setenv("GEMINI_CLI_PATH", previousValue, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard body.contains("client_id=test-client-id") else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 400, body: Data())
                }
                let json = GeminiAPITestHelpers.jsonData([
                    "access_token": "new-token",
                    "expires_in": 3600,
                    "id_token": GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
                ])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistStandardTierResponse())
                }
                let auth = request.value(forHTTPHeaderField: "Authorization")
                guard auth == "Bearer new-token" else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.sampleQuotaResponse())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 2, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch()
        XCTAssertEqual(snapshot.accountEmail, "user@example.com")

        let updated = try env.readCredentials()
        XCTAssertEqual(updated["access_token"] as? String, "new-token")
    }

    func test_refreshes_expired_token_with_nix_share_layout() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"))

        let binURL = try env.writeFakeGeminiCLI(layout: .nixShare)
        let previousValue = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousValue {
                setenv("GEMINI_CLI_PATH", previousValue, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard body.contains("client_id=test-client-id") else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 400, body: Data())
                }
                let json = GeminiAPITestHelpers.jsonData([
                    "access_token": "new-token",
                    "expires_in": 3600,
                    "id_token": GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
                ])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudresourcemanager.googleapis.com":
                let json = GeminiAPITestHelpers.jsonData(["projects": []])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    let auth = request.value(forHTTPHeaderField: "Authorization")
                    if auth != "Bearer new-token" {
                        return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                    }
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistStandardTierResponse())
                }
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                let auth = request.value(forHTTPHeaderField: "Authorization")
                if auth != "Bearer new-token" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.sampleQuotaResponse())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 2, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch()
        XCTAssertEqual(snapshot.accountPlan, "Paid")
    }

    func test_refreshes_expired_token_with_fnm_bundle_layout() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"))

        let binURL = try env.writeFakeGeminiCLI(layout: .fnmBundle)
        // Match the real fnm layout: package root is inside the same multishell
        // dir as the bin symlink target, under lib/node_modules/@google/gemini-cli.
        let multishellRoot = binURL.deletingLastPathComponent().deletingLastPathComponent()
        let packageJSONPath = multishellRoot
            .appendingPathComponent("lib")
            .appendingPathComponent("node_modules")
            .appendingPathComponent("@google")
            .appendingPathComponent("gemini-cli")
            .appendingPathComponent("package.json")
        let npmRoot = packageJSONPath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        _ = try env.writeFakeFnm(npmRoot: npmRoot, geminiPackageJSONPath: packageJSONPath.path)

        let previousPath = ProcessInfo.processInfo.environment["PATH"]
        let fakeBinDir = env.homeURL.appendingPathComponent("bin").path
        let pathValue = if let previousPath, !previousPath.isEmpty {
            "\(fakeBinDir):\(binURL.deletingLastPathComponent().path):\(previousPath)"
        } else {
            "\(fakeBinDir):\(binURL.deletingLastPathComponent().path)"
        }
        setenv("PATH", pathValue, 1)

        let previousGeminiPath = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousPath {
                setenv("PATH", previousPath, 1)
            } else {
                unsetenv("PATH")
            }

            if let previousGeminiPath {
                setenv("GEMINI_CLI_PATH", previousGeminiPath, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard body.contains("client_id=test-client-id") else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 400, body: Data())
                }
                let json = GeminiAPITestHelpers.jsonData([
                    "access_token": "new-token",
                    "expires_in": 3600,
                    "id_token": GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
                ])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudresourcemanager.googleapis.com":
                let json = GeminiAPITestHelpers.jsonData(["projects": []])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    let auth = request.value(forHTTPHeaderField: "Authorization")
                    if auth != "Bearer new-token" {
                        return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                    }
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistStandardTierResponse())
                }
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                let auth = request.value(forHTTPHeaderField: "Authorization")
                if auth != "Bearer new-token" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.sampleQuotaResponse())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 2, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch()
        XCTAssertEqual(snapshot.accountPlan, "Paid")

        let updated = try env.readCredentials()
        XCTAssertEqual(updated["access_token"] as? String, "new-token")
    }

    func test_refreshes_expired_token_with_homebrew_bundle_layout() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"))

        let binURL = try env.writeFakeGeminiCLI(layout: .homebrewBundle)
        let previousGeminiPath = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousGeminiPath {
                setenv("GEMINI_CLI_PATH", previousGeminiPath, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard body.contains("client_id=test-client-id") else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 400, body: Data())
                }
                let json = GeminiAPITestHelpers.jsonData([
                    "access_token": "new-token",
                    "expires_in": 3600,
                    "id_token": GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
                ])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token" else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                }
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistStandardTierResponse())
                }
                if url.path == "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.sampleQuotaResponse())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 2, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch()
        XCTAssertEqual(snapshot.accountPlan, "Paid")

        let updated = try env.readCredentials()
        XCTAssertEqual(updated["access_token"] as? String, "new-token")
    }

    func test_uses_code_assist_project_for_quota() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        final class ProjectCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var value: String?

            func set(_ newValue: String?) {
                self.lock.lock()
                self.value = newValue
                self.lock.unlock()
            }

            func get() -> String? {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.value
            }
        }

        let projectId = "managed-project-123"
        let seenProject = ProjectCapture()

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistResponse(
                            tierId: "free-tier",
                            projectId: projectId))
                }
                if url.path == "/v1internal:retrieveUserQuota" {
                    if let body = request.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                    {
                        seenProject.set(json["project"] as? String)
                    }
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.sampleQuotaResponse())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 500, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        _ = try await probe.fetch()
        XCTAssertEqual(seenProject.get(), projectId)
    }

    func test_fails_refresh_when_oauth_config_missing() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: nil)

        let binURL = try env.writeFakeGeminiCLI(includeOAuth: false)
        let previousValue = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousValue {
                setenv("GEMINI_CLI_PATH", previousValue, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.apiError("Could not find Gemini CLI OAuth configuration")) {
            _ = try await probe.fetch()
        }
    }

    func test_reports_api_errors() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            switch host {
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 500, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.apiError("HTTP 500")) {
            _ = try await probe.fetch()
        }
    }

    func test_reports_not_logged_in_when_access_token_missing() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.notLoggedIn) {
            _ = try await probe.fetch()
        }
    }

    func test_reports_not_logged_in_on_401() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            switch host {
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.notLoggedIn) {
            _ = try await probe.fetch()
        }
    }

    func test_reports_parse_errors_for_invalid_payload() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            switch host {
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["buckets": []]))
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        do {
            _ = try await probe.fetch()
            XCTFail("expected parse error")
        } catch {
            let cast = error as? GeminiStatusProbeError
            XCTAssertTrue(cast?.errorDescription?.contains("Could not parse Gemini usage") == true)
        }
    }

    private static func expectError(
        _ expected: GeminiStatusProbeError,
        operation: () async throws -> Void) async
    {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch {
            XCTAssertEqual(error as? GeminiStatusProbeError, expected)
        }
    }
}
#endif
