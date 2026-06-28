#if os(macOS)
import XCTest
import SQLite3
@testable import CLIPulseCore

/// Tests `GeckoCookieImporter.loadCookies` (Firefox `moz_cookies`) — a 0-test
/// auth path that reads browser cookies driving provider sign-in. Uses a REAL
/// on-disk SQLite fixture (SQLite writes the file format, so the test exercises
/// the actual reader, not a hand-built blob) and asserts concrete parsed values,
/// so a passing test can't be vacuous.
final class GeckoCookieImporterTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gecko-cookie-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("cookies.sqlite")
        try makeMozCookiesDB(at: dbURL)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    /// Two rows: a persistent secure+httpOnly cookie on `.anthropic.com`
    /// (leading dot, future expiry), and a plain session cookie on `example.com`
    /// (expiry 0 → session).
    private func makeMozCookiesDB(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db); throw XCTSkip("sqlite open failed")
        }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE moz_cookies (
            id INTEGER PRIMARY KEY, host TEXT, name TEXT, path TEXT, value TEXT,
            expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER
        );
        INSERT INTO moz_cookies (host,name,path,value,expiry,isSecure,isHttpOnly)
            VALUES ('.anthropic.com','sessionKey','/','sk-secret-abc',4070908800,1,1);
        INSERT INTO moz_cookies (host,name,path,value,expiry,isSecure,isHttpOnly)
            VALUES ('example.com','plain','/x','v2',0,0,0);
        """
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
            let m = errmsg.map { String(cString: $0) } ?? "?"
            sqlite3_free(errmsg)
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "sqlite exec: \(m)"])
        }
    }

    private func store() -> BrowserCookieStore {
        BrowserCookieStore(
            browser: .firefox,
            profile: BrowserProfile(id: "test", name: "default-release"),
            kind: .primary,
            label: "Firefox test",
            databaseURL: dbURL)
    }

    private func load(_ domains: [String], _ match: BrowserCookieDomainMatch) throws
        -> [GeckoCookieImporter.CookieRecord]
    {
        try GeckoCookieImporter.loadCookies(from: store(), matchingDomains: domains, domainMatch: match)
    }

    func test_loads_matching_cookie_with_all_fields() throws {
        let rows = try load(["anthropic.com"], .contains)
        XCTAssertEqual(rows.count, 1, "domain filter should return exactly the anthropic cookie")
        let c = try XCTUnwrap(rows.first)
        XCTAssertEqual(c.host, "anthropic.com", "leading dot must be stripped by normalizeDomain")
        XCTAssertEqual(c.name, "sessionKey")
        XCTAssertEqual(c.path, "/")
        XCTAssertEqual(c.value, "sk-secret-abc")
        XCTAssertTrue(c.isSecure)
        XCTAssertTrue(c.isHTTPOnly)
        XCTAssertNotNil(c.expires, "expiry 4070908800 must decode to a Date")
        XCTAssertEqual(c.expires, Date(timeIntervalSince1970: 4_070_908_800))
    }

    func test_empty_domains_returns_all_rows() throws {
        // sqlCondition([]) → "1=1" → every row.
        XCTAssertEqual(try load([], .contains).count, 2)
    }

    func test_session_cookie_zero_expiry_decodes_to_nil() throws {
        let rows = try load(["example.com"], .contains)
        let c = try XCTUnwrap(rows.first)
        XCTAssertNil(c.expires, "expiry 0 is a session cookie → nil")
        XCTAssertFalse(c.isSecure)
        XCTAssertFalse(c.isHTTPOnly)
        XCTAssertEqual(c.value, "v2")
    }

    func test_exact_match_also_matches_dotted_host() throws {
        // exact builds `(host = 'anthropic.com' OR host = '.anthropic.com')`,
        // so the stored ".anthropic.com" row is found.
        XCTAssertEqual(try load(["anthropic.com"], .exact).count, 1)
    }

    func test_nonmatching_domain_returns_empty() throws {
        // Genuinely no match — safe to assert empty because the tests above
        // prove the reader DOES return rows when they match.
        XCTAssertTrue(try load(["nonexistent.invalid"], .exact).isEmpty)
    }
}
#endif
