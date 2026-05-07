import Foundation
import SQLite3

/// Reads `sessionKey` cookies from Chromium-fork browsers' Cookies
/// SQLite databases on macOS. Used by `ClaudeWebSessionResolver`
/// when the OAuth path fails.
///
/// **Browser support** (priority order, mirrors Python
/// `_claude_cookie_candidates`):
///   1. Claude Desktop (`~/Library/Application Support/Claude/Cookies`)
///   2. Google Chrome (per-profile under `*/Cookies`)
///   3. Microsoft Edge (per-profile)
///   4. Brave (per-profile)
///   5. Chromium (per-profile)
///   6. Arc (per-profile under User Data)
///
/// Each browser has its own "Safe Storage" Keychain entry; the
/// reader probes the browser-specific service first then falls
/// back to "Chrome Safe Storage" (some forks share Chrome's key).
///
/// **Read-only SQLite mode** (`?mode=ro`) is critical — the browser
/// holds a write lock on Cookies while running, and a read-write
/// open would either fail or corrupt the DB.
public actor ChromiumCookieReader {

    public typealias FileExistsHook = @Sendable (URL) -> Bool

    /// One browser cookie-DB candidate to probe.
    public struct CookieDBCandidate: Sendable, Equatable {
        public let label: String                  // e.g. "chrome:Default"
        public let dbPath: URL
        public let keychainServices: [String]     // priority list

        public init(label: String, dbPath: URL, keychainServices: [String]) {
            self.label = label
            self.dbPath = dbPath
            self.keychainServices = keychainServices
        }
    }

    private let keychain: KeychainReader
    private let fileExists: FileExistsHook

    public init(
        keychain: KeychainReader,
        fileExists: @escaping FileExistsHook = { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    ) {
        self.keychain = keychain
        self.fileExists = fileExists
    }

    /// Walk all browser cookie DBs in priority order until one
    /// produces a `sessionKey` that decrypts to `sk-ant-sid…`. Returns
    /// `(sessionKey, sourceLabel)` so the caller can log which
    /// browser produced it.
    public func resolveClaudeSessionKey() async -> (key: String, source: String)? {
        for candidate in candidates() {
            if let key = await tryReadSessionKey(from: candidate) {
                return (key, candidate.label)
            }
        }
        return nil
    }

    /// Try one DB. Reads the encrypted blob, asks `KeychainReader`
    /// for the Safe Storage password, decrypts, validates that the
    /// plaintext starts with `sk-ant-sid` (Anthropic's session-key
    /// prefix). Returns `nil` on any failure (parity with Python's
    /// "log debug, fall through" semantics).
    func tryReadSessionKey(from candidate: CookieDBCandidate) async -> String? {
        guard fileExists(candidate.dbPath) else { return nil }
        let encryptedRows: [Data]
        do {
            encryptedRows = try Self.readSessionKeyBlobs(from: candidate.dbPath)
        } catch {
            return nil
        }
        if encryptedRows.isEmpty { return nil }

        // Try each Keychain service in priority order; take the first
        // password that successfully decrypts a row to a valid prefix.
        for service in candidate.keychainServices {
            let result = await keychain.find(generic: service)
            guard case .success(let password) = result else { continue }
            for blob in encryptedRows {
                if let plaintext = try? ChromiumCookieDecrypter.decrypt(
                    encryptedValue: blob, password: password
                ), plaintext.hasPrefix("sk-ant-sid") {
                    return plaintext
                }
            }
        }
        return nil
    }

    // MARK: - Candidate enumeration

    /// All DB paths to probe. Files are added only if they exist on
    /// disk (matches Python's `add()` filter so we don't waste time
    /// SQLite-opening missing files).
    func candidates() -> [CookieDBCandidate] {
        var results: [CookieDBCandidate] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        func addIfExists(label: String, dbPath: URL, services: [String]) {
            if fileExists(dbPath) {
                results.append(CookieDBCandidate(
                    label: label, dbPath: dbPath, keychainServices: services
                ))
            }
        }

        // 1. Claude Desktop (single profile).
        addIfExists(
            label: "claude-desktop",
            dbPath: home.appendingPathComponent("Library/Application Support/Claude/Cookies"),
            services: ["Claude Safe Storage", "Chrome Safe Storage"]
        )

        // 2-6. Multi-profile browsers.
        for (browserName, dirSegment, services) in [
            ("chrome", "Library/Application Support/Google/Chrome",
             ["Chrome Safe Storage"]),
            ("edge", "Library/Application Support/Microsoft Edge",
             ["Microsoft Edge Safe Storage", "Chrome Safe Storage"]),
            ("brave", "Library/Application Support/BraveSoftware/Brave-Browser",
             ["Brave Safe Storage", "Chrome Safe Storage"]),
            ("chromium", "Library/Application Support/Chromium",
             ["Chromium Safe Storage", "Chrome Safe Storage"]),
            ("arc", "Library/Application Support/Arc/User Data",
             ["Arc Safe Storage", "Chrome Safe Storage"]),
        ] {
            let baseDir = home.appendingPathComponent(dirSegment)
            for profile in profileDirs(under: baseDir) {
                let cookiesPath = profile.appendingPathComponent("Cookies")
                addIfExists(
                    label: "\(browserName):\(profile.lastPathComponent)",
                    dbPath: cookiesPath,
                    services: services
                )
            }
        }

        return results
    }

    /// List profile sub-directories under a browser's base dir.
    /// Sorted for deterministic order across runs.
    private func profileDirs(under baseDir: URL) -> [URL] {
        guard fileExists(baseDir) else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let dirs = contents.compactMap { url -> URL? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir ? url : nil
        }
        return dirs.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - SQLite

    /// Open the Cookies DB read-only (so we don't fight the running
    /// browser's write lock) and return all encrypted_value blobs
    /// for `name = 'sessionKey' AND host_key LIKE '%claude.ai%'`.
    /// Sorted by host_key descending (matches Python query).
    static func readSessionKeyBlobs(from dbPath: URL) throws -> [Data] {
        var db: OpaquePointer? = nil
        // `?mode=ro` opens read-only via the URI form — required so
        // we don't lock against a running browser writing the DB.
        let uri = "file:\(dbPath.path)?mode=ro"
        let openStatus = sqlite3_open_v2(
            uri,
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        )
        defer { if let db = db { sqlite3_close(db) } }
        guard openStatus == SQLITE_OK else {
            throw NSError(domain: "ChromiumCookieReader", code: Int(openStatus),
                          userInfo: [NSLocalizedDescriptionKey: "sqlite3_open failed"])
        }

        let sql = """
        SELECT encrypted_value FROM cookies
        WHERE name = 'sessionKey' AND host_key LIKE '%claude.ai%'
        ORDER BY host_key DESC
        """
        var stmt: OpaquePointer? = nil
        let prepStatus = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { if let stmt = stmt { sqlite3_finalize(stmt) } }
        guard prepStatus == SQLITE_OK else {
            throw NSError(domain: "ChromiumCookieReader", code: Int(prepStatus),
                          userInfo: [NSLocalizedDescriptionKey: "sqlite3_prepare failed"])
        }

        var rows: [Data] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let byteCount = sqlite3_column_bytes(stmt, 0)
            guard byteCount > 0,
                  let blobPtr = sqlite3_column_blob(stmt, 0) else { continue }
            let blob = Data(bytes: blobPtr, count: Int(byteCount))
            rows.append(blob)
        }
        return rows
    }
}
