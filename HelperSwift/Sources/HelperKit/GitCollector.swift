import Foundation
import CryptoKit
import Darwin

/// One row uploaded to Supabase `ingest_commits` per detected commit.
/// Field names match the Python `helper/git_collector.py::CommitRecord`
/// dataclass — same wire shape so the server side doesn't notice a
/// language switch.
public struct CommitRecord: Codable, Sendable, Equatable {
    /// Git SHA-1.
    public let commitHash: String

    /// Hex-encoded HMAC-SHA256 of the absolute project path, keyed by
    /// the user's helper secret. The plaintext path NEVER reaches
    /// Supabase — only this digest, which the server uses as a stable
    /// project identifier without learning where on disk the project
    /// lives.
    public let projectHash: String

    /// ISO-8601 committer date from `git log --pretty=%aI`.
    public let committedAt: String

    /// `git log --no-merges` already filters merges, but defend in
    /// depth: a commit with more than one parent gets `isMerge=true`
    /// so the server can exclude it from yield attribution even if
    /// the flag stops working in some future git release.
    public let isMerge: Bool

    /// Wire-shape parity with `helper/git_collector.py::CommitRecord`'s
    /// `to_dict()` — Supabase `ingest_commits` expects snake_case keys.
    /// Without these, Swift's synthesized `Codable` would emit camelCase
    /// and the server would silently drop the fields.
    private enum CodingKeys: String, CodingKey {
        case commitHash = "commit_hash"
        case projectHash = "project_hash"
        case committedAt = "committed_at"
        case isMerge = "is_merge"
    }

    public init(
        commitHash: String,
        projectHash: String,
        committedAt: String,
        isMerge: Bool
    ) {
        self.commitHash = commitHash
        self.projectHash = projectHash
        self.committedAt = committedAt
        self.isMerge = isMerge
    }
}

