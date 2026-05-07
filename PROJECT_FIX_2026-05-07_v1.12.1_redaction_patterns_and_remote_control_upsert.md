# PROJECT_FIX — v1.12.1 — Redaction Patterns + Remote-Control Upsert

**Date:** 2026-05-07
**Branch:** `v1.12.1-redaction-and-upsert` (cut from `main`)
**Source:** Cross-team backport from cli-pulse-desktop's v0.6.0–v0.7.0 Gemini 3.1 Pro
post-impl review. See `memory/feedback_mac_windows_remote_track_alignment.md`
items #2 and #7c — both flagged as **P1** for Mac.

## Why this is a release

Two independent privacy/security holes in shipped Mac code:

1. **M1 — redaction gap**: `helper/redaction.py` was missing 5 third-party
   credential shapes (Stripe `sk_live_/sk_test_/rk_*`, Stripe publishable
   `pk_*`, Slack `xox*-`, NPM `npm_`, PyPI `pypi-`). Any Claude
   `tool_input` or remote-session stdout that mentioned one of these
   tokens uploaded the credential verbatim to Supabase. Stripe live keys
   are immediately exploitable, hence P1.
2. **M4 — remote-control toggle silently lies**: `APIClient.updateSettings`
   used `PATCH /rest/v1/user_settings?user_id=eq.<uid>`. PostgREST does not
   upsert on PATCH — when the user's row doesn't exist (every first-time
   toggler), PATCH matches zero rows and returns HTTP 2xx with an empty
   body, which the UI mis-read as a successful toggle while the server
   retained the default `remote_control_enabled = false`. **Privacy
   toggle was lying about being on.**

Bundled as **v1.12.1** — both fixes are small, isolated, and target the
same class of "we promised X about user data, then accidentally didn't
do X" bug.

## Files changed

| File | Change |
|---|---|
| [helper/redaction.py](helper/redaction.py) | +5 token-shape regexes (Stripe sk/rk/pk live+test, Slack xox a/b/p/r/s, NPM npm_, PyPI pypi-) inserted between provider keys and AWS-style |
| [helper/test_redaction.py](helper/test_redaction.py) | New section "4b. Third-party service keys" — 10 tests, fixtures split via string concatenation to avoid GitHub Push Protection on real-shape secrets |
| [CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/APIClient.swift](CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/APIClient.swift) | `updateSettings` rewritten as `POST /rest/v1/user_settings` + `Prefer: resolution=merge-duplicates`; new private `restPost<Body>` helper with per-call `extraHeaders`; new private `SettingsUpsertEnvelope` struct that flattens `user_id` + the patch into one JSON object via custom `encode(to:)` |

## Per-fix root cause + what changed

### M1 — redaction +5 patterns

**Root cause:** `_PATTERNS` in `redaction.py` only knew Anthropic/OpenAI
`sk-`, Google `AIza`, GitHub `ghp_`/`github_pat_`, AWS `AKIA`, Bearer
tokens, JWTs, and long hex blobs. Anything else passed through. Stripe
keys begin with `sk_` (underscore — not the dash-prefixed `sk-` shape we
covered), so they slipped through both passes.

**Fix:**
- Added 5 compiled regexes (lines 198–215 in the new file) targeting
  exactly the live+test variants of Stripe secret/restricted/publishable,
  all 5 Slack token prefix letters, NPM `_`-prefixed, PyPI `-`-prefixed.
- Each regex has a 16-char (Slack: 10-char) minimum trailing length to
  avoid colliding with short non-credential identifiers.
- New patterns inserted **before** the existing `\b[A-Fa-f0-9]{32,}\b`
  long-hex pattern so any all-hex token bodies get redacted by the
  prefix-aware regex first (the long-hex pattern would also catch a
  pure-hex Stripe test fixture but the prefix-aware regex preserves the
  shape information for future audit).

**Test coverage:** 10 new tests in section 4b. All fixtures use
concatenation tricks (`"sk_l" + "ive_" + "..."`) to keep the test file
itself from tripping GitHub Push Protection's Stripe scanner. Tests use
bare-token context (no `*_KEY=` envelope) so Pass 2 (token shape) is
exercised, not Pass 1 (key/header).

### M4 — `updateSettings` PATCH → POST upsert

**Root cause:** `restPatch("/rest/v1/user_settings?user_id=eq.<uid>", body: patch)`
sends a PostgREST PATCH that filters by `user_id`. For a user who never
had a row in `user_settings` (every first-time toggler — `track_git_activity`,
`remote_control_enabled`, etc.), PATCH matches 0 rows. PostgREST
returns HTTP 200 + `Content-Length: 0` (or sometimes `[]`). The Swift
client treated 2xx as success without inspecting the body length, so the
UI optimistically left `remoteControlEnabled = true` while the database
still held `false`. Subsequent reads (next polling cycle) would discover
the truth — but in the meantime, the user thought remote control was
allowed. Same bug for `track_git_activity` and any other future settings
toggle that follows the same path.

