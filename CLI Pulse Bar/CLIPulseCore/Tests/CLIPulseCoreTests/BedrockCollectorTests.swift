// Unit tests for the v1.23.0 Phase C-19 BedrockCollector (CodexBar parity —
// AWS Cost Explorer). Locks: SigV4 primitives (known SHA256 vectors +
// deterministic signed header), Bedrock-service cost aggregation, env-cred
// resolution, and the `.statusOnly` spend mapping. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class BedrockCollectorTests: XCTestCase {

    // MARK: - SigV4 primitives

    func test_sha256Hex_known_vectors() {
        XCTAssertEqual(BedrockCollector.AWSSigner.sha256Hex(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(BedrockCollector.AWSSigner.sha256Hex(Data("hello".utf8)),
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func test_signatureHex_is_deterministic_64hex() {
        let sig = BedrockCollector.AWSSigner.signatureHex(
            secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            dateStamp: "20150830", region: "us-east-1", service: "ce",
            stringToSign: "test-string")
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(sig.allSatisfy { $0.isHexDigit })
        // determinism
        XCTAssertEqual(sig, BedrockCollector.AWSSigner.signatureHex(
            secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            dateStamp: "20150830", region: "us-east-1", service: "ce",
            stringToSign: "test-string"))
    }

    func test_sign_produces_wellformed_authorization() {
        let creds = BedrockCollector.Creds(
            accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: nil, region: "us-east-1")
        var req = URLRequest(url: URL(string: "https://ce.us-east-1.amazonaws.com")!)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        let fixedDate = Date(timeIntervalSince1970: 1_440_938_160)   // 2015-08-30T12:36:00Z
        BedrockCollector.AWSSigner.sign(request: &req, creds: creds, region: "us-east-1", service: "ce", date: fixedDate)
        let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/ce/aws4_request"), auth)
        XCTAssertTrue(auth.contains("SignedHeaders="), auth)
        XCTAssertTrue(auth.contains("Signature="), auth)
        XCTAssertNotNil(req.value(forHTTPHeaderField: "X-Amz-Date"))
        XCTAssertNotNil(req.value(forHTTPHeaderField: "x-amz-content-sha256"))
    }

    // MARK: - parseTotalCost (filter Bedrock service)

    func test_parseTotalCost_sums_bedrock_only() throws {
        let total = try BedrockCollector.parseTotalCost(Data(#"""
        {"ResultsByTime":[{"Groups":[
          {"Keys":["Amazon Bedrock"],"Metrics":{"UnblendedCost":{"Amount":"12.34"}}},
          {"Keys":["Amazon Simple Storage Service"],"Metrics":{"UnblendedCost":{"Amount":"5.00"}}}
        ]}]}
        """#.utf8))
        XCTAssertEqual(total, 12.34, accuracy: 0.001)   // S3 excluded
    }

    func test_parseTotalCost_sums_across_results() throws {
        let total = try BedrockCollector.parseTotalCost(Data(#"""
        {"ResultsByTime":[
          {"Groups":[{"Keys":["Amazon Bedrock"],"Metrics":{"UnblendedCost":{"Amount":"1.50"}}}]},
          {"Groups":[{"Keys":["Bedrock"],"Metrics":{"UnblendedCost":{"Amount":"2.50"}}}]}
        ]}
        """#.utf8))
        XCTAssertEqual(total, 4.0, accuracy: 0.001)
    }

    func test_parseTotalCost_missing_results_throws() {
        XCTAssertThrowsError(try BedrockCollector.parseTotalCost(Data("{}".utf8))) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    func test_nextPageToken() {
        XCTAssertEqual(BedrockCollector.nextPageToken(from: Data(#"{"NextPageToken":"abc"}"#.utf8)), "abc")
        XCTAssertNil(BedrockCollector.nextPageToken(from: Data(#"{"ResultsByTime":[]}"#.utf8)))
    }

    // MARK: - creds (env-only)

    func test_creds_from_env() {
        let c = BedrockCollector.creds(env: [
            "AWS_ACCESS_KEY_ID": "AKID", "AWS_SECRET_ACCESS_KEY": "sec", "AWS_REGION": "eu-west-1",
        ])
        XCTAssertEqual(c?.accessKeyID, "AKID")
        XCTAssertEqual(c?.region, "eu-west-1")
        XCTAssertNil(BedrockCollector.creds(env: ["AWS_ACCESS_KEY_ID": "AKID"]))   // no secret
        // region default
        XCTAssertEqual(BedrockCollector.creds(env: [
            "AWS_ACCESS_KEY_ID": "A", "AWS_SECRET_ACCESS_KEY": "S"])?.region, "us-east-1")
    }

    // MARK: - buildResult

    func test_buildResult_statusOnly_spend() {
        let result = BedrockCollector.buildResult(spend: 12.34, region: "us-east-1", budget: nil)
        XCTAssertEqual(result.dataKind, .statusOnly)
        let u = result.usage
        XCTAssertNil(u.quota)
        XCTAssertEqual(u.estimated_cost_week, 12.34, accuracy: 0.001)
        XCTAssertEqual(u.cost_status_week, "Exact")
        XCTAssertEqual(u.plan_type, "us-east-1")
        XCTAssertEqual(u.status_text, "$12.34 this month")
    }

    func test_buildResult_with_budget() {
        let u = BedrockCollector.buildResult(spend: 25, region: "us-east-1", budget: 100).usage
        XCTAssertTrue(u.status_text.contains("$25.00 this month"), u.status_text)
        XCTAssertTrue(u.status_text.contains("25% of $100"), u.status_text)
    }
}
#endif
