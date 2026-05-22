// Unit tests for the v1.23.0 Phase C-23 GrokCollector (CodexBar parity — the
// 48th/final provider; gRPC-web + heuristic protobuf, unverifiable without a
// live grok.com session). These lock the PORTED logic: gRPC-web framing, the
// schema-agnostic protobuf scan + usedPercent/reset heuristic (incl. the
// Gemini-adopted millis-timestamp path), grpc-status validation, and the
// `.quota` / `.statusOnly` mapping. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class GrokCollectorTests: XCTestCase {
    private let collector = GrokCollector()

    // MARK: - protobuf fixture builders (use the shared `Proto` writer)

    private func fixed32Bytes(_ f: Float) -> [UInt8] {
        let bp = f.bitPattern
        return [UInt8(bp & 0xFF), UInt8((bp >> 8) & 0xFF), UInt8((bp >> 16) & 0xFF), UInt8((bp >> 24) & 0xFF)]
    }

    /// Wraps `payload` in a single gRPC-web frame (1 flag byte + 4-byte BE length).
    private func grpcWebFrame(_ payload: Data, flag: UInt8 = 0x00) -> Data {
        var d = Data([flag])
        let len = UInt32(payload.count)
        d.append(UInt8((len >> 24) & 0xFF))
        d.append(UInt8((len >> 16) & 0xFF))
        d.append(UInt8((len >> 8) & 0xFF))
        d.append(UInt8(len & 0xFF))
        d.append(payload)
        return d
    }

    /// Builds a protobuf message: reset at path [1,5,1] (varint), used-percent
    /// fixed32 at path [2,1].
    private func buildPayload(percent: Float?, resetTS: UInt64?) -> Data {
        var top = Data()
        if let ts = resetTS {
            var tsMsg = Data()                                  // {1: ts}
            Proto.appendKey(1, .varint, &tsMsg); Proto.appendVarint(ts, &tsMsg)
            var f5 = Data()                                     // {5: {1: ts}}
            Proto.appendKey(5, .lengthDelimited, &f5)
            Proto.appendVarint(UInt64(tsMsg.count), &f5); f5.append(tsMsg)
            Proto.appendKey(1, .lengthDelimited, &top)          // {1: {5: {1: ts}}}
            Proto.appendVarint(UInt64(f5.count), &top); top.append(f5)
        }
        if let p = percent {
            var inner = Data()                                  // {1: <fixed32 p>}
            Proto.appendKey(1, .fixed32, &inner); inner.append(contentsOf: fixed32Bytes(p))
            Proto.appendKey(2, .lengthDelimited, &top)          // {2: {1: <fixed32 p>}}
            Proto.appendVarint(UInt64(inner.count), &top); top.append(inner)
        }
        return top
    }

    // MARK: - gRPC-web framing

    func test_grpcWebDataFrames_excludesTrailer() {
        let dataPayload = Data([0x01, 0x02, 0x03])
        let trailerPayload = Data("grpc-status:0\r\n".utf8)
        var combined = grpcWebFrame(dataPayload, flag: 0x00)
        combined.append(grpcWebFrame(trailerPayload, flag: 0x80))   // trailer bit set
        let frames = GrokCollector.grpcWebDataFrames(from: combined)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first, dataPayload)
    }

    // MARK: - scan + heuristic

    func test_parseGRPCWebResponse_percentAndReset() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snap = try GrokCollector.parseGRPCWebResponse(
            grpcWebFrame(buildPayload(percent: 42.0, resetTS: 1_900_000_000)), now: now)
        XCTAssertEqual(snap.usedPercent ?? -1, 42.0, accuracy: 0.01)
        XCTAssertNotNil(snap.resetsAt)
        XCTAssertEqual(snap.resetsAt!.timeIntervalSince1970, 1_900_000_000, accuracy: 1)
    }

    func test_parseGRPCWebResponse_millisReset() throws {
        // Gemini C-23 LOW: a reset varint in MILLIS must be divided to seconds.
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snap = try GrokCollector.parseGRPCWebResponse(
            grpcWebFrame(buildPayload(percent: 10.0, resetTS: 1_900_000_000_000)), now: now)
        XCTAssertEqual(snap.resetsAt!.timeIntervalSince1970, 1_900_000_000, accuracy: 1)
    }

    func test_parseGRPCWebResponse_noUsageYet_zeroPercent() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        // reset at [1,5,1] + a [1,6,1] varint, NO fixed32 ⇒ percent 0.
        var top = buildPayload(percent: nil, resetTS: 1_900_000_000)
        var f6 = Data()
        Proto.appendKey(1, .varint, &f6); Proto.appendVarint(7, &f6)        // {1: 7}
        var inner6 = Data()
        Proto.appendKey(6, .lengthDelimited, &inner6)
        Proto.appendVarint(UInt64(f6.count), &inner6); inner6.append(f6)    // {6: {1: 7}}
        Proto.appendKey(1, .lengthDelimited, &top)                          // {1: {6: {1: 7}}}
        Proto.appendVarint(UInt64(inner6.count), &top); top.append(inner6)
        let snap = try GrokCollector.parseGRPCWebResponse(grpcWebFrame(top), now: now)
        XCTAssertEqual(snap.usedPercent ?? -1, 0, accuracy: 0.001)
    }

    func test_parseGRPCWebResponse_emptyPayload_throws() {
        XCTAssertThrowsError(try GrokCollector.parseGRPCWebResponse(Data())) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    // MARK: - grpc-status

    func test_validateGRPCStatusFields() {
        XCTAssertThrowsError(try GrokCollector.validateGRPCStatusFields(["grpc-status": "16"])) {
            guard case CollectorError.missingCredentials = $0 else { return XCTFail("expected missingCredentials") }
        }
        XCTAssertThrowsError(try GrokCollector.validateGRPCStatusFields(["grpc-status": "5"])) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
        XCTAssertNoThrow(try GrokCollector.validateGRPCStatusFields(["grpc-status": "0"]))
        XCTAssertNoThrow(try GrokCollector.validateGRPCStatusFields([:]))
    }

    // MARK: - buildResult

    func test_buildResult_quotaAndStatusOnly() {
        let q = GrokCollector.buildResult(
            .init(usedPercent: 42, resetsAt: Date(timeIntervalSince1970: 1_900_000_000)))
        XCTAssertEqual(q.dataKind, .quota)
        XCTAssertEqual(q.usage.quota, 100)
        XCTAssertEqual(q.usage.remaining, 58)               // 100 − 42 used
        XCTAssertEqual(q.usage.tiers.count, 1)
        XCTAssertEqual(q.usage.status_text, "58% left")
        XCTAssertNotNil(q.usage.reset_time)

        let s = GrokCollector.buildResult(.init(usedPercent: nil, resetsAt: nil))
        XCTAssertEqual(s.dataKind, .statusOnly)
        XCTAssertEqual(s.usage.status_text, "Connected")
        XCTAssertNil(s.usage.quota)
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .grok)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .grok, manualCookieHeader: "sso=x")))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .grok, cookieSource: .automatic)))
    }
}
#endif
