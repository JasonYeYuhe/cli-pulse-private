import XCTest
@testable import HelperKit
import Foundation

/// M4.4a PR-C: ShellIntegration. Swift twin of `helper/test_shell_integration.py`.
/// Pure rendering / strip-block / install-uninstall-status logic + a real-shell
/// fail-open check (skipped when /bin/sh is unavailable). No tmux required.
final class ShellIntegrationTests: XCTestCase {

    private var tmpHome: String!

    override func setUp() {
        super.setUp()
        tmpHome = NSTemporaryDirectory() + "clipulse-shellint-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tmpHome, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpHome)
        super.tearDown()
    }

    // MARK: - rendering

    func testRcBlockIsMarkedAndSourcesInit() {
        let block = ShellIntegration.renderRcBlock(initPath: "/x/shell-init.sh")
        XCTAssertTrue(block.contains(ShellIntegration.markerBegin))
        XCTAssertTrue(block.contains(ShellIntegration.markerEnd))
        // Single-quoted (injection-safe) source line.
        XCTAssertTrue(block.contains(#"[ -f '/x/shell-init.sh' ] && . '/x/shell-init.sh'"#))
    }

    func testShellInitDefinesShimsAndFailsOpen() {
        let init_ = ShellIntegration.renderShellInit(tmuxBin: "/b/tmux", sock: "/s.sock", conf: "/c.conf")
        XCTAssertTrue(init_.contains("claude() {"))
        XCTAssertTrue(init_.contains("codex() {"))
        // fail-open guards.
        XCTAssertTrue(init_.contains("$CLIPULSE_WRAP_ACTIVE"))
        XCTAssertTrue(init_.contains(#"[ "$CLIPULSE_WRAP_DISABLE" = "1" ]"#))
        XCTAssertTrue(init_.contains("[ ! -t 0 ]"))
        XCTAssertTrue(init_.contains("[ ! -t 1 ]"))
        XCTAssertTrue(init_.contains(#"[ ! -x "$CLIPULSE_TMUX_BIN" ]"#))
        XCTAssertTrue(init_.contains(#"command "$@""#))
        // new-session -A wraps.
        XCTAssertTrue(init_.contains("new-session -A -s"))
        XCTAssertTrue(init_.contains("clipulse-"))
    }

    // MARK: - strip-block

    func testStripBlockToleratesMissingEndMarker() {
        let text = "before\n\(ShellIntegration.markerBegin)\n. /x\n"  // no END
        let stripped = ShellIntegration.stripBlock(text)
        XCTAssertFalse(stripped.contains(ShellIntegration.markerBegin))
        XCTAssertTrue(stripped.contains("before"))
    }

    func testStripBlockPreservesSurroundingContent() {
        let block = ShellIntegration.renderRcBlock(initPath: "/x/init.sh")
        let text = "export FOO=1\n\n\(block)\nalias ll='ls -la'\n"
        let stripped = ShellIntegration.stripBlock(text)
        XCTAssertFalse(stripped.contains(ShellIntegration.markerBegin))
        XCTAssertTrue(stripped.contains("export FOO=1"))
        XCTAssertTrue(stripped.contains("alias ll="))
    }

    // MARK: - install / uninstall / status round-trips

    private func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    func testInstallIsIdempotent() throws {
        let rc = (tmpHome as NSString).appendingPathComponent(".zshrc")
        try "export EXISTING=1\n".write(toFile: rc, atomically: true, encoding: .utf8)
        _ = try ShellIntegration.install(home: tmpHome, tmuxBin: "/b/tmux", rcFiles: [rc])
        let once = read(rc)
        _ = try ShellIntegration.install(home: tmpHome, tmuxBin: "/b/tmux", rcFiles: [rc])
        let twice = read(rc)
        XCTAssertEqual(once, twice, "re-install must not duplicate the block")
        // exactly one marked block.
        let count = once.components(separatedBy: ShellIntegration.markerBegin).count - 1
        XCTAssertEqual(count, 1)
        XCTAssertTrue(once.contains("export EXISTING=1"), "user content preserved")
        // managed files written.
        XCTAssertTrue(FileManager.default.fileExists(atPath: ShellIntegration.initPath(home: tmpHome)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ShellIntegration.confPath(home: tmpHome)))
    }

    func testUninstallRemovesBlockAndFiles() throws {
        let rc = (tmpHome as NSString).appendingPathComponent(".zshrc")
        try "user stuff\n".write(toFile: rc, atomically: true, encoding: .utf8)
        _ = try ShellIntegration.install(home: tmpHome, tmuxBin: "/b/tmux", rcFiles: [rc])
        _ = try ShellIntegration.uninstall(home: tmpHome, rcFiles: [rc])
        let after = read(rc)
        XCTAssertFalse(after.contains(ShellIntegration.markerBegin))
        XCTAssertTrue(after.contains("user stuff"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShellIntegration.initPath(home: tmpHome)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShellIntegration.confPath(home: tmpHome)))
    }

    func testUninstallSafeWhenNeverInstalled() throws {
        let rc = (tmpHome as NSString).appendingPathComponent(".zshrc")
        // No install; uninstall must not throw and not create the rc.
        _ = try ShellIntegration.uninstall(home: tmpHome, rcFiles: [rc])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rc))
    }

    func testStatusReflectsState() throws {
        let rc = (tmpHome as NSString).appendingPathComponent(".zshrc")
        let before = ShellIntegration.status(home: tmpHome, rcFiles: [rc])
        XCTAssertFalse(before.installed)
        XCTAssertFalse(before.initPresent)

        _ = try ShellIntegration.install(home: tmpHome, tmuxBin: "/b/tmux", rcFiles: [rc])
        let after = ShellIntegration.status(home: tmpHome, tmuxBin: "/b/tmux", rcFiles: [rc])
        XCTAssertTrue(after.installed)
        XCTAssertTrue(after.initPresent)
        XCTAssertEqual(after.rcFilesWithBlock, [rc])
        XCTAssertTrue(after.sock.hasSuffix(".clipulse/tmux.sock"))
    }

    func testInstallLocksDownClipulseDir() throws {
        _ = try ShellIntegration.install(home: tmpHome, tmuxBin: "/b/tmux",
                                         rcFiles: [(tmpHome as NSString).appendingPathComponent(".zshrc")])
        let attrs = try FileManager.default.attributesOfItem(atPath: ShellIntegration.clipulseDir(home: tmpHome))
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o700, "~/.clipulse holds the input-injection socket → 0700")
    }

    // MARK: - tmux resolution

    func testResolveTmuxBinPrefersExplicit() {
        XCTAssertEqual(ShellIntegration.resolveTmuxBin(explicit: "/custom/tmux"), "/custom/tmux")
    }

    func testResolveTmuxBinFallsBackToHomebrew() {
        // With no explicit + no bundled sibling next to the test binary, it
        // resolves to a PATH tmux OR the Homebrew fallback — never empty.
        let resolved = ShellIntegration.resolveTmuxBin()
        XCTAssertFalse(resolved.isEmpty)
        XCTAssertTrue(resolved.hasSuffix("/tmux"))
    }

    // MARK: - real-shell fail-open behavior (skipped if /bin/sh absent)

    private func runSh(_ script: String, extraPATH: String? = nil) throws -> (out: String, code: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        if let extraPATH {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = extraPATH + ":" + (env["PATH"] ?? "")
            proc.environment = env
        }
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        try? out.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", proc.terminationStatus)
    }

    /// Prove DELEGATION (review: codex — the old test only checked the shim was
    /// defined). In a NON-tty sh (no controlling tty → fail-open branch), the
    /// `claude` shim must run the REAL `claude` on PATH, not launch tmux. We
    /// plant a fake `claude` that prints a sentinel and assert it ran.
    func testShimFailsOpenAndDelegatesToRealBinary() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else { throw XCTSkip("no /bin/sh") }
        let initP = ShellIntegration.initPath(home: tmpHome)
        try FileManager.default.createDirectory(atPath: ShellIntegration.clipulseDir(home: tmpHome),
                                                withIntermediateDirectories: true)
        try ShellIntegration.renderShellInit(tmuxBin: "/nonexistent/tmux", sock: "/s.sock", conf: "/c.conf")
            .write(toFile: initP, atomically: true, encoding: .utf8)
        // Fake `claude` on a PATH dir that prints a sentinel + its args.
        let binDir = (tmpHome as NSString).appendingPathComponent("bin")
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let fake = (binDir as NSString).appendingPathComponent("claude")
        try "#!/bin/sh\necho REAL_CLAUDE_RAN \"$@\"\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        // sh -c has no controlling tty → fail-open → runs the real claude.
        let (out, _) = try runSh(". \(ShellIntegration.shQuote(initP)); claude --version", extraPATH: binDir)
        XCTAssertTrue(out.contains("REAL_CLAUDE_RAN --version"),
                      "non-tty launch must fail open to the real claude; got: \(out)")
    }

    // MARK: - codex-flagged hardening

    func testInstallRefusesToClobberUnreadableRc() throws {
        // An rc with invalid UTF-8 must NOT be silently replaced by just our
        // block (data-loss regression vs Python).
        let rc = (tmpHome as NSString).appendingPathComponent(".zshrc")
        try Data([0xFF, 0xFE, 0x00, 0x80, 0x81]).write(to: URL(fileURLWithPath: rc))
        XCTAssertThrowsError(try ShellIntegration.install(home: tmpHome, tmuxBin: "/b/tmux", rcFiles: [rc])) { err in
            guard case ShellIntegration.ShellIntegrationError.rcUnreadable = err else {
                return XCTFail("expected rcUnreadable, got \(err)")
            }
        }
        // The original bytes are UNTOUCHED.
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: rc)), Data([0xFF, 0xFE, 0x00, 0x80, 0x81]))
    }

    func testInstallFollowsSymlinkedRcPreservingTheLink() throws {
        // ~/.zshrc -> ~/dotfiles/zshrc: install must edit the TARGET and keep
        // the symlink (dotfile-manager parity).
        let dotfiles = (tmpHome as NSString).appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(atPath: dotfiles, withIntermediateDirectories: true)
        let real = (dotfiles as NSString).appendingPathComponent("zshrc")
        try "export FROM_DOTFILES=1\n".write(toFile: real, atomically: true, encoding: .utf8)
        let link = (tmpHome as NSString).appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        _ = try ShellIntegration.install(home: tmpHome, tmuxBin: "/b/tmux", rcFiles: [link])
        // The link is still a symlink…
        let attrs = try FileManager.default.attributesOfItem(atPath: link)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "install must not replace the symlink with a plain file")
        // …and the TARGET got both the user content + our block.
        let targetText = try String(contentsOfFile: real, encoding: .utf8)
        XCTAssertTrue(targetText.contains("export FROM_DOTFILES=1"))
        XCTAssertTrue(targetText.contains(ShellIntegration.markerBegin))
    }