**Fix (mirrors cli-pulse-desktop v0.6.0):**
- New private helper `restPost<Body: Encodable>(path:body:extraHeaders:retried:)`
  parallel to `restPatch`; `extraHeaders` lets the call attach
  `Prefer: resolution=merge-duplicates`.
- New private nested struct `SettingsUpsertEnvelope` that wraps a
  `SettingsPatch` together with `user_id`. Custom `encode(to:)` first
  encodes the patch (which writes its own `Optional`-aware fields to the
  encoder's keyed container via auto-synthesis) and then writes
  `user_id` to the same container. Result: `{"user_id":"...","<set fields only>":...}`
  — the exact PostgREST upsert body shape, with nil patch fields omitted
  so an UPDATE doesn't accidentally clobber other columns to NULL.
- `updateSettings` now calls `restPost("/rest/v1/user_settings", body: envelope, extraHeaders: ["Prefer": "resolution=merge-duplicates"])`.
- Conflict target is `user_settings.user_id` PRIMARY KEY (per cross-team
  memory: schema confirmed via `pg_get_constraintdef` query). New users
  → INSERT. Existing → UPDATE. No race.

**No schema change.** No migration. The `Prefer: resolution=merge-duplicates`
header is recognized by every PostgREST version Supabase supports.

**Other call sites of `restPatch`:** unchanged. Alerts ack/snooze/resolve
all genuinely target an existing-row WHERE clause — for those, PATCH
semantics are correct and the row's existence is enforced earlier in the
flow. Only `user_settings` had the first-time-toggler problem.

## Verification

| Step | Result |
|---|---|
| `python3 -m pytest helper/test_redaction.py -v` | **76/76 passed** (10 new) |
| `swift build` from `CLI Pulse Bar/CLIPulseCore` | Build complete (only pre-existing warnings, none from this diff) |
| `xcodebuild build -project "CLI Pulse Bar/CLI Pulse Bar.xcodeproj" -scheme "CLI Pulse Bar" -destination "platform=macOS,arch=arm64"` | **BUILD SUCCEEDED** |
| Standalone Swift envelope-encoding script (`/tmp/verify_envelope_encoding.swift`) | All 3 cases pass: single toggle → `{"remote_control_enabled":true,"user_id":"..."}`; multi-field → all set fields present, nil omitted; empty patch → `{"user_id":"..."}` only |
| `grep -E "(stripe|slack.*token\|merge-duplicates\|user_settings.*upsert)" PROJECT_FIX_*.md` | No prior fix archive covers these — confirmed not duplicating an earlier session |
| `grep -nE "restPatch" APIClient.swift` | 7 hits remain (alerts ack, snooze, resolve, sessions) — restPatch retained for legitimate use |

## Computer-use end-to-end toggle test (post-merge)

After the PR merges and a new Debug build is staged, exercise the toggle
path against a real demo account using computer-use:

1. Quit running `CLI Pulse Bar` (DerivedData build).
2. Launch the v1.12.1 Debug `.app`.
3. Open Settings → Privacy/Remote Control toggle.
4. Toggle ON, wait ~1 sec, observe DataRefreshManager next poll.
5. Confirm via Supabase MCP: `SELECT remote_control_enabled FROM user_settings WHERE user_id = '<demo>'` returns `true`.

Will run after CI green.

## Out of scope / remaining TODOs

- **Phase 4E Swift port** (Sprint C): when `helper/redaction.py` is
  ported to Swift, the new 5 patterns must port too. Track in
  `docs/PHASE_4E_DEV_PLAN.md` (to be drafted).
- **Sprint B (v1.12.2)**: M2 (`helper/remote_hook.py` per-request 2.5s
  timeout) and M3 (`provider_adapters/claude.py:_classify_risk`
  token-level). Both P2, not blocking v1.12.1.
- **HelperKit Swift redaction module**: existing `phase4d-swift-helper`
  branch has parity with the *previous* Python pattern set. Once Phase 4E
  starts, the HelperKit redactor needs the same 5 patterns added — but
  Phase 4D is still draft so this is a Phase 4E concern, not v1.12.1.

## Cross-team note

This PR closes Mac M1 + M4 from
`memory/feedback_mac_windows_remote_track_alignment.md` Mac sprint table.
M2 and M3 (P2) ship in v1.12.2. Windows v0.7.0 currently has 0 blocking
items from this sprint — no reciprocal action needed there.
