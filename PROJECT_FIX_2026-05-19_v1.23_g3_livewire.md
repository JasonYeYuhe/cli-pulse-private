# PROJECT_FIX — v1.23.0 CodexBar Parity, G3 GeminiStatusProbe live-wiring (2026-05-19)

Branch `feature/v1.23.0-g3-livewire` (cut from `main` `06c0e73` = the
G4 PR #44 merge). Follow-on to Phase A (PR #43) + G4 (PR #44). No
overlap — Phase A vendored `GeminiStatusProbe` *standalone* and
explicitly deferred "live-path wiring of the probe into GeminiCollector
(own review)"; verified not already done.

## Context / why
Phase A vendored `GeminiStatusProbe` with no live consumer. Handoff
§3.2: integrate it into the live `GeminiCollector` (own Gemini 3.1 Pro
review; production path ⇒ dark/flagged if behavior-changing). It IS
behavior-changing ⇒ ships dark/opt-in (default OFF), byte-identical
prod until a user explicitly opts a Gemini config in.

The concrete value: `GeminiCollector` cannot refresh file-based
`~/.gemini/oauth_creds.json` tokens (`refreshToken` throws
unconditionally for `.file`; "connect via CLI Pulse OAuth"). The probe
can, via the Gemini CLI's own embedded OAuth client, and is
`settings.json` auth-type aware (rejects apiKey/vertexAI cleanly).

## Reviews (project norm)
Gemini 3.1 Pro R1 on the plan → **GO-WITH-CHANGES**, all adopted
(`~/.claude/plans/v1.23.0-g3-livewire-plan.md`):
- **CRITICAL** — MAS sandbox blocks the probe's subprocess (`which`) +
  fs scans of the global npm/gemini install; bubbling those errors
  would bypass `GeminiRefreshBackoff` ⇒ per-tick log spam. ADOPTED:
  `probeFallbackResult` swallows **every** probe error and returns nil
  ⇒ the pre-existing failure/backoff path runs byte-identically. The
  probe only ever upgrades a credential-gap failure into a success.
- **HIGH** — scale trap: primary `QuotaBucket.remainingFraction` is
  0–1 (`buildResult` ×100); `GeminiModelQuota.percentLeft` is already
  0–100. ADOPTED: `mapSnapshot` consumes `percentLeft` directly, NO
  second ×100; unit test locks percentLeft=85 ⇒ tier 85 (not 8500).
- **MEDIUM** — double-writer: collector's `.file` `persistCredentials`
  is dead code (refresh throws for `.file`), so letting the probe own
  the `~/.gemini/oauth_creds.json` refresh-write is safe. Documented.
- **LOW** — `geminiCliProbeFallback: Bool?` confirmed 100% dark-safe
  (synthesized `encodeIfPresent`/`decodeIfPresent`).
- Q2 ADOPTED: config-only/dark with UI+i18n deferred is acceptable
  (Phase-A-style staging). Q3 ADOPTED: `normalizePlan` maps the
  probe's plan onto `buildResult`'s Paid/Free/Legacy/Unknown so the
  badge doesn't jump when toggling. Q4 ADOPTED: MAS degrades to
  original gracefully; the future UI toggle must hide on sandboxed
  builds.

## Changes (commit `25f7bd9`)
- `ProviderConfig.swift`: + `geminiCliProbeFallback: Bool?` (property
  + `CodingKeys` case + init param default nil). Dark-safe exactly
  like `cookieSource`.
- `GeminiCollector.swift` (`#if os(macOS)`): primary path 100%
  unchanged. New private `probeFallbackResult(config:)` — guards
  `geminiCliProbeFallback == true` (else returns nil before the probe
  is even constructed ⇒ dark), `do { GeminiStatusProbe(homeDirectory:
  realUserHome()).fetch() → mapSnapshot } catch { nil }` (swallow
  all). Wired at the two credential-gap throw sites only (no-creds;
  expired/unrefreshable token) — never on transient network errors.
  `mapSnapshot` mirrors `buildResult`'s ProviderUsage shape from
  `snap.modelQuotas` (instance method ⇒ reuses instance
  `classifyModel`, primary path untouched). `normalizePlan` →
  Paid/Free/Legacy/Unknown.
- `GeminiProbeFallbackTests.swift` (8): double-scale lock, lowest-per-
  family, primary-family fallback, clamp, ISO round-trip,
  resetDescription fallback, plan vocabulary, dark-safe Codable.

## Verification
- `swift build` clean; targeted `swift test --filter` →
  **68/0** (GeminiProbeFallbackTests **8/8**; primary
  GeminiCollectorTests **untouched-green**; GeminiStatusProbe{,API,
  Plan}Tests green; ProviderConfigModelTests green).
- **All 5 Xcode schemes BUILD SUCCEEDED** (macOS, iOS, Watch,
  Widgets, CLIPulseHelper) — CLIPulseCore change does not break any
  platform.
- Full local `swift test` not run (documented macOS-26 Keychain hang,
  `feedback_keychain_agent_bug_macos26`) — CI clean-env full matrix
  is authoritative.
- No backend/schema/ASC/helper change. Dark guarantee: opt-in
  absent/false ⇒ `GeminiStatusProbe` never constructed ⇒ zero new
  network/fs/subprocess activity ⇒ prod byte-identical.

## Remaining / carried forward
- G3 follow-on: UI opt-in toggle in `ProviderConfigEditor` (macOS +
  iOS) + L10n; **must hide/disable on sandboxed/MAS builds** (Gemini
  R1 Q4). Probe value is DEVID-only in practice (MAS sandbox blocks
  its package discovery) — surface that in the UI copy.
- CodexBar Phases B–E (handoff §3): B = 6 hollow stubs → real
  collectors; C = ~17 missing providers; D = depth; E = CLI/widgets/
  polish. Re-clone CodexBar fresh (`reference_codexbar_upstream`).
- v1.22.1 owes the deferred Decision-A swarm attention-sort
  extraction (on `release/v1.22.1`, not parity scope).
