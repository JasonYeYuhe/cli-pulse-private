import XCTest
@testable import CLIPulseCore

final class PushTokenSyncTests: XCTestCase {

    func testFormatTokenZeroPaddedHex() {
        // APNs tokens are 32-byte Data on iOS; ensure single-byte values
        // serialise as `0x` two-char hex (i.e. 0x07 → "07", not "7").
        let data = Data([0x00, 0x07, 0xab, 0xff])
        let hex = PushTokenSync.formatToken(data)
        XCTAssertEqual(hex, "0007abff")
    }

    func testFormatTokenIsLowercase() {
        let data = Data([0xAB, 0xCD, 0xEF])
        XCTAssertEqual(PushTokenSync.formatToken(data), "abcdef")
    }

    func testFormatTokenEmptyData() {
        XCTAssertEqual(PushTokenSync.formatToken(Data()), "")
    }

    func testIsValidTokenLength_realisticAPNsLength() {
        // Real APNs tokens are 32 bytes → 64 hex chars.
        let realistic = String(repeating: "a", count: 64)
        XCTAssertTrue(PushTokenSync.isValidTokenLength(realistic))
    }

    func testIsValidTokenLength_rejectsTooShort() {
        XCTAssertFalse(PushTokenSync.isValidTokenLength(""))
        XCTAssertFalse(PushTokenSync.isValidTokenLength("short"))
        XCTAssertFalse(PushTokenSync.isValidTokenLength("1234567"))   // 7 chars
    }

    func testIsValidTokenLength_rejectsTooLong() {
        let tooLong = String(repeating: "a", count: 257)
        XCTAssertFalse(PushTokenSync.isValidTokenLength(tooLong))
    }

    func testPlatformIdentifierUIKitDefault() {
        XCTAssertEqual(PushTokenSync.platformIdentifier(), "ios")
        XCTAssertEqual(PushTokenSync.platformIdentifier(forUIKit: true), "ios")
        XCTAssertEqual(PushTokenSync.platformIdentifier(forUIKit: false), "macos")
    }

    func testIsValidBundleId() {
        XCTAssertTrue(PushTokenSync.isValidBundleId("yyh.CLI-Pulse-iOS"))
        XCTAssertTrue(PushTokenSync.isValidBundleId("a"))
        XCTAssertFalse(PushTokenSync.isValidBundleId(nil))
        XCTAssertFalse(PushTokenSync.isValidBundleId(""))
        XCTAssertFalse(PushTokenSync.isValidBundleId(String(repeating: "x", count: 129)))
    }

    // ── Permission-request decode contract: device_name optional ──

    func testRemotePermissionRequestDecodesWithoutDeviceName() throws {
        // Pre-v0.32 server response shape.
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "session_id": null,
          "device_id": "22222222-2222-2222-2222-222222222222",
          "provider": "claude",
          "tool_name": "Bash",
          "summary": "$ ls",
          "risk": "low",
          "status": "pending",
          "created_at": "2026-04-29T10:00:00Z",
          "expires_at": "2026-04-29T10:05:00Z"
        }
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(RemotePermissionRequest.self, from: json)
        XCTAssertNil(req.device_name)
        XCTAssertEqual(req.tool_name, "Bash")
    }

    func testRemotePermissionRequestDecodesWithDeviceName() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "session_id": null,
          "device_id": "22222222-2222-2222-2222-222222222222",
          "device_name": "Jason's MacBook Pro",
          "provider": "claude",
          "tool_name": "Bash",
          "summary": "$ ls",
          "risk": "low",
          "status": "pending",
          "created_at": "2026-04-29T10:00:00Z",
          "expires_at": "2026-04-29T10:05:00Z"
        }
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(RemotePermissionRequest.self, from: json)
        XCTAssertEqual(req.device_name, "Jason's MacBook Pro")
    }
}
