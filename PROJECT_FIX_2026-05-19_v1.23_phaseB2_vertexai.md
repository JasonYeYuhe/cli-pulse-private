# PROJECT_FIX — v1.23.0 CodexBar Phase B-2: Vertex AI collector (2026-05-19)

Branch `feature/v1.23.0-phaseB-vertexai` (cut from `main` `e3867e2` =
Phase B-1 PR #47 merge). 2nd increment of Phase B (fragility-ascending
stub promotions). No overlap with G1–G4 / B-1.

## Context / why
Phase B-1 (Perplexity) merged. Per the validated fragility-ascending
strategy, B-2 = VertexAI (MEDIUM, low fragility — clean gcloud ADC
file + token refresh + Cloud-Monitoring API; no browser/scrape).
CodexBar source `/tmp/codexbar-latest` @ `7e97d2b`; 3 source files
(VertexAIOAuthCredentials 327L / VertexAITokenRefresher 128L /
VertexAIUsageFetcher 292L) read in full.

## Reviews (project norm)
Gemini 3.1 Pro R1 on the plan → **GO-WITH-CHANGES**, all adopted
(`~/.claude/plans/v1.23.0-phaseB2-vertexai-plan.md`):
- **CRITICAL** — stateless struct + ~30s ticks ⇒ would re-read the
  expired on-disk token and re-hit oauth2.googleapis.com every tick.
  ADOPTED: `actor VertexAITokenCache.shared` holds the last refreshed
  `Creds`; `collect` is cache-first (use if `!needsRefresh`, else load
  disk + refresh + store). Mirrors the `GeminiRefreshBackoff` actor.
- **HIGH** — sandboxed GUI `ProcessInfo.environment` doesn't inherit
  the shell ⇒ `$CLOUDSDK_CONFIG`/`$GOOGLE_APPLICATION_CREDENTIALS`
  nil ⇒ the `realUserHome()/.config/gcloud/...` path is THE path.
  ADOPTED: `realUserHome()` (getpwuid, real `/Users/x`) +
  `SandboxFileAccess.read`; INI read = explicit
  `String(data:encoding:.utf8)`.
- **HIGH** — service-account creds need a sandbox-blocked `gcloud`
  subprocess. ADOPTED: detect `client_email`+`private_key` ⇒ throw a
  clear `.missingCredentials` (run `gcloud auth application-default
  login`). User-cred ADC is the common, sandbox-safe case.
- **MEDIUM** — `isAvailable` sync+frequent ⇒ cheap file-exists, no
  full JSON decode. ADOPTED. `.quota` quota=100/remaining=100−pct,
  reset_time nil (24h rolling window) — confirmed correct.
- **LOW** — descriptor `[.auto,.oauth]`/exactCost:false correct.

## Changes (commit `8963d9b`)
- `Collectors/VertexAICollector.swift` (new, `#if os(macOS)`): ports
  the 3 CodexBar files with the adjustments above. `actor
  VertexAITokenCache`. Static testable surface:
  `parseUserCredentials`, `isServiceAccount`, `parseProjectIdINI`,
  `extractEmailFromIdToken`, `parseRefreshResponse`,
  `parseTimeSeries`, `aggregate`, `maxPercent`.
- `Collectors/ProviderCollector.swift`: `+ VertexAICollector()`.
- `ProviderConfig.swift`: VertexAI descriptor →
  `supportedSources:[.auto,.oauth]`, `supportsExactCost:false`,
  `requiresHelperBackend:false`.
- `Tests/.../VertexAICollectorTests.swift` (new, 10).

## Verification
- `swift build` clean; targeted `swift test --filter` **35/0**
  (VertexAICollectorTests **10/10**; Perplexity +
  ProviderConfigModelTests regression green).
- **All 5 Xcode schemes BUILD SUCCEEDED** (`#if os(macOS)` collector;
  cross-platform descriptor change doesn't break iOS/Watch/Widgets/
  Helper).
- Full local `swift test` not run (documented macOS-26 Keychain hang)
  — CI clean-env matrix authoritative.
- Additive — VertexAI was a silently-skipped stub; localized
  `CollectorError` on failure, no other provider affected. Not
  dark/opt-in (new collector, not a live-path change, unlike G3). No
  backend/schema/ASC/helper.

## Remaining / carried forward
- **Phase B-3: Kiro** — subprocess `kiro-cli whoami` + `chat
  --no-interactive /usage` + ANSI-strip/text-parse (MEDIUM; reuse the
  GeminiStatusProbe subprocess idiom; subprocess ⇒ sandbox-aware /
  likely DEVID-leaning — assess in its plan).
- **DEFERRED (reassess vs Phase C ROI):** OpenCode/OpenCodeGo
  (server-hash fragility), Antigravity/Factory (HIGH scrape). Likely
  do **Phase C** (~17 missing providers, cookie/API cheap post-G1)
  before these. Re-clone CodexBar fresh each time.
- Vertex AI **service-account** support is a possible DEVID-only
  follow-on (needs the gcloud subprocess; out of MAS scope).
- v1.22.1 owes the deferred Decision-A swarm attention-sort
  extraction (on `release/v1.22.1`, not parity scope).
