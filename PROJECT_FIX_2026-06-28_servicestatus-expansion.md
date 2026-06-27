# PROJECT FIX — Expand ServiceStatus to 12 providers (live-verified) (DEV_PLAN §5)

**Date:** 2026-06-28
**Train:** Post-trust-hardening quality follow-on (DEV_PLAN §5 "ServiceStatus expansion 5→12+")
**Branch:** `feat/servicestatus-expand-providers`

---

## Summary

Added 7 providers (→ 12 total) to `ServiceStatusCatalog`, reusing the existing,
already-tested Atlassian Statuspage v2 parser. Every new endpoint was **fetched
live and verified** before adding it, so a reviewer/user sees a correct status
badge and never a silently-broken one.

## Why this is functionally safe (verified, not assumed)

Per the "保证功能不出问题 / 查清楚" directive, every claim below was checked
against the live endpoints + the actual code:

1. **Each new host serves a valid Atlassian Statuspage v2 `/api/v2/status.json`.**
   Fetched live 2026-06-28; each returns `status.indicator` + `status.description`
   + `page.updated_at` — exactly the fields `parseStatuspageStatus` reads:

   | ProviderKind | host | live result (2026-06-28) |
   |---|---|---|
   | `.elevenLabs` | status.elevenlabs.io | 200, indicator `none`, "All Systems Operational" |
   | `.groq` | groqstatus.com | 200, `none` |
   | `.warp` | status.warp.dev | 200, `none` |
   | `.moonshot` | status.moonshot.cn | 200, `none` |
   | `.deepgram` | status.deepgram.com | 200, `none` |
   | `.windsurf` | status.codeium.com | 200, `none` |
   | `.augment` | status.augmentcode.com | 200, `none` |

   Candidates that are NOT Atlassian v2 were **rejected**: perplexity (404 / HTML),
   openRouter (404), deepseek (no response), mistral (HTML), grok/x.ai (403).

2. **The indicator maps correctly** — `ServiceStatusIndicator(statuspageIndicator: "none")
   == .operational` (ServiceStatus.swift:34), so operational providers show NO
   badge (`shouldSurface == false`), i.e. **no visual change** in the common case.
   A badge only appears on a real incident/maintenance — the whole point.

3. **Zero behavioral fan-out.** `supportedProviders` has NO production consumers
   (grep: catalog/tests only). `ServiceStatusBadge` is already rendered for every
   provider in ProvidersTab and returns nil immediately for unmapped ones; the 7
   now fetch their real status instead (lazy, per-badge `.task`, 10s timeout,
   graceful nil on any failure). No new global polling, no thundering herd.

4. **Non-exhaustive switch** — adding cases can't break any other provider; the
   parser and fetcher are unchanged.

## What changed

- **`ServiceStatus.swift`** — 7 new cases in `statusPageHost(for:)` + the 7 added
  to `supportedProviders`. No parser/fetcher change.
- **`ServiceStatusTests.swift`** — `testCatalogEndpointsForExpandedProviders`
  (pins all 7 endpoint URLs so a typo fails CI) + `testParsesExpandedProviderRealResponse`
  (a verbatim live `status.moonshot.cn` body, incl. the `+08:00` numeric-offset
  timestamp some new providers use, parses to a correct snapshot).

## Verification

- [x] All 7 endpoints fetched live + schema-checked (table above).
- [x] Indicator/​surface behavior confirmed against the code (no badge when operational).
- [x] `supportedProviders` has no fan-out consumers (grep).
- [x] `ServiceStatusTests` 16, 0 failures; **full `swift test` green — 1786 tests, 0 failures**.
- [ ] CI green.

## Notes

- The `webDomain` "Open dashboard" affordance (DEV_PLAN §5) was deliberately NOT
  done here: its only home is app-target SwiftUI (CI-only, not locally verifiable),
  so it can't meet the same functional-safety bar in a CLIPulseCore-testable PR.
  Deferred until it can be done with a testable URL-builder seam + on-device check.
- Status pages can move; the pinned-URL test + graceful-nil fetch mean a future
  move degrades to "no badge", never a crash.
