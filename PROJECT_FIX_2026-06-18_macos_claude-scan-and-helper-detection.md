# PROJECT FIX — macOS: Claude usage not detected + companion-CLI not detected (2026-06-18)

Two user-reported macOS detection failures (both on App Store v1.29.1). Fixed
together; self-review + Gemini 3.1 Pro review (LGTM). All changes in CLIPulseCore
(locally swift-build/tested); the app target compiles in CI.

## BUG 1 — Claude usage not detected after "grant folder access + force re-scan"
**Report:** user's Claude data is in the standard `~/.claude/projects` (48 jsonl,
recent; no `CLAUDE_CONFIG_DIR`, not a symlink, boot volume) — confirmed via the
user's terminal. So it's NOT a data-location issue (Cause A ruled out). Yet the
sandboxed app found 0 Claude usage even after the one-tap authorize + force re-scan.

**Root cause:** the folder-access grant only *stores* a security-scoped bookmark
— it never *activates* it in the current session (`grantAll` even explicitly
`stopAccessingSecurityScopedResource()`; `requestAccessViaPanel` just stores).
`forceRescanTokenCache` scans via `FileManager`, which needs an ACTIVE
security-scoped resource; without one, `fileExists(~/.claude/projects)` is false
in the sandbox and `CostUsageScanner.scanClaudeRoot` silently bails → 0 usage.
It only worked after an app **relaunch** (launch-time `resolveAllBookmarks`
activates the bookmark). The status row still showed "Granted" (it only checks
whether a bookmark is *stored*), so it looked fine.

**Fix:**
- `DataRefreshManager.forceRescanTokenCache()` → `await BookmarkManager.shared.resolveAllBookmarks()` BEFORE scanning (re-activates stored bookmarks).
- `BookmarkManager.requestAccessViaPanel` + `requestHomeAccessViaPanel` → `resolveBookmark(for: url.path)` right after `storeBookmark` (active immediately, same session).
- `FolderAccessView` per-dir "Grant" + "grant all" → auto-trigger `forceRescanTokenCache()` so usage appears immediately (no separate "Force re-scan" tap).

**Immediate workaround for affected v1.29.1 users (pre-fix):** grant access, then fully quit + relaunch CLI Pulse.

## BUG 2 — Companion CLI (helper) running in Activity Monitor but "not detected"
**Detection mechanism:** the app probes a UDS `hello()` to
`<group-container>/clipulse-helper.sock` (`LocalSessionControlClient`). The helper
(`HelperSwift/Sources/cli_pulse_helper/main.swift`) binds at
`AuthToken.containerPath()/clipulse-helper.sock` =
`homeDirectoryForCurrentUser/Library/Group Containers/group.yyh.CLI-Pulse/…`.
For a normally user-installed helper these paths MATCH (so the dev's Mac works).

**App-side bug fixed:** `LocalSessionControlClient.connect()` HARD-FAILED with
`helperNotRunning` when `FileManager.default.fileExists(socketPath)` was false —
*before even attempting* the `NWConnection`. `fileExists` is an unreliable gate
for a UNIX-domain socket created by the (unsandboxed) helper in the shared group
container, so a running/connectable helper could be reported "not running" purely
because the stat returned false. **Fix:** removed the hard-fail; always attempt
the connect, but use `min(connectTimeout, 1.5)` when the socket looks absent so a
genuinely-missing socket still fails fast (the v1.16 anti-hang intent — connect
runs on a background queue awaited via continuation, never blocks the main actor;
`stateUpdateHandler` maps ENOENT/ECONNREFUSED → `helperNotRunning`).

**Still to confirm (env-specific):** if the affected user's helper bound its socket
where the sandboxed app can't reach it (e.g. helper running as a different
launchd user/domain → `homeDirectoryForCurrentUser` ≠ the user's home, or the
group container absent), the app-side change alone won't detect it — that would
be a helper-side fix in `HelperSwift`. Diagnostic to run on the affected Mac:
`ls -la ~/Library/Group\ Containers/group.yyh.CLI-Pulse/` and
`lsof -U 2>/dev/null | grep -i clipulse-helper` (shows where the helper actually
bound vs where the app probes).

## Verification
- CLIPulseCore `swift build` clean; full suite green (1666 tests, 0 failures; LocalSession suite green).
- Self-review + Gemini 3.1 Pro diff review: LGTM.
- App target (`CLIPulseBarApp` wiring) compiles in CI only.
