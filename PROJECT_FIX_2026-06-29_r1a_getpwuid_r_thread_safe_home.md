# PROJECT FIX — R1a: getpwuid → thread-safe getpwuid_r for real-home resolution

**Date:** 2026-06-29
**Train:** v1.34 ship (R1 pre-ship hardening)
**Area:** CLIPulseCore (macOS home-directory resolution)
**Origin:** Gemini 3.5 Flash finding #5 on the in-app-terminal/OAuth changeset
(`getpwuid` returns shared static storage → not thread-safe).

## Problem
`getpwuid(getuid())` returns a pointer into a single process-wide static
`passwd` buffer. A concurrent `getpwuid` / `getpwnam` / `getpwent` call on any
other thread can overwrite that buffer between the call and the `pw_dir` read,
yielding a torn or wrong home path. Home resolution runs off background queues
(collectors, the local-session client, bookmark restore) while the app is live,
so the race is reachable.

The pattern was copy-pasted across **5** call sites in CLIPulseCore, each with
its own fallback:
1. `UnsandboxedDataMigration.realUserHome()` (the W1-A unsandbox migration — the
   site Gemini flagged; a wrong home here would migrate to / read from the wrong
   container).
2. `LocalSessionControlClient.groupContainerBasePath()` (helper socket/token path).
3. `HelperInstaller.helperDir` (the `~/Library/CLI-Pulse-Helper/` resolution).
4. `BookmarkManager.realUserHome()`.
5. `ClaudeCredentials.realHomeDir` (Claude credential discovery).

## Fix
Introduce one shared, thread-safe helper `passwdHomeDirectory()` in
`PasswdHome.swift` (`#if os(macOS)`, matching all 5 macOS-only call sites) that
uses `getpwuid_r` with a caller-owned buffer:
- buffer sized via `sysconf(_SC_GETPW_R_SIZE_MAX)` (fallback 16 KiB when the
  platform reports `-1`);
- `ERANGE` → double-and-retry, capped at 1 MiB so a misbehaving libc can't spin
  an unbounded allocation loop;
- `rc == 0 && result == NULL` is treated as "no entry" (returns `nil`, not an
  error);
- `pw_dir` (which points INTO the live buffer) is copied to a Swift `String`
  before the buffer goes out of scope;
- returns `nil` (never a sandbox/guessed path) on any failure or empty home, so
  each call site keeps its **exact** prior fallback (`NSHomeDirectoryForUser`,
  `NSHomeDirectory`, container-path stripping, etc.).

Centralizing also removes the 5× duplication of the tricky lookup. The only
behavioral change vs the old code: where the old guard returned an *empty* home
string verbatim, the helper now treats empty as failure and falls through to the
site's fallback — strictly safer.

## Verification
- New unit test `test_passwdHomeDirectory_agreesWithLegacyGetpwuid` asserts the
  `getpwuid_r` result is absolute, non-empty, never a container path, and equals
  the legacy `getpwuid` result.
- Full `swift test` (no `--filter`) on CLIPulseCore: **1827 tests, 0 failures, 4
  skipped, exit 0**.
- Reviewed by Gemini 3.1 Pro + Codex (see PR).

## Notes
R1c (pushChunk `WKContentWorld` isolation) remains deferred to v1.34.1 per the
DEV_PLAN (headless-untestable render risk).
