# PROJECT_FIX — v1.23.0 CodexBar Parity, G4 UI Consumer + i18n (2026-05-19)

Branch `feature/v1.23.0-g4-pace-ui` (cut from `main` `46956d1` = PR #43
Phase A merge). PR #44 → `main`. Follow-on to
`PROJECT_FIX_2026-05-18_v1.23_codexbar_parity_phaseA.md` (no overlap —
Phase A explicitly deferred "UsagePace UI consumer + full-locale
usage_pace.*"; verified not already done before starting).

## Context / why
Phase A vendored the `UsagePace`/`UsagePaceText` forecast engine into
CLIPulseCore but deliberately wired no UI consumer (Gemini Phase-A D3)
and shipped `usage_pace.*` en-only (D2). Handoff §3.1 = next parity
work: make the engine visible on Mac + iOS and finish localization.

## §2 merge gate (resolved first, owner-approved "recommended order")
- `git branch release/v1.22.1 790573e` + pushed (P1 Cost-Intelligence
  train point protected).
- PR #43 (Phase A) un-drafted → full 5-scheme CI green on `533dc45` →
  **merged to `main`** (merge commit `46956d1`); post-merge `main`
  full matrix green. v1.23.0 parity is now the `main` line.
- ASC re-checked read-only (owner asked): iOS 1.22.0 b63 PASSED review
  (Ready for Distribution; release owner-gated, untouched); macOS b63
  still Waiting for Review. Recorded in `project_v1_22_0_progress`.

## Reviews (project norm)
Gemini 3.1 Pro R1 on the plan → **GO-WITH-CHANGES**, all 4 adopted
(plan+review archived at `~/.claude/plans/v1.23.0-g4-ui-consumer-plan.md`):
- HIGH — `UsagePaceText.durationText` did `countdown.dropFirst(3)` after
  concatenating `"in "`; a latent string-corruption bug if the formatter
  ever changed. Replaced `durationText`+`resetCountdownDescription` with
  one strongly-typed `compactCountdown(seconds:) -> String?` (nil ⇒ the
  `*Now` phrase). Rendered L10n output byte-identical.
- MEDIUM — anchorless window ⇒ unstable `expectedUsedPercent`. The
  bridge now returns nil unless `reset_time` parses to a *future* Date.
- MEDIUM — verbose menu label risks notch truncation → ultra-compact
  `▲<d>%`/`▼<d>%`/`≈` from stage+deltaPercent (no new L10n).
- CRITICAL — conditional card row → grid misalignment. Verified the
  actual layout: macOS providers list is a vertical `ScrollView`/`VStack`
  (no equal-height grid); iOS iPad path is a 2-col `LazyVGrid` that has
  *already* rendered a provider-conditional footer (`ClaudePeakFooter`,
  Claude-only) since v1.18.2 — ragged rows are an established shipped
  design. The pace row matches that accepted pattern; no new
  misalignment class, and over-equalizing would diverge from the rest
  of the card. Documented, not over-engineered.

## Changes

### Commit 1 `1094a06` — CLIPulseCore seam
- `UsagePaceText.swift`: `enum`+`WeeklyDetail`(+public init)+`weekly*`/
  `session*` statics internal→**public** (Phase A kept internal, D3).
  HIGH refactor as above. Header divergence note updated.
- `ProviderUsage+Pace.swift` (new, cross-platform, no `#if os(macOS)`):
  `paceRateWindow` (usagePercent 0…1 ×100 → RateWindow 0…100;
  `reset_time` via shared `sharedISO8601Parse`, future-anchor guard),
  `paceSummary`, `paceDetail`, `paceMenuLabel`.
- `ProviderUsagePaceTests` (new, 8): scale, anchor guard
  (nil/non-ISO8601/past), provider gating, seam equivalence. en-locale
  pinned via `LocaleOverrideStore` (mirrors UsagePaceTextTests).

### Commit 2 `d230c99` — Mac menu-bar + Mac/iOS cards
- `AppState.menuBarLabel` `.pace`: shallow `"%.0f%%"` → compact engine
  label, `%` fallback when no verdict (non-Codex/Claude or no anchor) ⇒
  unchanged for those. `.pace` opt-in (default `.icon`), dark-safe.
- `ProvidersTab.swift` `EnhancedProviderCard` + `iOSProvidersTab.swift`
  `iOSEnhancedProviderCard`: optional one-line `paceSummary` row next
  to the existing `ClaudePeakFooter`, same conditional-footer pattern.

### Commit 3 `85d5973` — i18n
- 11 `usage_pace.*` keys translated into ja / zh-Hans / es / ko (en
  was the only locale from Phase A). zh-Hans uses the project's
  fullwidth-colon convention; `·`/`≈` preserved. Compact duration unit
  letters (3d/2h) stay English (Gemini R1 Q4 — defer 5-locale duration
  pluralization; CodexBar-identical, language-neutral).

## Verification
- `swift test --filter 'UsagePaceTextTests|ProviderUsagePaceTests'`:
  **UsagePaceTextTests 9/9** (unchanged ⇒ refactor behavior-preserving)
  **+ ProviderUsagePaceTests 8/8**.
- **All 5 Xcode schemes BUILD SUCCEEDED** locally: CLI Pulse Bar
  (macOS), CLI Pulse iOS, CLI Pulse Watch, CLI Pulse Widgets,
  CLIPulseHelper. CLIPulseCore `swift build` clean.
- i18n: `plutil -lint` OK for en/ja/zh-Hans/es/ko; `%@`+`%%`
  format-spec counts match en exactly for all 11 keys.
- Full local `swift test` NOT run (documented macOS-26 Keychain-Agent
  hang, `feedback_keychain_agent_bug_macos26`) — CI clean-env full
  matrix is the authoritative gate.
- No helper/.pkg/backend/schema/ASC change; v1.22.0 ASC pipeline
  untouched. Engine gated to Codex/Claude ⇒ universal nil fallback.
- CI: PR #44 full 9-job matrix (link in PR); `SwiftLint (warning-only)`
  remains the known non-blocking baseline (not a gate).

## Remaining (next parity sessions, unchanged from Phase A handoff §3)
- G3 live-path wiring: integrate the vendored `GeminiStatusProbe` into
  the live `GeminiCollector` (own Gemini review; dark/flagged if
  behavior-changing).
- CodexBar Phases B–E: promote the 6 hollow stubs (B); ~17 missing
  providers (C); depth parity (D); CLI/widgets/polish (E). Re-clone
  CodexBar fresh per `reference_codexbar_upstream`.
- v1.22.1 still owes the deferred Decision-A swarm attention-sort
  extraction (on `release/v1.22.1`, not parity scope).
