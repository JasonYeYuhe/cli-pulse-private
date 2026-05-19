# PROJECT_FIX — v1.23.0 CodexBar Phase C-1: Crof collector + B-3 Kiro pivot (2026-05-20)

Branch `feature/v1.23.0-phaseC-crof` (cut from `main` `2da3a94` =
Phase B-2 PR #48 merge). First **Phase C** provider. No overlap with
G1–G4 / B-1 / B-2.

## Context — the B-3 → Phase C pivot (autonomous, Gemini-validated)
After B-2 (VertexAI) merged, the documented next was B-3 Kiro. Scoping
CodexBar's `KiroStatusProbe` showed it is **pure `Process()`
subprocess** (`kiro-cli`) → App-Sandbox-blocked in MAS → **DEVID-only,
narrow reach**, MEDIUM effort (864L). Same narrow/fragile profile that
deferred OpenCode*/Antigravity/Factory. Per the Gemini-validated B-1
principle ("spend effort on Phase C's broad, stabler providers"),
**deferred Kiro; pivoted to Phase C** (broad, sandbox-safe). An
Explore survey of fresh CodexBar (`7e97d2b`) ranked the cheapest
sandbox-safe LOW ports: **Crof #1** → DeepSeek → ElevenLabs → Venice.
All ~17 Phase-C providers are ABSENT (need NEW `ProviderKind` cases).
Skip Grok/Windsurf (FS-scan, not sandbox-safe).

## Reviews (project norm)
Gemini 3.1 Pro R1 on the Crof plan → **VERDICT: GO** (only LOW/MEDIUM
advisories), all adopted (`~/.claude/plans/v1.23.0-phaseC1-crof-plan.md`):
- **MEDIUM** — inject `now` into `buildResult`/`nextRequestReset` (not
  a deep `Date()`) so the Chicago-midnight reset is deterministically
  testable. ADOPTED.
- **LOW** — adding `.crof` + the single `iconName` arm is sufficient
  (the 5-scheme build is the authoritative exhaustiveness gate);
  `.quota` correct (uncapped credit balance → status_text, not a
  synthetic %); descriptor `[.auto,.api]`+supportsCredits correct;
  CaseIterable/`defaults()` auto-includes Crof = intended and inert
  until an API key is set; `Double→Int` truncation safe.

## New-`ProviderKind`-case audit (the cross-scheme compile risk)
- `Models.swift:84 defaultCostRate` — has `default:` ⇒ safe.
- `Models.swift:105 iconName` — exhaustive, **NO default** ⇒ added
  `case .crof: return "c.circle"`.
- `Components.providerColor`, `iOSSettingsTab.providerLabel`,
  `iOSAlertsTab.sourceKindIcon` — switch over **String** w/ default
  ⇒ safe (descriptor/registry is string-keyed).
- **All 5 Xcode schemes BUILD SUCCEEDED** ⇒ no missed exhaustive
  ProviderKind switch anywhere.

## Changes (commit `afdf31a`)
- `Models.swift`: `+ case crof = "Crof"`; `iconName` `.crof` arm.
- `Components.swift`: Crof brand color (cosmetic, String switch).
- `ProviderConfig.swift`: `.crof` `ProviderDescriptor`
  (`[.auto,.api]`, supportsQuota, supportsCredits,
  requiresHelperBackend:false, cliNames `["crof"]`, crof.ai).
- `Collectors/CrofCollector.swift` (new, `#if os(macOS)`, MIT
  header): ZaiCollector api-key idiom; `GET
  https://crof.ai/usage_api/` Bearer; vendored Codable
  `CrofUsageResponse` (snake_case) + `nextRequestReset`
  (next America/Chicago midnight, DST-safe via `Calendar`,
  injectable `now`). `.quota`: quota=requestsPlan,
  remaining=usableRequests (clamped 0…plan), reset=ISO(nextReset),
  credit balance → status_text. Registered in CollectorRegistry.
- `Tests/.../CrofCollectorTests.swift` (new, 8).

## Verification
- `swift build` clean; targeted `swift test --filter` **29/0**
  (CrofCollectorTests **8/8**; Zai + ProviderConfigModelTests
  regression green).
- **All 5 Xcode schemes BUILD SUCCEEDED** (the authoritative
  new-enum-case exhaustiveness gate).
- Full local `swift test` not run (documented macOS-26 Keychain
  hang) — CI clean-env matrix authoritative.
- Additive new provider; isAvailable-gated on api-key presence ⇒
  inert until configured. No backend/schema/ASC/helper. Not
  dark/opt-in (new collector, like Perplexity/VertexAI).

## Remaining / carried forward
- **Phase C-2: DeepSeek** (api-key Bearer, single `GET
  api.deepseek.com/user/balance`, string-encoded Double balances —
  LOW). Then C-3 ElevenLabs (`xi-api-key` header, single endpoint),
  C-4 Venice (Bearer, flexible-Double balance). Each NEW
  `ProviderKind` case ⇒ same iconName-arm + 5-scheme exhaustiveness
  discipline.
- **DEFERRED:** Kiro (subprocess/DEVID), OpenCode/OpenCodeGo
  (server-hash fragility), Antigravity/Factory (HIGH scrape),
  Grok/Windsurf (not sandbox-safe). Re-clone CodexBar fresh each
  time (`reference_codexbar_upstream`; HEAD moves).
- v1.22.1 owes the deferred Decision-A swarm attention-sort
  extraction (on `release/v1.22.1`, not parity scope).
