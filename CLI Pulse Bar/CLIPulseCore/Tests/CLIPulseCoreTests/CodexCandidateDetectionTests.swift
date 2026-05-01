#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// iter22 regression suite: pin the "Codex is running but Sessions
/// tab is empty" diagnosis. Each test injects a real-on-disk JSONL
/// at the Codex CLI's actual layout (`<root>/YYYY/MM/DD/rollout-*.jsonl`)
/// and asserts the scanner emits a candidate that survives
/// `SessionFreshnessFilter`.
final class CodexCandidateDetectionTests: XCTestCase {

    private var tempDir: URL!
    private var codexRoot: URL!
    private var cacheRoot: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCandidateDetectionTests-\(UUID().uuidString)", isDirectory: true)
        codexRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        cacheRoot = tempDir.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Date-partitioned layout

    private func writeRolloutFile(at date: Date, sessionId: String, cwd: String?) throws -> URL {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let y = String(format: "%04d", comps.year ?? 1970)
        let m = String(format: "%02d", comps.month ?? 1)
        let d = String(format: "%02d", comps.day ?? 1)
        let dir = codexRoot
            .appendingPathComponent(y).appendingPathComponent(m).appendingPathComponent(d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-\(sessionId).jsonl")

        var payload: [String: Any] = ["id": sessionId]
        if let cwd { payload["cwd"] = cwd }
        let metaLine: [String: Any] = [
            "timestamp": "2026-05-01T03:44:40.669Z",
            "type": "session_meta",
            "payload": payload,
        ]
        let lineData = try JSONSerialization.data(withJSONObject: metaLine)
        var contents = Data()
        contents.append(lineData)
        contents.append(0x0A) // newline
        try contents.write(to: url)

        // Set mtime to `date` so the freshness filter can see it.
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path
        )
        return url
    }

    private func makeOptions() -> CostUsageScanner.Options {
        var opts = CostUsageScanner.Options(
            codexSessionsRoot: codexRoot,
            claudeProjectsRoots: [],
            cacheRoot: cacheRoot,
            daysToScan: 7
        )
        opts.refreshMinIntervalSeconds = 0  // always rescan
        return opts
    }

    func test_freshCodexJsonl_withoutCacheEntry_yieldsCandidate() throws {
        let now = Date()
        // 1 minute old — well within the 5-minute freshness window.
        let mtime = now.addingTimeInterval(-60)
        _ = try writeRolloutFile(at: mtime, sessionId: "abcd-test-1", cwd: "/Users/jason/cli-pulse")

        let result = CostUsageScanner.scan(options: makeOptions())

        let codexCandidates = result.activeSessionCandidates.filter { $0.provider == "Codex" }
        XCTAssertEqual(codexCandidates.count, 1, "Fresh Codex JSONL without cache entry must still emit a candidate")

        let cand = try XCTUnwrap(codexCandidates.first)
        XCTAssertEqual(cand.sessionId, "abcd-test-1", "Candidate must read sessionId from the on-disk session_meta line")
        XCTAssertEqual(cand.projectName, "cli-pulse", "Candidate projectName must come from cwd's last path component")
        XCTAssertEqual(cand.projectRoot, "/Users/jason/cli-pulse")
    }

    func test_staleCodexJsonl_isIgnored() throws {
        let now = Date()
        // 6 minutes old — past the 300s window.
        let mtime = now.addingTimeInterval(-60 * 6)
        _ = try writeRolloutFile(at: mtime, sessionId: "stale-test", cwd: "/Users/jason/cli-pulse")

        let result = CostUsageScanner.scan(options: makeOptions())
        let codexCandidates = result.activeSessionCandidates.filter { $0.provider == "Codex" }
        XCTAssertTrue(codexCandidates.isEmpty, "Stale Codex JSONL must NOT yield a candidate")
    }

