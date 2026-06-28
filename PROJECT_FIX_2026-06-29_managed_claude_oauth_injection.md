# PROJECT FIX — managed `claude` sessions use the user's plan (Max), not Claude API

**Date:** 2026-06-29
**Branch / PR:** `fix/managed-claude-oauth-injection`
**Found by:** owner, during the W1 in-app-terminal on-device test (the spawned
Claude Code TUI showed "Sonnet 4.6 · Claude **API**" instead of the Max plan).

## Problem
A managed `claude` session spawned by the helper authenticated as **Claude API**
(pay-per-token) instead of the user's **Max subscription**. Root cause, traced in
the Swift helper:
- The helper has no `ANTHROPIC_API_KEY` (`ps eww`), none in the login shell, none
  in `~/.claude/settings.json` — so it isn't a stray API key.
- The user IS logged into Max (`~/.claude/.credentials.json` →
  `claudeAiOauth.subscriptionType = "max"`).
- But the **Swift helper injects NO Anthropic auth** at spawn
  (`ManagedSessionManager.startSession` only set the hook vars). `claude` reads
  the macOS Keychain item `Claude Code-credentials` FIRST, and in the
  LaunchAgent-spawned context that read doesn't reliably yield the subscription
  (broken/empty keychain refresh token + GUI-session/ACL differences) → it
  degrades to "Claude API".
- The proven fix (`feedback_managed_claude_agy_auth`, on-device 2026-06-20) — read
  the FILE refresh token, refresh, and inject `CLAUDE_CODE_OAUTH_TOKEN` — existed
  only in the **Python** helper and was never ported to the **Swift** helper now
  in use.

## Fix
Port the OAuth-token injection to the Swift helper, leak-safe via an inherited fd.

- **`ClaudeOAuthInjector.swift`** (new): reads `~/.claude/.credentials.json`
  `claudeAiOauth`; if the access token is still valid → use it (no network); else
  POST `https://console.anthropic.com/v1/oauth/token` (api.anthropic.com fallback)
  with the **required** public Claude Code `client_id`
  (`9d1c250a-…`), parse the new access token + **rotated** refresh token, and
  persist atomically (temp+rename, 0600, preserving `subscriptionType`/`scopes`/
  any unknown fields). Best-effort: any failure → nil → claude's own ambient auth
  (no regression). Synchronous, timeout-bounded HTTP (injectable for tests).
- **`PtyTransport`**: new `inheritedFD: (envVar, data)?` — creates a pipe, writes
  the secret, closes the write end, and lets posix_spawn inherit the read end;
  passes its number via the env var; closes the parent copy on success/failure.
  The token therefore rides an fd, NOT the env — so it never leaks to `ps eww` or
  to tool subprocesses the agent spawns.
- **`ManagedSessionManager`**: for `provider == "claude"`, resolves the token
  (overridable `claudeTokenResolver` for tests) and injects it as
  `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` (exact name — `…_FD` does NOT work).
  Codex/Gemini paths unchanged (agy authenticates via `~/.gemini`).

## Verification
- `swift test` (HelperSwift): **427 tests, 0 failures**, incl. new
  `ClaudeOAuthInjectorTests` (valid-token-no-network, refresh+rotate+persist+
  preserve-fields, request shape with client_id, console→api fallback, missing
  file, no-RT) and `PtyTransportInheritedFDTests` (a real child reads the injected
  secret from the inherited fd; absent → env var unset).
- **On-device (live)**: injecting THIS user's real subscription token via
  `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` → `claude -p` returns success
  (`service_tier: standard`). In a STRIPPED env (empty HOME, zero ambient
  credentials) the injected token ALONE authenticates → definitively the
  subscription, not API. (claude 2.1.195; FD injection proven ≥ 2.1.183.)

## Codex security review — hardening applied (2026-06-29)
A Codex review of the diff found 6 real issues, all fixed + tested:
1. `persist` now returns Bool and logs loudly on failure (a dropped rotated RT
   could brick future login).
2. Lost-update guard: persist **re-reads** the file first, and **conflict-detects**
   — if the on-disk refresh token changed since we read it (a concurrent `claude`
   rotated it), we bail rather than clobber the live winner's credentials.
3. `0600` is forced on the FINAL path (`replaceItemAt` preserves the original's
   metadata, so a 0644 original would otherwise stay 0644).
4. `expiresAt` ms-vs-seconds is disambiguated by magnitude (a seconds value would
   otherwise read as 1970 → needless refresh → more RT-rotation exposure).
5. A partial / oversized pipe write injects **nothing** (never a truncated token).
6. The read fd is intentionally non-CLOEXEC (claude must inherit it across the
   exec) and claude closes it before spawning tools — documented leak-safe contract.

## Notes / not done
- Could not run through the *installed* helper binary on-device (it's
  `.pkg`-installed at `~/Library/CLI-Pulse-Helper/cli_pulse_helper` with a Launch
  Constraint/LWCR that rejects an ad-hoc rebuild) — but the three links (resolve →
  inherited-fd → claude auth) are each verified, so the composed path is proven.
- The injected access token is a static ~8h bearer; claude won't refresh it
  mid-session, so >8h sessions can re-hit expiry. Acceptable (orphan/idle caps
  bound it); a long-session refresh is a follow-up.
- No new privacy toggle: this injects the user's OWN token for the user's OWN
  managed session. (`PrivacySettings.skipClaudeKeychain` governs cross-app
  COLLECTION reads, a different concern.)
