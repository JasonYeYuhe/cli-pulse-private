import XCTest
@testable import HelperKit

/// Swift port of `helper/test_local_auth_token.py`. Pins the same
/// invariants:
///
///   - rotateToken writes a fresh token + sets mode 0600
///   - loadToken returns nil on missing file (NOT throw)
///   - compare is constant-time + rejects mismatched lengths +
///     empty inputs
final class AuthTokenTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuthTokenTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    func testRotateTokenWritesFreshToken() throws {
        let path = tmp.appendingPathComponent("token")
        let t1 = try AuthToken.rotateToken(at: path)
        XCTAssertGreaterThan(t1.count, 0)
        // base64 of 32 raw bytes = 44 chars (with padding)
        XCTAssertEqual(t1.count, 44)
        // File contains the encoded token verbatim.
        let read = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(read, t1)
    }

    func testRotateTokenChangesEachTime() throws {
        let path = tmp.appendingPathComponent("token")
        let t1 = try AuthToken.rotateToken(at: path)
        let t2 = try AuthToken.rotateToken(at: path)
        XCTAssertNotEqual(t1, t2, "every rotation must produce a new token")
    }

    func testRotateTokenSetsMode0600() throws {
        let path = tmp.appendingPathComponent("token")
        _ = try AuthToken.rotateToken(at: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        guard let mode = attrs[.posixPermissions] as? NSNumber else {
            XCTFail("posixPermissions missing"); return
        }
        XCTAssertEqual(mode.intValue & 0o777, 0o600,
                       "token file must be owner-read/write only")
    }

    func testLoadTokenReturnsNilOnMissingFile() {
        let path = tmp.appendingPathComponent("does-not-exist")
        XCTAssertNil(AuthToken.loadToken(at: path))
    }

    func testLoadTokenStrippedOfWhitespace() throws {
        let path = tmp.appendingPathComponent("token")
        try "  abc  \n".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(AuthToken.loadToken(at: path), "abc")
    }

    func testCompareMatchesEqualBytes() {
        XCTAssertTrue(AuthToken.compare(expected: "ABCD", supplied: "ABCD"))
    }

    func testCompareRejectsMismatch() {
        XCTAssertFalse(AuthToken.compare(expected: "ABCD", supplied: "ABCE"))
    }

    func testCompareRejectsLengthMismatch() {
        XCTAssertFalse(AuthToken.compare(expected: "ABCD", supplied: "ABC"))
        XCTAssertFalse(AuthToken.compare(expected: "ABC", supplied: "ABCD"))
    }

    func testCompareRejectsEmptyInputs() {
        XCTAssertFalse(AuthToken.compare(expected: "", supplied: ""))
        XCTAssertFalse(AuthToken.compare(expected: "a", supplied: ""))
        XCTAssertFalse(AuthToken.compare(expected: "", supplied: "a"))
    }

    func testRotateTokenAndCompareRoundTrip() throws {
        let path = tmp.appendingPathComponent("token")
        let t = try AuthToken.rotateToken(at: path)
        guard let loaded = AuthToken.loadToken(at: path) else {
            XCTFail("loadToken returned nil immediately after rotateToken"); return
        }
        XCTAssertTrue(AuthToken.compare(expected: t, supplied: loaded))
    }
}