    func test_freshCodexJsonl_synthesizesSessionThatSurvivesFreshnessFilter() throws {
        let now = Date()
        let mtime = now.addingTimeInterval(-30)
        _ = try writeRolloutFile(at: mtime, sessionId: "synth-test-1", cwd: "/Users/jason/cli-pulse")

        let result = CostUsageScanner.scan(options: makeOptions())
        let synthesized = CostUsageScanner.synthesizeSessions(
            candidates: result.activeSessionCandidates,
            now: now,
            deviceName: "test-host"
        )
        let filtered = SessionFreshnessFilter.filterCurrent(synthesized, now: now)

        let codex = filtered.filter { $0.provider == "Codex" }
        XCTAssertEqual(codex.count, 1, "Synthesized Codex session must survive SessionFreshnessFilter")
        let session = try XCTUnwrap(codex.first)
        XCTAssertEqual(session.project, "cli-pulse")
        XCTAssertEqual(session.status, "Running")
    }

    func test_codexJsonl_missingSessionMeta_stillYieldsCandidateWithFallbackProject() throws {
        // A JSONL whose first line isn't session_meta — we still want
        // a candidate (file is fresh = strong signal Codex was active),
        // just falling back to the "Codex" placeholder project label.
        let now = Date()
        let mtime = now.addingTimeInterval(-30)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: mtime)
        let y = String(format: "%04d", comps.year ?? 1970)
        let m = String(format: "%02d", comps.month ?? 1)
        let d = String(format: "%02d", comps.day ?? 1)
        let dir = codexRoot.appendingPathComponent(y).appendingPathComponent(m).appendingPathComponent(d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-no-meta.jsonl")
        // Just a non-meta line.
        let payload: [String: Any] = ["timestamp": "2026-05-01T03:50:00.000Z", "type": "event_msg"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var contents = data
        contents.append(0x0A)
        try contents.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)

        let result = CostUsageScanner.scan(options: makeOptions())
        let codexCandidates = result.activeSessionCandidates.filter { $0.provider == "Codex" }
        XCTAssertEqual(codexCandidates.count, 1)
        XCTAssertEqual(codexCandidates.first?.projectName, "Codex", "Without session_meta, fall back to placeholder")
    }

    // MARK: - projectLabelFromCodexMeta

    func test_projectLabelFromCodexMeta_extractsLastPathComponent() {
        XCTAssertEqual(CostUsageScanner.projectLabelFromCodexMeta("/Users/jason/cli-pulse"), "cli-pulse")
        XCTAssertEqual(CostUsageScanner.projectLabelFromCodexMeta("/Users/jason/cli-pulse/"), "cli-pulse")
        XCTAssertEqual(CostUsageScanner.projectLabelFromCodexMeta("/home/dev/myapp"), "myapp")
    }

    func test_projectLabelFromCodexMeta_rejectsBareHomeRoots() {
        XCTAssertNil(CostUsageScanner.projectLabelFromCodexMeta("/Users"))
        XCTAssertNil(CostUsageScanner.projectLabelFromCodexMeta("/home"))
        XCTAssertNil(CostUsageScanner.projectLabelFromCodexMeta(""))
        XCTAssertNil(CostUsageScanner.projectLabelFromCodexMeta(nil))
        XCTAssertNil(CostUsageScanner.projectLabelFromCodexMeta("/"))
    }

    // MARK: - readCodexSessionMeta

    func test_readCodexSessionMeta_parsesPayloadIdAndCwd() throws {
        let url = tempDir.appendingPathComponent("only-meta.jsonl")
        let line: [String: Any] = [
            "type": "session_meta",
            "payload": ["id": "session-xyz", "cwd": "/tmp/work"],
        ]
        var contents = try JSONSerialization.data(withJSONObject: line)
        contents.append(0x0A)
        try contents.write(to: url)

        let meta = try XCTUnwrap(CostUsageScanner.readCodexSessionMeta(fileURL: url))
        XCTAssertEqual(meta.sessionId, "session-xyz")
        XCTAssertEqual(meta.cwd, "/tmp/work")
    }

    func test_readCodexSessionMeta_returnsNilForFileWithoutMetaLine() throws {
        let url = tempDir.appendingPathComponent("no-meta.jsonl")
        let line: [String: Any] = ["type": "event_msg", "payload": [:]]
        var contents = try JSONSerialization.data(withJSONObject: line)
        contents.append(0x0A)
        try contents.write(to: url)

        XCTAssertNil(CostUsageScanner.readCodexSessionMeta(fileURL: url))
    }
}
#endif
