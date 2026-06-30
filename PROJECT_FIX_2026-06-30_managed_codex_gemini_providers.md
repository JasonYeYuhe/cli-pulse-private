# PROJECT FIX — managed Codex + Gemini run on your plan

**Date:** 2026-06-30 · **Train:** Managed Codex + Gemini on-plan (PR-B of 2; the feature)
**Plan:** `DEV_PLAN_2026-06-30_managed_codex_gemini_onplan.md` (Gemini 3.1 Pro + Codex reviewed).
**Depends on:** PR-A (the generalized env seam: `ProviderEnvPatch`, HOME/PATH augmentation).

## What
Extends the v1.34 "managed Claude on Max" win so a managed **Codex** session runs on the
user's **ChatGPT plan** and a managed **Gemini** session runs on the user's **Gemini plan**,
not the pay-per-token API. Both are file-/argv-driven (no token injection like Claude's FD).

### Gemini → `agy` (`GeminiSpawner`)
Route through the proven `agy` wrapper (OAuth via `~/.gemini/oauth_creds.json`, which agy
self-refreshes) instead of bare `gemini`. argv0 resolution: `CLI_PULSE_GEMINI_ARGV0` →
`/opt/homebrew/bin/agy` → `agy` on the augmented PATH; `isAvailable()` probes the same.
Launch BARE `agy` (interactive REPL) — **no seed via argv/env** (those leak to same-user
process inspection; seed via the PTY if ever needed). The old `--yolo` (which agy rejects)
is remapped to `--dangerously-skip-permissions` ONLY when `CLI_PULSE_GEMINI_YOLO` is truthy
AND `agy --help` advertises the flag — else **fail safe** (degrade to interactive approvals;
agy is a fast-moving 3rd-party CLI, a flag rename must not break spawning).

### Codex → ChatGPT-plan (`CodexSpawner.envPatch`)
Codex is file-driven (reads `~/.codex/auth.json`, honors `CODEX_HOME`, self-refreshes its
own token). To force the plan without a token injector: pin `CODEX_HOME=<home>/.codex`, and
**DELETE any inherited `OPENAI_API_KEY`** so codex can't silently fall back to the billed
API — but ONLY when the user has a **verified ChatGPT login** (`auth_mode=="chatgpt"` + a
non-empty `tokens.access_token`/`refresh_token`, read via the existing
`CodexQuotaFetcher.extractAccessToken`). An api-key user (`auth_mode=="apikey"`) or a
missing/unreadable auth.json is left untouched (no worse than today). Per the review, a
parallel network refresh is DEFERRED (it would rotate the refresh_token and nuke the login).

## Tests (full HelperKit `swift test`: 456 tests, 0 failures)
- `ManagedProviderSpawnerTests` (14): agy argv0 override; bare-by-default; YOLO→skip-perms
  when supported; **YOLO fails safe when the flag is absent**; Codex verified-auth matrix
  (chatgpt+access ✓, chatgpt+refresh ✓, apikey ✗, missing-mode ✗, chatgpt-no-token ✗,
  unreadable ✗); CODEX_HOME pin; nil-home no-pin.
- Updated `ProviderSpawnerRegistryTests` gemini cases (old `gemini`/`--yolo` assertions →
  the new agy contract, tested via the deterministic pure helpers — argv() itself does
  machine-dependent filesystem resolution so isn't asserted directly).

## Verification note (on-device, owner)
End-to-end on-plan behavior (codex runs on ChatGPT plan with no OPENAI_API_KEY; `agy` stays
interactive; launchd delivers the augmented HOME/PATH) needs the next DEVID smoke per
`docs/DEVID_TERMINAL_SMOKE.md` (blocked on this Mac by the App Store install). The user's
creds were verified present on-device during the design map.

## Deferred (noted)
- Per-provider plan-auth **readiness signal** in the hello reply + picker warning (so an
  api-key Codex user isn't silently on pay-per-token). The gated scrub already prevents
  *silent* mis-billing (scrub only on verified chatgpt; apikey is the user's explicit
  choice), so this is a UX warning, not a correctness gap.
- Codex OAuth network refresh (endpoint/client_id unverified; codex self-refreshes).
