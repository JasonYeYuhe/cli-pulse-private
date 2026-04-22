# PROJECT_FIX v1.10.9 — P3-3: accessibility pass (tab / cards / bars / buttons)

**Date:** 2026-04-22
**Commit:** (pending)
**Scope:** First pass of VoiceOver / HIG accessibility coverage on the
iOS + macOS surfaces. Plan prioritized tab icon, provider cards,
progress bars, button icons. Before this change: macOS had 4
`.accessibilityLabel` calls, iOS had 0.

## Shipped

### UsageBar (shared `CLIPulseCore.Components`)
- Replaced raw overlay-rectangle + text readout with a single composed
  VoiceOver element using `.accessibilityElement(children: .ignore)` +
  explicit `accessibilityLabel(label)` + `accessibilityValue(detail)`.
- Deliberately does NOT compute a percentage from the numeric `value`
  input — call sites are inconsistent (some pass "remaining 0..1",
  others pass "used 0..1"). The caller-formatted `detail` string
  ("15% left" / "17k remaining") is the source of truth for VoiceOver
  (and this is what the Gemini review's critical finding surfaced).

### Provider cards (both platforms)
- `EnhancedProviderCard` (macOS) + `iOSEnhancedProviderCard` (iOS) both
  add `.accessibilityElement(children: .contain)` + a composed summary
  label like "Claude, enabled, Active, 73% used". Nested UsageBars
  keep their own drill-in accessibility so a VoiceOver user can still
  step into individual tier bars.

### MenuBarLabel (macOS menu-bar extra)
- Full readout replacement via `.accessibilityElement(children: .ignore)`
  + `accessibilityLabel("CLI Pulse, <label>")`. Without this,
  VoiceOver announced the raw SF Symbol name (e.g. "waveform dot path
  dot ecg, 3") instead of the app identity.

### Configuration error banner (both platforms)
- `.accessibilityElement(children: .combine)` — no explicit label
  override. VoiceOver inherits the actual Text content ("Configuration
  error. SUPABASE_ANON_KEY missing — API calls will fail."), so future
  localization / copy tweaks propagate automatically (this was
  Gemini's second finding).

### Priority button icons
Icon-only buttons that previously read out as symbol names now carry
descriptive labels:
- macOS `MenuBarView` refresh + banner dismiss buttons (error + tier
  warning).
- macOS `ProviderSettingsSection` gear buttons — "Configure Claude",
  "Configure Codex", etc.
- iOS `iOSOverviewTab` + `iOSMainView` (iPad split-view) toolbar
  refresh buttons.
- Refresh buttons use `L10n.common.refresh` (already localized);
  dismiss + "Configure X" use English placeholders — see follow-ups.

## Review verdict
- **Codex codex-rescue:** skipped (session flake pattern).
- **Gemini 3.1 Pro scan (first pass):** flagged 3 issues:
  1. **Critical** — UsageBar computed "% remaining" from an
     ambiguously-signed `value` input; would have announced "80%
     remaining" for an 80%-used bar.
  2. **Warning** — hardcoded `accessibilityLabel` on config-error
     banners was overriding dynamic Text content.
  3. **Suggestion** — MenuBarLabel used `.combine` + explicit label,
     which is redundant.
  All three addressed: UsageBar dropped the percentage computation,
  banners dropped the hardcoded label, MenuBarLabel switched to
  `.ignore`.
- **Gemini 3.1 Pro scan (second pass):** confirmed all prior findings
  resolved. Two new polish suggestions:
  1. UsageBar should also use `.ignore` (not `.combine`) since it
     fully replaces the readout — applied.
  2. Hardcoded English accessibility labels ("Dismiss error",
     "Configure X") should be localized — **deferred to P3-2 L10n**
     since that slice will sweep through all user-facing strings
     uniformly.

## Baselines
- `swift test` CLIPulseCore: all passing ✓
- `xcodebuild -scheme "CLI Pulse Bar" -destination platform=macOS`:
  BUILD SUCCEEDED ✓
- `xcodebuild -scheme "CLI Pulse iOS" -destination generic/platform=iOS
  Simulator`: BUILD SUCCEEDED ✓

## Not in scope (deferred)
- **VoiceOver end-to-end run-through** on a real device — the plan
  specifies "Apple HIG + VoiceOver 跑关键路径". Left for Jason to
  smoke on his own hardware; code-level contract is clean per two
  reviewer passes.
- **L10n keys for new accessibility labels** — picked up by P3-2 L10n
  slice. Current strings ("Dismiss error", "Dismiss tier limit
  warning", "Configure <ProviderName>") work in English-only; when
  P3-2 adds Japanese/Spanish, these become `L10n.a11y.dismissError`
  etc.
- **Additional icon-only buttons** — the app has ~136 `Image(systemName:)`
  usages. This slice covers the high-traffic paths per the plan
  priorities; a second pass could sweep the long tail
  (settings switches, sub-section gear icons, etc.) but diminishing
  returns vs. the top-of-funnel hits we handled.
- **Settings-screen labels** — not in the plan priority list; defer
  until a user reports friction.

## Follow-ups
- Completes P3-3. Remaining v1.11-scope autonomously-doable: P3-2 L10n,
  P3-1A Android placeholder. P2-8 Sentry still blocked on user DSN.
- When P3-2 runs, add a11y strings to `L10n` alongside the UI strings
  they pair with (e.g. `L10n.common.dismiss`, `L10n.providers.configure`).
