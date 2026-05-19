# PROJECT_FIX — v1.23.0 CodexBar Parity, G3 UI/i18n follow-on (2026-05-19)

Branch `feature/v1.23.0-g3-ui` (cut from `main` `cca641d` = G3 PR #45
merge). Follow-on to G3 (PR #45). No overlap — PR #45 explicitly
deferred the UI/i18n; verified not already done.

## Context / why
G3 (PR #45) shipped the `geminiCliProbeFallback` opt-in **dark** —
reachable only by hand-editing the persisted config. This makes it a
real toggle in `ProviderConfigEditor` so users can actually enable it,
with the Gemini-mandated MAS-hide.

## Reviews (project norm)
Gemini 3.1 Pro R1 on the plan → **GO-WITH-CHANGES**, all adopted
(`~/.claude/plans/v1.23.0-g3-ui-plan.md`):
- **CRITICAL** — `save()` is cross-platform but the toggle's `@State`
  is macOS-only ⇒ the new `save()` assignment MUST be
  `#if os(macOS)`-wrapped or iOS/watch fails to compile
  (feedback_ci_smoke_full_matrix class). ADOPTED + verified by the
  iOS scheme build.
- **HIGH** — saving nil-when-off (and for non-Gemini) is correct &
  necessary: `ProviderConfig` optionals encode with `encodeIfPresent`
  ⇒ key omitted ⇒ byte-identical to legacy configs. Confirmed.
- **LOW** — `NSHomeDirectory().contains("/Library/Containers/")`
  sandbox gate accepted (codebase-consistent, cf.
  ClaudeSourceStrategy.swift:235).
- Q1 → en/ja/zh-Hans (match the existing provider_config editor
  coverage; es/ko fall back to en like the rest of that section).
  Q3 → keep the nil-collapse (do NOT mirror cookieSource's direct
  save which would emit `false`). Q4 → toggle inside
  `geminiOAuthSection`; the cosmetic rename to `geminiMacSection` was
  SKIPPED (minimal diff on a shared editor).

## Changes (commit `50b10a3`)
- `ProviderConfigEditor.swift` (shared editor; all additions
  macOS-gated): `@State geminiCliProbeFallback`; `isAppSandboxed`
  computed; Toggle + caption note inside `geminiOAuthSection`
  rendered only `if !isAppSandboxed`; load in the existing macOS
  `if kind == .gemini` block; `save()` writes
  `(kind == .gemini && geminiCliProbeFallback) ? true : nil` inside a
  new `#if os(macOS)` guard.
- `L10n.swift`: + `providerConfig.geminiCliFallback` /
  `.geminiCliFallbackNote`.
- i18n: `provider_config.gemini_cli_fallback` + `_note` → en/ja/
  zh-Hans (no format specifiers).

## Verification
- plutil-lint en/ja/zh-Hans **OK**; both new keys present ×3 locales.
- `swift build` clean; targeted `swift test` **25/0**
  (ProviderConfigModelTests 17 + GeminiProbeFallbackTests 8 —
  unchanged-green; this change has no logic, only UI/strings).
- **All 5 Xcode schemes BUILD SUCCEEDED** (macOS = new path compiles;
  **iOS = the Gemini CRITICAL** macOS-only-state compile-out;
  Watch/Widgets/Helper green).
- No collector/probe/backend/schema/ASC change. Dark-safe: default
  off; save writes nil when off ⇒ existing configs byte-identical;
  macOS-only + sandbox-hidden ⇒ no dead toggle on MAS.

## Remaining / carried forward
- CodexBar Phases B–E (handoff §3): B = 6 hollow stubs → real
  collectors; C = ~17 missing providers; D = depth; E =
  CLI/widgets/polish. Re-clone CodexBar fresh
  (`reference_codexbar_upstream`; HEAD moves).
- v1.22.1 owes the deferred Decision-A swarm attention-sort
  extraction (on `release/v1.22.1`, not parity scope).
- G3 is now feature-complete (probe wiring + reachable opt-in);
  the probe's value remains DEVID-only by design (MAS sandbox).
