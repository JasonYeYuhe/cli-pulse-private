import XCTest
@testable import HelperKit
import Foundation

/// Tests for the Phase 4E Slice 1 port of `helper/git_collector.py`.
/// Pin the wire-shape and behavioural parity with the Python reference
/// — same HMAC scheme, same per-project last-seen-hash cache, same
/// dedupe-on-collect, same graceful-degrade-on-error.
///
/// Subprocess hygiene: timeout MUST reap the child (Phase 4E plan v2.1
/// Gemini P1). Tests use `/bin/sleep` as a fake `git` to exercise the
/// timeout branch deterministically.
final class GitCollectorTests: XCTestCase {

    // MARK: - Fixtures

    private var rootTmp: URL!

    override func setUp() {
        super.setUp()
        rootTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitCollectorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: rootTmp, withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootTmp)
        super.tearDown()
    }

    /// Spin up a real git repo at a fresh temp dir with `initialCommits`
    /// commits already made. Uses local-only git config (no GPG, no
    /// global config) so the test passes on any developer machine.
    private func makeTempGitRepo(initialCommits: Int = 0) throws -> URL {
        let repo = rootTmp.appendingPathComponent("repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repo, withIntermediateDirectories: true
        )

        try runGit(["init", "-b", "main"], cwd: repo)
        try runGit(["config", "user.email", "test@cli-pulse.local"], cwd: repo)
        try runGit(["config", "user.name", "Test"], cwd: repo)
        try runGit(["config", "commit.gpgsign", "false"], cwd: repo)
        try runGit(["config", "tag.gpgsign", "false"], cwd: repo)

        for i in 0..<initialCommits {
            let f = repo.appendingPathComponent("file-\(i).txt")
            try "content \(i)".write(to: f, atomically: true, encoding: .utf8)
            try runGit(["add", "."], cwd: repo)
            try runGit(["commit", "-m", "commit \(i)"], cwd: repo)
        }

        return repo
    }

    @discardableResult
    private func runGit(_ args: [String], cwd: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd.path] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(
            data: out.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private func addCommit(repo: URL, label: String) throws {
        let f = repo.appendingPathComponent("file-\(label).txt")
        try "content \(label)".write(to: f, atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: repo)
        try runGit(["commit", "-m", "commit \(label)"], cwd: repo)
    }

    // MARK: - Happy-path scan + last-seen fence

    func testScanReturnsCommitsFromTempRepo() async throws {
        let repo = try makeTempGitRepo(initialCommits: 3)
        let collector = GitCollector(secret: Data("k".utf8))

        let result = await collector.scan(projectPath: repo)

        XCTAssertEqual(result.count, 3, "first scan should see all 3 commits")
        XCTAssertFalse(result.contains { $0.commitHash.isEmpty })
        XCTAssertFalse(result.contains { $0.committedAt.isEmpty })
        XCTAssertFalse(result.contains { $0.isMerge },
                       "non-merge commits must report isMerge=false")
        // Same project_hash for every commit in this repo.
        let hashes = Set(result.map { $0.projectHash })
        XCTAssertEqual(hashes.count, 1)
    }

    func testSecondScanReturnsZeroIfNoNewCommits() async throws {
        let repo = try makeTempGitRepo(initialCommits: 2)
        let collector = GitCollector(secret: Data("k".utf8))

        _ = await collector.scan(projectPath: repo)
        let second = await collector.scan(projectPath: repo)

        XCTAssertEqual(second.count, 0,
                       "last-seen fence must keep already-emitted commits out")
    }

    func testThirdScanReturnsOnlyNewCommitsAfterFenceAdvance() async throws {
        let repo = try makeTempGitRepo(initialCommits: 2)
        let collector = GitCollector(secret: Data("k".utf8))

        _ = await collector.scan(projectPath: repo)
        try addCommit(repo: repo, label: "new1")
        try addCommit(repo: repo, label: "new2")
        let third = await collector.scan(projectPath: repo)

        XCTAssertEqual(third.count, 2,
                       "fence-advance scan should emit exactly the 2 new commits")
    }

    func testResetCacheClearsLastSeen() async throws {
        let repo = try makeTempGitRepo(initialCommits: 3)
        let collector = GitCollector(secret: Data("k".utf8))

        _ = await collector.scan(projectPath: repo)
        await collector.resetCache()
        let afterReset = await collector.scan(projectPath: repo)

        XCTAssertEqual(afterReset.count, 3,
                       "reset must drop the last-seen mark; rescan yields all commits again")
    }

    // MARK: - Dedupe across paths

    func testCollectDedupsCommitsAcrossPaths() async throws {
        let repo = try makeTempGitRepo(initialCommits: 2)
        let collector = GitCollector(secret: Data("k".utf8))

        // Same URL twice — `collect` must dedupe by commit hash. (Two
        // worktrees of the same repo would behave identically; using
        // the same path keeps the test hermetic.)
        let result = await collector.collect(projectPaths: [repo, repo])

        XCTAssertEqual(result.count, 2,
                       "collect must dedupe shared commits across paths")
    }

    // MARK: - HMAC parity with Python reference

    func testHmacParityWithPython() {
        // Reference values generated via `helper/user_secret.py::project_hash`
        // — the Python wire contract. Drift here would silently change
        // the project_hash uploaded to Supabase, invalidating yield
        // attribution for already-onboarded users.
        struct Fixture {
            let secret: Data
            let path: String
            let expectedHex: String
        }
        let fixtures: [Fixture] = [
            Fixture(
                secret: Data([0x74, 0x65, 0x73, 0x74, 0x2d, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74]),
                path: "/Users/test/project",
                expectedHex: "29fadfe19477bab5a9377069d47f52888b5934990e8dd6bca88a8794efed3e07"
            ),
            Fixture(
                secret: Data([0x74, 0x65, 0x73, 0x74, 0x2d, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74]),
                path: "/Users/dev/cool-app",
                expectedHex: "0a561ed2112232443f2afb78dd05a1a3930551f5ea95a0af849f1dfca80ced1c"
            ),
            Fixture(
                secret: Data([0x00, 0x01, 0x02, 0x03]),
                path: "/tmp/test",
                expectedHex: "5c57a18c2477317d06d346c708e192df41a2592f89c463c89d903e9388fc2512"
            ),
            Fixture(
                secret: Data([
                    0x6c, 0x6f, 0x6e, 0x67, 0x65, 0x72, 0x2d, 0x73,
                    0x65, 0x63, 0x72, 0x65, 0x74, 0x2d, 0x76, 0x61,
                    0x6c, 0x75, 0x65, 0x2d, 0x33, 0x32, 0x2d, 0x63,
                    0x68, 0x61, 0x72, 0x73, 0x2d, 0x2d, 0x2d, 0x2d,
                ]),
                path: "/Users/jason/Documents/cli pulse",
                expectedHex: "d0667081a3e21c3b9071e8537b19d55589bd9d3c823c625c0b8fc3f570d1b223"
            ),
            Fixture(
                secret: Data([0x65, 0x6d, 0x70, 0x74, 0x79, 0x2d, 0x70, 0x61, 0x74, 0x68, 0x2d, 0x6b, 0x65, 0x79]),
                path: "",
                expectedHex: "fdffff419ab71d5e22dd986451e42ae77993c81ae316fc29dbc576d8d355a5cf"
            ),
        ]

        for fixture in fixtures {
            let actual = GitCollector.computeProjectHashHex(
                secret: fixture.secret,
                absolutePath: fixture.path
            )
            XCTAssertEqual(actual, fixture.expectedHex,
                           "HMAC drift for path \(fixture.path.debugDescription): expected \(fixture.expectedHex), got \(actual)")
        }
    }

    // MARK: - Subprocess timeout / zombie reap (Phase 4E v2 P1)

    func testSubprocessTimeoutTerminatesChildAndReturnsEmpty() async throws {
        // Fake `git` = `/bin/sleep`. Even with `--no-merges --since=…
        // --pretty=…` args, sleep ignores them and just hangs for the
        // first numeric arg (which here is `-C` — sleep won't accept
        // that, so it errors out fast). Use a fake_git.sh script that
        // sleeps so we get a real timeout exercise.
        let fakeGit = rootTmp.appendingPathComponent("fake_git.sh")
        try #"""
        #!/bin/bash
        sleep 30
        """#.write(to: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fakeGit.path
        )

        // A real git repo (so the dot-git early-out doesn't trigger).
        let repo = try makeTempGitRepo(initialCommits: 1)

        let collector = GitCollector(
            secret: Data("k".utf8),
            sinceWindow: "2 hours ago",
            subprocessTimeout: 0.3,
            gitPath: fakeGit
        )

        let started = Date()
        let result = await collector.scan(projectPath: repo)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result, [],
                       "scan must return [] when git times out (matches Python contract)")
        XCTAssertLessThan(elapsed, 2.5,
                          "timeout(0.3s) + 1s SIGKILL grace must keep total well under the 30s sleep — proves zombie reap fired")
    }

    // MARK: - Graceful-degrade-on-error parity with Python

    func testScanReturnsEmptyForNonExistentPath() async {
        let collector = GitCollector(secret: Data("k".utf8))
        let bogus = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
        let result = await collector.scan(projectPath: bogus)
        XCTAssertEqual(result, [])
    }

    func testScanReturnsEmptyForNonRepoDirectory() async throws {
        let nonRepo = rootTmp.appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(
            at: nonRepo, withIntermediateDirectories: true
        )
        let collector = GitCollector(secret: Data("k".utf8))
        let result = await collector.scan(projectPath: nonRepo)
        XCTAssertEqual(result, [],
                       "directory without .git must scan to []")
    }

    func testCollectIsolatesPerPathFailures() async throws {
        let goodRepo = try makeTempGitRepo(initialCommits: 2)
        let nonRepo = rootTmp.appendingPathComponent("not-a-repo-2")
        try FileManager.default.createDirectory(
            at: nonRepo, withIntermediateDirectories: true
        )

        let collector = GitCollector(secret: Data("k".utf8))
        let result = await collector.collect(projectPaths: [nonRepo, goodRepo])

        XCTAssertEqual(result.count, 2,
                       "good repo's commits must still surface even if a sibling path fails")
    }

    // MARK: - GitProjectPaths.extract

    func testExtractProjectPathsDedupsAndOrdersByFirstAppearance() {
        let urlA = URL(fileURLWithPath: "/Users/dev/a")
        let urlB = URL(fileURLWithPath: "/Users/dev/b")
        let urlC = URL(fileURLWithPath: "/Users/dev/c")

        let sessions: [CollectedSession] = [
            CollectedSession(sessionId: "s1", provider: "claude", projectRoot: urlA),
            CollectedSession(sessionId: "s2", provider: "codex", projectRoot: urlB),
            CollectedSession(sessionId: "s3", provider: "claude", projectRoot: urlA), // dup of s1
            CollectedSession(sessionId: "s4", provider: "gemini", projectRoot: nil),  // skipped
            CollectedSession(sessionId: "s5", provider: "claude", projectRoot: urlC),
        ]

        let paths = GitProjectPaths.extract(from: sessions)

        XCTAssertEqual(paths, [urlA, urlB, urlC],
                       "first-appearance order, deduped, nil skipped")
    }

    func testExtractFromEmptySessionListIsEmpty() {
        XCTAssertEqual(GitProjectPaths.extract(from: []), [])
    }

    // MARK: - Pipe-buffer deadlock regression (Gemini Slice 1 P0)

    func testLargeStdoutDoesNotDeadlockOnPipeBufferLimit() async throws {
        // macOS pipes default to 64 KB. If the parent doesn't drain
        // stdout concurrently with the wait loop, a child that writes
        // more than the buffer holds blocks on the next write — the
        // parent thinks the child is hung, fires the timeout, and
        // SIGKILLs it. Result: commits silently dropped on big repos.
        // This test pins the concurrent-drain fix.
        let fakeGit = rootTmp.appendingPathComponent("fake_big_git.sh")
        // Emit ~256 KB of stdout — 4× the typical pipe buffer — then
        // exit cleanly. If the parent doesn't drain, this hangs and
        // the test trips the 5 s timeout we set.
        try #"""
        #!/bin/bash
        # Each line ~64 bytes; 4096 lines ≈ 256 KB.
        for i in $(seq 1 4096); do
          echo "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123|2026-05-07T00:00:00+00:00|"
        done
        """#.write(to: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fakeGit.path
        )

        let repo = try makeTempGitRepo(initialCommits: 1)
        let collector = GitCollector(
            secret: Data("k".utf8),
            sinceWindow: "2 hours ago",
            subprocessTimeout: 5.0,  // generous; the fix makes drain ~instant
            gitPath: fakeGit
        )

        let started = Date()
        let result = await collector.scan(projectPath: repo)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.count, 4096,
                       "all 4096 lines must round-trip — pipe-buffer deadlock would have truncated or zero'd this")
        XCTAssertLessThan(elapsed, 4.0,
                          "fix-present: 256 KB of output drains in << 4 s; deadlock would have hit the 5 s timeout")
    }
}
