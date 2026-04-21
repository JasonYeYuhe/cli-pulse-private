# PROJECT_FIX v1.10 — P2-2 slices 5-8: complete SettingsTab split

**Date**: 2026-04-21
**Scope**: Final round of P2-2. SettingsTab reduced from 904 → 220 lines.

---

## What shipped

### Slice 5 — `GeneralSection` (287 lines)
- Extracts `generalSection` + `alertThresholdRow` + `filterChip` +
  `toggleFilterItem` helpers + `alertThresholds` @State
- Self-contained; no @Binding

### Slice 6 — `AdvancedSection` (223 lines)
- Extracts `advancedSection` + `privacyRow` helper + `showGitTrackingConsent`
  @State
- Takes `@Binding var launchAtLogin: Bool` and `@Binding var helperEnabled: Bool`
  because both pair with `LaunchAtLogin.toggle()` / `HelperLogin.toggle()`
  services also called from `PairingSection`
- Parent SettingsTab keeps canonical ownership — Codex confirmed no race
  concern because PairingSection and AdvancedSection are never mounted
  simultaneously (pairing section renders only when `!state.isPaired`)

### Slice 7 — `DisplaySection` (126 lines)
- Extracts `displaySection` — menu-bar display mode, content mode,
  appearance toggles, overview-providers reorderable list

### Slice 8 — `ProviderSettingsSection` (73 lines)
- Extracts `providerSettingsSection` + `providerSettingsRow` helper
- Takes `@Environment(\.openWindow)` for the gear-button-opens-config window

### Dead-code cleanup (from Codex follow-up)
- Removed unused `@Environment(\.openWindow)` on SettingsTab
- Removed unused `@State serverInput` and the `.onAppear { serverInput = "" }`
  that referenced it

## Cumulative P2-2 across all 8 slices

| file | original | final | Δ |
|---|---|---|---|
| `SettingsTab.swift` | 1381 | **220** | **-1161 (-84.1%)** |
| 9 extracted section files | 0 | **1284** | +1284 |

Remaining in `SettingsTab.swift`: `loginSection` (~100 lines, tightly
coupled to email/OTP/password/usePasswordLogin state) + thin
`authenticatedSection` orchestration that delegates to the 8 extracted
sections + the top-level `body`/picker.

## Verification

- `xcodebuild build` (macOS scheme) → `** BUILD SUCCEEDED **`
- All CLIPulseCore tests green (no test file changes this slice)

## Codex review: ship-with-notes, no must-fix

- State-identity stable across all new views
- `helperEnabled` binding-from-two-children is safe — the two children
  are mutually exclusive via the `!state.isPaired` gate
- Both dead-code items actioned

## Why `loginSection` stays in SettingsTab

Codex: "Extraction mostly turns into binding plumbing unless you also
move state into a child-owned login view or a login view model." The
login flow owns 5 @State vars (`email`, `otpCode`, `password`,
`usePasswordLogin`, `launchAtLogin`) and is only shown pre-login. Not
worth extracting right now. Revisit if a second login view (iOS login
UI?) needs to share the state machine.

## Files changed

```
CLI Pulse Bar/CLI Pulse Bar/GeneralSection.swift            (new, 287)
CLI Pulse Bar/CLI Pulse Bar/DisplaySection.swift            (new, 126)
CLI Pulse Bar/CLI Pulse Bar/ProviderSettingsSection.swift   (new, 73)
CLI Pulse Bar/CLI Pulse Bar/AdvancedSection.swift           (new, 223)
CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift               (-684 lines across slices 5-8)
CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj       (16 entries for 4 new files)
docs/PROJECT_FIX_v1.10_p2_2_settings_split_slices5_8.md     (this doc)
```
