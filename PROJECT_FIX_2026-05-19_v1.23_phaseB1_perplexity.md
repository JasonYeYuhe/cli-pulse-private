# PROJECT_FIX — v1.23.0 CodexBar Phase B-1: Perplexity collector (2026-05-19)

Branch `feature/v1.23.0-phaseB-perplexity` (cut from `main` `0cc3eea`
= G3-UI PR #46 merge). First increment of Phase B (promote the 6
hollow "requires-helper" stubs). No overlap with G1–G4.

## Context / why
Handoff §3 Phase B = promote 6 stubs (openCode, droid/Factory,
antigravity, kiro, vertexAI, perplexity) to real collectors. CodexBar
re-cloned fresh `/tmp/codexbar-latest` @ `7e97d2b` (still
0.27.1-Unreleased; catalog valid). Two read-only Explore agents mapped
both sides.

**Key scoping conclusion: the 6 are heterogeneous.** Per-provider
port complexity (CodexBar source survey): Perplexity LOW (1 endpoint,
session cookie); VertexAI/Kiro MEDIUM; OpenCode/OpenCodeGo MEDIUM but
**HIGH fragility** (hardcoded server-function hashes break on site
deploys); Antigravity/Factory HIGH (OAuth-creds scraped from Electron
app JS / 8 credential paths + raw LevelDB binary scan + SQLite).
⇒ fragility-ascending increments, NOT all 6 at once.

## Reviews (project norm)
Gemini 3.1 Pro R1 on the plan → **GO-WITH-CHANGES**, strategy
validated ("excellent risk call"), all adopted
(`~/.claude/plans/v1.23.0-phaseB-plan.md`):
- **CRITICAL** — pass `knownSessionCookieNames`
  `["__Secure-next-auth.session-token","next-auth.session-token"]` to
  `CookieResolver.resolve` or it may return `__cf_bm`/analytics
  cookies ⇒ 401. ADOPTED.
- **MEDIUM** — port CodexBar's `PerplexityUsageSnapshot` waterfall
  attribution (recurring→purchased→promotional) verbatim, not bespoke
  mapping. ADOPTED.
- **MEDIUM** — descriptor `supportedSources` `[.auto,.api]` →
  `[.auto,.web]` so the auth UI asks for a session cookie, not an
  API key. ADOPTED.
- **LOW/Q2** — `dataKind: .credits` (monetary balance, OpenRouter-
  like) + match OpenRouter's $1 = 100_000-unit scale so the UI
  formats consistently. ADOPTED.
- Q5 — adding a collector where none existed is regression-safe
  (localized `CollectorError`; `requiresHelperBackend` is
  metadata-only/inert). Confirmed.
- Strategy Q1 — defer OpenCode*/Antigravity/Factory indefinitely;
  spend the effort on Phase C's cheaper, stabler providers. ADOPTED.

## Changes (commit `f46e760`)
- `Collectors/PerplexityCollector.swift` (new, `#if os(macOS)`, MIT
  header / ClaudePlan format): mirrors `CursorCollector`. Vendored
  verbatim — the Codable `PerplexityCreditsResponse` (snake_case) +
  the waterfall attribution + plan inference; `UsageSnapshot`/
  `RateWindow` (CodexBar types) NOT vendored — mapped to
  `ProviderUsage` `.credits`, OpenRouter unit scale.
- `Collectors/ProviderCollector.swift`: `+ PerplexityCollector()` in
  `CollectorRegistry.collectors`.
- `ProviderConfig.swift`: Perplexity descriptor →
  `supportedSources:[.auto,.web]`, `supportsExactCost:true`,
  `requiresHelperBackend:false`.
- `Tests/.../PerplexityCollectorTests.swift` (new, 8): decode,
  invalid-throws, waterfall, purchased max(field,grants),
  expired-promo filter, plan inference, `.credits` scale,
  `isAvailable` matrix.

## Verification
- `swift build` clean; targeted `swift test --filter` **32/0**
  (PerplexityCollectorTests **8/8**; Augment/Cursor +
  ProviderConfigModelTests regression green — no other collector
  touched, descriptor change safe).
- **All 5 Xcode schemes BUILD SUCCEEDED** (PerplexityCollector is
  `#if os(macOS)`; the cross-platform descriptor change doesn't break
  iOS/Watch/Widgets/Helper).
- Full local `swift test` not run (documented macOS-26 Keychain hang)
  — CI clean-env matrix is authoritative.
- No backend/schema/ASC/helper change. Dark-safe: previously the stub
  produced no data (silently skipped); now a localized collector —
  failures throw `CollectorError`, handled gracefully; no other
  provider affected.

## Remaining / carried forward
- **Phase B-2: VertexAI** (gcloud ADC file + token refresh + 2
  Cloud-Monitoring GETs — MEDIUM, low fragility, reuses
  CodexCollector file idiom). Then **B-3: Kiro** (subprocess
  `kiro-cli` + text parse — MEDIUM; GeminiStatusProbe subprocess
  idiom). Each its own PR + Gemini review.
- **DEFERRED (reassess vs Phase C ROI):** OpenCode/OpenCodeGo
  (server-hash fragility), Antigravity/Factory (HIGH scrape
  fragility). Likely better to do Phase C's ~17 cheaper cookie/API
  providers first.
- v1.22.1 owes the deferred Decision-A swarm attention-sort
  extraction (on `release/v1.22.1`, not parity scope).