    func testInstallFollowsSymlinkChainToFinalTarget() throws {
        // ~/.zshrc -> link1 -> real: writing must reach `real` and preserve BOTH
        // links (full-chain follow, not a one-hop that clobbers link1).
        let real = (tmpHome as NSString).appendingPathComponent("real-zshrc")
        try "chain-orig\n".write(toFile: real, atomically: true, encoding: .utf8)
        let link1 = (tmpHome as NSString).appendingPathComponent("link1")
        try FileManager.default.createSymbolicLink(atPath: link1, withDestinationPath: real)
        let rc = (tmpHome as NSString).appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(atPath: rc, withDestinationPath: link1)

        _ = try ShellIntegration.install(home: tmpHome, tmuxBin: "/b/tmux", rcFiles: [rc])
        // Both links survive as symlinks…
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: rc))[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: link1))[.type] as? FileAttributeType, .typeSymbolicLink)
        // …and the FINAL real file got the content.
        let text = try String(contentsOfFile: real, encoding: .utf8)
        XCTAssertTrue(text.contains("chain-orig"))
        XCTAssertTrue(text.contains(ShellIntegration.markerBegin))
    }

    func testStatusRejectsNonexistentExplicitTmux() {
        // status(tmuxBin: "/missing/tmux") must NOT claim it — validate exists.
        let st = ShellIntegration.status(home: tmpHome, tmuxBin: "/definitely/missing/tmux",
                                         rcFiles: [(tmpHome as NSString).appendingPathComponent(".zshrc")])
        XCTAssertNotEqual(st.tmuxBin, "/definitely/missing/tmux")
    }

    func testStatusRejectsDirectoryAsTmux() {
        // A searchable DIRECTORY (`/bin`) is +x but not a real binary — it must
        // NOT be reported as tmux (review: codex — would pass the shim's -x
        // guard and claude would try to exec a directory).
        let st = ShellIntegration.status(home: tmpHome, tmuxBin: "/bin",
                                         rcFiles: [(tmpHome as NSString).appendingPathComponent(".zshrc")])
        XCTAssertNotEqual(st.tmuxBin, "/bin")
    }

    func testWriteRcRefusesCyclicSymlink() throws {
        // a -> b -> a : unresolvable. install must refuse, not replace a link.
        let a = (tmpHome as NSString).appendingPathComponent(".zshrc")
        let b = (tmpHome as NSString).appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(atPath: a, withDestinationPath: b)
        try FileManager.default.createSymbolicLink(atPath: b, withDestinationPath: a)
        // A cycle is refused non-destructively — either at read time (ELOOP →
        // rcUnreadable) or at the writeRc cycle guard (rcUnresolvableSymlink);
        // both are ShellIntegrationErrors that leave the link untouched.
        XCTAssertThrowsError(try ShellIntegration.install(home: tmpHome, tmuxBin: "/b/tmux", rcFiles: [a])) { err in
            XCTAssertTrue(err is ShellIntegration.ShellIntegrationError, "expected a refusal, got \(err)")
        }
        // The cyclic link is untouched (still a symlink).
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: a))[.type] as? FileAttributeType,
                       .typeSymbolicLink)
    }

    func testShellInitPathsAreSingleQuotedAgainstInjection() {
        // A metachar-laden path must be inert (single-quoted), not injectable.
        let evil = "/home/u$(touch /tmp/pwned)/tmux"
        let init_ = ShellIntegration.renderShellInit(tmuxBin: evil, sock: "/s", conf: "/c")
        XCTAssertTrue(init_.contains(ShellIntegration.shQuote(evil)),
                      "tmuxBin must be single-quoted so $() can't execute")
        XCTAssertFalse(init_.contains("\"${CLIPULSE_TMUX_BIN:-\(evil)}\""),
                       "must not double-quote-interpolate the raw path")
    }
}
