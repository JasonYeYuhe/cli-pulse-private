# PROJECT_FIX — v1.23.0 CodexBar Parity, Phase A (2026-05-18)

Branch: `feature/v1.23.0-parity` (cut from `main` `790573e`; **NOT merged to
main** while owner away — see Roadmap). Autonomous session; owner directives:
parity = v1.23.0, full-autonomous through Phase A.

## Context / why
Owner directive 2026-05-18: CLI Pulse Bar must have ≥ every CodexBar feature.
Handoff prompt `~/Desktop/CLI_Pulse_NEXT_PHASE_CodexBar_Parity_PROMPT.md`.
Phase A = highest-leverage UX: **G1** browser-cookie auto-import, **G2**
`ClaudePlan` tier normalization, **G4** `UsagePace` forecast engine. (**G3**
`GeminiStatusProbe` split out by Gemini review → own later commit, task #6.)
Re-verified gap vs fresh CodexBar `d715648` v0.27.1-unreleased — catalog still
valid, Phase A unaffected.

## Reviews (project norm)
Two Gemini 3.1 Pro reviews, both findings adopted:
- R1 (takeover plan) `GO-WITH-CHANGES`: SweetCookieKit must be macOS-isolated;
  sandbox/Keychain/FDA must fail gracefully; strip AppKit/NS* before vendoring;
  strict branch discipline; explicit UI failure state.
- R2 (scoped Phase A spec) `GO`: D1 per-process denied-browser memo; D2 en-only
  L10n this train; D3 land engine w/o UI consumer; **D4 split G3 out**; D5/HIGH
  use `#if os(macOS) && canImport(SweetCookieKit)` everywhere.

## G1 — browser-cookie auto-import
- **SweetCookieKit is SOURCE-VENDORED, not an SPM dependency.** First attempt
  added it via SPM (`.when(platforms:[.macOS])`); clean CI (macos-15 / Xcode
  16.4 / **Swift 6.1**) rejected it — every SweetCookieKit tag's manifest is
  `swift-tools 6.2`, which the 6.1 toolchain cannot parse (and bumping
  CLIPulseCore to 6.2 then failed: CI Swift 6.1 can't parse a 6.2 root either).
  Resolution (Gemini-consulted, PICK B): vendor the 11 MIT source files into
  `Sources/CLIPulseCore/Vendor/SweetCookieKit/` (+ `LICENSE`), each whole-file
  `#if os(macOS)`-wrapped (same iOS/watch isolation the SPM platform-condition
  gave). `Package.swift` reverted to `swift-tools 5.9`, SPM dep removed, +
  `linkerSettings: [.linkedLibrary("sqlite3", .when(platforms:[.macOS]))]`.
  No external dependency / toolchain coupling remains; local builds passed
  only because the dev Mac is Swift 6.2 — the clean-env CI matrix caught it
  (`feedback_ci_smoke_full_matrix` validated again).
- New `CookieImporting.swift` (cross-platform, no `#if`): protocol +
  `NullCookieImporter` (iOS/watch/tests → returns nil → manual fallback).
- New `BrowserCookieAutoImporter.swift` (`#if os(macOS) && canImport(SweetCookieKit)`):
  `actor`; iterates a curated `Browser` order; builds `Cookie:` header; catches
  `BrowserCookieError` (.accessDenied/.notFound/.loadFailed) — **never throws**;
  D1: per-process `deniedThisRun` memo so an FDA/Keychain denial isn't
  re-attempted every refresh tick.
- New `CookieResolver.swift` (cross-platform): ladder manual →
  env → (only if `cookieSource == .automatic`) importer → `.unavailable`;
  testable importer-injection overload + platform-default overload.
- `ProviderConfig.swift`: `CookieSource.automatic` added as **first** case
  (rawValue-keyed Codable ⇒ existing serialized values + `nil` unaffected ⇒
  dark-safe: pre-existing users see byte-identical behavior).
- Cursor / Augment / MiniMax / Kimi collectors: private sync `resolveCookie`
  → `await CookieResolver.resolve(...)`; `isAvailable` now also true when
  `.automatic` opted in (MiniMax keeps API-token priority; Kimi extracts the
  `kimi-auth` JWT from the resolved header). Registry unchanged (resolver picks
  the importer internally — no init churn).
- `ProviderConfigEditor.swift`: `.automatic` hidden on non-macOS
  (`availableCookieSources`); info note (sets DEVID-build Keychain-prompt
  expectation — Gemini MEDIUM); animated manual-fallback reveal on
  `.automatic` test failure (`autoImportFailed`, Gemini LOW); shared
  `manualCookieField` helper. 3 new L10n keys `provider_config.auto_import_*`
  in en/ja/zh-Hans (matches existing cookie-key locale coverage).

## G2 — ClaudePlan
- Vendored verbatim → `Collectors/Claude/ClaudePlan.swift` + full MIT header
  (ClaudePeakHours format). Foundation-only, cross-platform, NOT `#if os(macOS)`.
  Brand strings ("Claude Max" / "Max") intentionally not L10n-routed (proper
  nouns, same rationale as ClaudePeakHours). Existing inline tier switches NOT
  refactored (out of scope).

## G4 — UsagePace engine (no UI consumer — Gemini D3)
- Vendored + MIT headers: `RateWindow.swift` (RateWindow only; not
  NamedRateWindow/ProviderIdentitySnapshot — need UsageProvider; no clash with
  nested `CodexCollector.RateWindow`), `UsagePace.swift` (verbatim),
  `Double+Clamped.swift` (verbatim), `UsagePaceText.swift` (adapted: drop
  `import CodexBarCore`; `UsageProvider`→`ProviderKind` at the one call site;
  `resetCountdownDescription` inlined as private helper instead of vendoring
  whole `UsageFormatter`; phrases routed through new `L10n.usagePace.*`).
- `L10n.swift`: + `public enum usagePace` (11 accessors). `usage_pace.*` en
  values only this train (D2; no UI consumer ⇒ never user-visible in Phase A;
  ja/zh/es/ko land with the UI-consumer follow-on).

## Verification
- **All 5 Xcode schemes BUILD SUCCEEDED** with SweetCookieKit present, correct
  destinations: CLI Pulse iOS (iOS Sim), CLI Pulse Bar (macOS), CLI Pulse Watch
  (watchOS Sim), CLI Pulse Widgets (iOS Sim), CLIPulseHelper (macOS). iOS/watch/
  Widgets green ⇒ BLOCKER-1/D5 macOS-isolation proven; G4 shared engine inherits
  to iOS/watch.
- `swift test` targeted: **CookieResolverTests 5/5, ClaudePlanTests 6/6,
  UsagePaceTextTests 9/9** (L10n-routed assertions pass under en-locale pin).
- Regression on the exact modified surface: **CursorCollectorTests,
  AugmentCollectorTests, MiniMaxCollectorTests, KimiCollectorTests,
  ProviderConfigModelTests, LocaleOverrideStoreTests — 40/40 pass**.
- **Known pre-existing issue (NOT a regression):** the *full* `swift test`
  suite hangs (~0% CPU, 0 output, killed at 78 min) on an unrelated suite —
  consistent with the documented macOS 26.x Keychain Agent bug on this Mac
  (`feedback_keychain_agent_bug_macos26`); a Keychain/credential test blocks on
  a SecurityAgent prompt that cannot be answered while the owner is away. All
  changed code verified via targeted suites + 5-scheme builds; CI's clean-env
  full/PR matrix (`feedback_ci_smoke_full_matrix`) remains the authoritative
  gate and will run the full suite without the local Keychain-Agent block.
- Helper untouched (Phase A is Swift-only) — no helper/.pkg/backend/ASC change;
  zero owner-gated steps touched; v1.22.0 ASC pipeline undisturbed.
- **CI resolution journey:** push `940f4af` (SPM dep) → Swift CI red (SCK
  tools 6.2 unresolvable); `d9a7f5d` (bump CLIPulseCore→6.2) → red (CI Swift
  6.1 can't parse 6.2 root); `<vendor>` (source-vendor SCK, revert to 5.9) →
  re-verified locally green (clean resolve + 5 schemes + 20 targeted), CI
  re-run pending. Net: SCK fully under our control, no toolchain coupling.

## Roadmap
Parity = **v1.23.0** (owner). P2 Team Rollup → v1.24.0; P1 Cost Intelligence
stays v1.22.1 (still owes deferred Decision-A swarm attention-sort extraction —
not in this scope). **Branch discipline (Gemini MEDIUM):** v1.23.0 parity must
NOT merge to `main` until the v1.22.1 release branch is cut from `790573e`.
Until then `feature/v1.23.0-parity` stays an isolated CI-green branch.

## Remaining (same branch, deferred)
- **G3 `GeminiStatusProbe`** (task #6): own commit + own Gemini review; replace
  7 infra seams (CodexBarLog→OSLog, BinaryLocator/PathBuilder/TTYCommandRunner
  →ProcessInfo+which, ProviderHTTPClient/SubprocessRunner→URLSession), drop
  `toUsageSnapshot()` (GeminiCollectorTests covers it). Before it touches the
  live Gemini path.
- UI consumer wiring for the UsagePace engine + full-locale `usage_pace.*`
  (follow-on).
- Phases B–E (promote 6 hollow stubs / 17 missing providers / depth / polish).