/// Stateful per-project commit scanner. Mirrors
/// `helper/git_collector.py::GitCollector` semantics 1:1:
///
///   * Same `git log --no-merges --since=<window> --pretty=%H|%aI|%P`
///     subprocess shape.
///   * Same per-project last-seen-hash cache: a commit is emitted
///     once and once only across repeated scans, until `resetCache()`
///     is invoked or the daemon restarts.
///   * Same dedupe-by-hash across worktrees in `collect`.
///   * Same HMAC scheme as `helper/user_secret.py::project_hash` —
///     UTF-8 bytes of the absolute path string, HMAC-SHA256, lower-hex.
///   * Same privacy guarantees: NO commit message, diff, file paths,
///     or author identity are read; the plaintext absolute path never
///     leaves the device.
///
/// Subprocess hygiene (Phase 4E plan v2.1, Gemini P1 — zombie reap on
/// timeout): the launched `git` child is `terminate()`d on timeout AND
/// outer-task cancellation, then `SIGKILL`ed after a 1 s grace if it
/// is still alive. Naive throw-without-reap leaks zombies under load.
public actor GitCollector {

    /// Errors `runGit` can throw. They never escape `scan(projectPath:)`
    /// or `collect(projectPaths:)` — both swallow errors and return
    /// `[]` to match Python's "log warning, return empty" contract.
    /// They DO escape unit tests that exercise `runGit` directly.
    public enum CollectorError: Error {
        case timedOut(URL)
        case gitNotFound
    }

    private let secret: Data
    private let sinceWindow: String
    private let subprocessTimeout: TimeInterval
    private let gitPath: URL
    private var lastSeenPerProject: [URL: String] = [:]

    public init(
        secret: Data,
        sinceWindow: String = "2 hours ago",
        subprocessTimeout: TimeInterval = 10.0,
        gitPath: URL = URL(fileURLWithPath: "/usr/bin/git")
    ) {
        self.secret = secret
        self.sinceWindow = sinceWindow
        self.subprocessTimeout = subprocessTimeout
        self.gitPath = gitPath
    }

    /// Scan one project for commits newer than the last-seen hash for
    /// that path. Returns commits in newest-first order (matches
    /// `git log` default), or `[]` on any error.
    public func scan(projectPath: URL) async -> [CommitRecord] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectPath.path, isDirectory: &isDir),
              isDir.boolValue else {
            return []
        }
        let dotGit = projectPath.appendingPathComponent(".git")
        guard fm.fileExists(atPath: dotGit.path) else {
            return []
        }

        let output: String
        do {
            output = try await runGit(at: projectPath, args: [
                "-C", projectPath.path,
                "log",
                "--no-merges",
                "--since=\(sinceWindow)",
                "--pretty=format:%H|%aI|%P",
            ])
        } catch {
            return []
        }

        let projectKey = projectPath
        let lastSeen = lastSeenPerProject[projectKey]
        let projectHash = projectHashHex(for: projectPath.path)

        var commits: [CommitRecord] = []
        var firstHash: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let parts = line.split(separator: "|", maxSplits: 2,
                                   omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let commitHash = String(parts[0])
            let committedAt = String(parts[1])
            let parents = parts.count > 2 ? String(parts[2]) : ""

            if firstHash == nil { firstHash = commitHash }
            if commitHash == lastSeen {
                // We've reached the last-seen mark for this project —
                // everything older was already emitted on a prior scan.
                break
            }

            let parentCount = parents.split(
                separator: " ",
                omittingEmptySubsequences: true
            ).count
            commits.append(CommitRecord(
                commitHash: commitHash,
                projectHash: projectHash,
                committedAt: committedAt,
                isMerge: parentCount > 1
            ))
        }

        if let first = firstHash {
            lastSeenPerProject[projectKey] = first
        }
        return commits
    }

    /// Scan multiple projects and return the union of new commits,
    /// deduplicated by commit hash so a commit shared between two
    /// worktrees uploads exactly once.
    public func collect(projectPaths: [URL]) async -> [CommitRecord] {
        var out: [CommitRecord] = []
        var seen: Set<String> = []
        for path in projectPaths {
            let records = await scan(projectPath: path)
            for record in records {
                if seen.contains(record.commitHash) { continue }
                seen.insert(record.commitHash)
                out.append(record)
            }
        }
        return out
    }

    /// Drop the per-project last-seen cache. Daemon calls this on
    /// SIGHUP so an operator-triggered "rescan everything" does the
    /// expected thing.
    public func resetCache() {
        lastSeenPerProject.removeAll()
    }

    // MARK: - HMAC

    /// `HMAC-SHA256(secret, utf8(absolutePath)).hex_lower()`. Must
    /// produce identical output to `helper/user_secret.py::project_hash`
    /// for the same `(secret, absolutePath)` pair — pinned by
    /// `GitCollectorTests.test_hmac_parity_with_python`. Exposed as a
    /// static so the parity test can call it without round-tripping a
    /// real git repo.
    internal static func computeProjectHashHex(
        secret: Data,
        absolutePath: String
    ) -> String {
        let key = SymmetricKey(data: secret)
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(absolutePath.utf8),
            using: key
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func projectHashHex(for absolutePath: String) -> String {
        Self.computeProjectHashHex(secret: secret, absolutePath: absolutePath)
    }

    // MARK: - Subprocess

    /// Run `git` with bounded execution time. Always reaps the child
    /// on timeout OR outer-task cancellation so we don't leak zombies
    /// under sustained load (Gemini Phase 4E v2 P1). Returns the raw
    /// stdout as a UTF-8 string; non-zero git exit returns "" rather
    /// than throwing (Python contract: "log warning, return []").
    private nonisolated func runGit(
        at path: URL,
        args: [String]
    ) async throws -> String {
        let process = Process()
        process.executableURL = gitPath
        process.arguments = args
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()  // discard; matches Python which logs the head only

        do {
            try process.run()
        } catch {
            // Most common cause: `gitPath` doesn't exist (git not
            // installed). Surface as a typed error so unit tests can
            // discriminate, but `scan(projectPath:)` swallows it.
            throw CollectorError.gitNotFound
        }

        // Drain stdout concurrently to avoid pipe-buffer deadlock —
        // macOS pipes are typically 64 KB, and a wide `--since=2 hours
        // ago` window on an active monorepo can blow past that. With
        // no concurrent reader, git would block on the next pipe write
        // and the wait loop would falsely classify the hang as a
        // timeout, then SIGKILL — silently dropping commits. Detached
        // task so the drain runs on a background queue, independent of
        // the wait loop's thread (Phase 4E v2 P1 — Gemini follow-up).
        let drainTask = Task<Data, Never>.detached(priority: .utility) {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let deadlineNs = DispatchTime.now().uptimeNanoseconds
            + UInt64(subprocessTimeout * 1_000_000_000)

        do {
            while process.isRunning {
                try Task.checkCancellation()
                if DispatchTime.now().uptimeNanoseconds > deadlineNs {
                    throw CollectorError.timedOut(path)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            // Either the deadline elapsed or the outer task was
            // cancelled. EITHER way, reap the child — naive throw
            // would leave it as a zombie until the parent exits.
            // `Thread.sleep` (sync) is deliberate here: `Task.sleep`
            // throws `CancellationError` immediately on a cancelled
            // task, bypassing our 1 s SIGTERM grace and going straight
            // to SIGKILL — git typically exits cleanly on SIGTERM, so
            // the grace is worth keeping (Phase 4E v2 P1 — Gemini
            // follow-up).
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 1.0)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            // Drain task is left to complete on its own; it'll see EOF
            // when the dead process's stdout closes.
            throw error
        }

        if process.terminationStatus != 0 {
            return ""
        }
        let data = await drainTask.value
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Pure-function helper for extracting unique project root URLs from a
/// session list. Lives outside the actor so callers don't pay the
/// hop-on-actor cost just to iterate a small array.
public enum GitProjectPaths {

    /// Return the unique non-`nil` `projectRoot` URLs, in the order
    /// they first appear in `sessions`. A session whose `projectRoot`
    /// is `nil` is silently skipped (it's a session not bound to a
    /// project — REPL, helper self-test, etc.).
    public static func extract(from sessions: [CollectedSession]) -> [URL] {
        var seen: Set<URL> = []
        var out: [URL] = []
        for session in sessions {
            guard let root = session.projectRoot else { continue }
            if seen.contains(root) { continue }
            seen.insert(root)
            out.append(root)
        }
        return out
    }
}
