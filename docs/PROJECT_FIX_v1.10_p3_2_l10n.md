# PROJECT_FIX v1.10.10 — P3-2: L10n parity fix + a11y/config strings localized

**Date:** 2026-04-22
**Commit:** (pending)
**Scope:** Fix locale parity and retroactively localize the English strings
introduced by P3-3 (accessibility) + P3-6 (config self-check) slices
earlier in this session. Plan's original "iOS 0 NSLocalizedString" claim
was outdated — CLIPulseCore's L10n abstraction already covers both iOS
and macOS. What actually needed doing: close drift + sweep new hardcoded
strings.

## Shipped

### Parity fix — 4 missing `subscription.*` keys in ja/es/ko
Pre-slice audit: en + zh-Hans had 348 lines each; ja/es/ko had 344. Diff
showed the same 4 keys missing across all 3:
- `subscription.free`
- `subscription.free_description`
- `subscription.pro_description`
- `subscription.team_description`

Added with natural translations alongside the existing `subscription.pro`
/ `subscription.team` entries in each file.

### New `L10n.a11y` namespace (CLIPulseCore/L10n.swift)
5 new keys:
- `dismissError` (static) → `"a11y.dismiss_error"`
- `dismissTierWarning` (static) → `"a11y.dismiss_tier_warning"`
- `configureProvider(_ name: String)` (format fn, `%@`)
  → `"a11y.configure_provider"`
- `configurationErrorTitle` (static) → `"a11y.configuration_error_title"`
- `configurationErrorBody` (static) → `"a11y.configuration_error_body"`

Added to all 5 locale bundles (en / ja / es / ko / zh-Hans) with
faithful translations — e.g.:
- en: "SUPABASE_ANON_KEY missing — API calls will fail."
- ja: "SUPABASE_ANON_KEY が未設定です。API 呼び出しは失敗します。"
- es: "Falta SUPABASE_ANON_KEY — las llamadas a la API fallarán."
- ko: "SUPABASE_ANON_KEY 누락 — API 호출이 실패합니다."
- zh-Hans: "缺少 SUPABASE_ANON_KEY — API 调用将失败。"

### View wiring — 5 hardcoded English strings now localized
- `MenuBarView.swift` — error banner dismiss accessibility label
  (`L10n.a11y.dismissError`)
- `MenuBarView.swift` — tier-limit banner dismiss accessibility label
  (`L10n.a11y.dismissTierWarning`)
- `MenuBarView.swift` — configuration error banner Text (title + body)
  (`L10n.a11y.configurationErrorTitle` / `configurationErrorBody`)
- `ProviderSettingsSection.swift` — gear button accessibility label
  (`L10n.a11y.configureProvider(name)`)
- `iOSMainView.swift` — configuration error banner Text (title + body)

Before this: 3 a11y labels + 2 banner body strings were hardcoded
English (called out as follow-ups in the P3-3 + P3-6 archives). Now all
route through L10n.

### Final locale key counts
All 5 locales: **304 keys each** (was 348 in en/zh-Hans vs 344 in
ja/es/ko before; +5 new keys brings everyone to 349 on the raw line
count, 304 on deduped key count).

## Review verdict
- **Codex codex-rescue:** skipped (session flake pattern).
- **Gemini 3.1 Pro scan:** 4 "critical" findings that turned out to be
  **false positives** — it claimed `configure_provider` used `% @`
  (space-separated) in 4 locales. Byte-level verification (`od -c`)
  and `grep -l "% @"` both confirm zero files contain a space-separated
  specifier. The actual bytes in every locale are `% @` → wait, no —
  the actual bytes are literally `%` immediately followed by `@`, no
  space. macOS + iOS builds also pass (if the format string were
  malformed at the source level, the Swift `String(format:)` call
  wouldn't substitute correctly, though it's runtime not compile-time).
  Proceeded to ship.
  Gemini's other conclusions (view routing + subscription parity
  correct) were accurate.

## Baselines
- `swift test` CLIPulseCore: all passing ✓
- `xcodebuild -scheme "CLI Pulse Bar" -destination platform=macOS`:
  BUILD SUCCEEDED ✓
- `xcodebuild -scheme "CLI Pulse iOS" -destination generic/platform=iOS
  Simulator`: BUILD SUCCEEDED ✓
- Locale key count parity: 5/5 locales = 304 deduped keys ✓

## Why this matters
- The 4 missing subscription keys silently drifted. Japanese / Spanish
  / Korean Pro-tier users would have seen empty or fallback-English
  plan descriptions on the paywall. Low-frequency path, but a direct
  revenue-adjacent bug.
- P3-3 + P3-6 shipped new user-visible English copy; if left
  un-localized, they would have quietly rotted as non-English users
  adopt the app and see mixed-language UI.

## Follow-ups / not done here
- **Full sweep for hardcoded English strings across all views** — this
  slice scoped to what P3-3 + P3-6 added. There are likely other
  hardcoded English strings in less-trafficked paths (onboarding,
  team management, export dialogs). A future pass could grep for
  `Text("...")` with literal English and migrate them all.
- **Professional translation review** — the new ja/es/ko/zh-Hans
  strings are engineer-translated (cross-referenced with existing
  style). A native reviewer should spot-check before public App Store
  release in those locales.
- **Xcode "Export for Localization"** (.xcloc) workflow — the plan
  mentions this for future translator hand-offs. Not needed while
  strings stay in `.strings` files, but relevant when scaling beyond
  5 locales or adding professional LSPs.
- Completes P3-2 (scoped version). Remaining v1.11: P3-1A Android
  placeholder (multi-day, non-code-heavy planning work), P2-8 Sentry
  (still blocked on user DSN).
