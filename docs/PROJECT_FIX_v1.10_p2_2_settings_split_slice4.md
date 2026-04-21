# PROJECT_FIX v1.10 — P2-2 slice 4: PairingSection extraction

**Date**: 2026-04-21
**Scope**: Largest single SettingsTab extraction so far; includes dead-code cleanup.

---

## Why

Per Codex's guidance after slice 1, the pairing flow is a single
cohesive state machine. Splitting the view without moving its state
+ its async helper would break identity preservation. This slice
moves the entire unit at once.

## What shipped

### Pairing cluster extraction

**New** `CLI Pulse Bar/CLI Pulse Bar/PairingSection.swift` (230 lines)

Moved as one unit:
- `pairingSection` view body (SectionHeader + mode indicator + pairing UI)
- `setupStepsView(info:)`
- `pairAndStartNativeHelper(code:) async` — writes helper-login-item
  status through the binding
- `modeIndicator(...)` private helper (pairing-only)
- `copyButton(text:)` private helper (pairing-only)
- `@State pairingInProgress`, `@State nativePairingError`

API shape:
```swift
struct PairingSection: View {
    @EnvironmentObject var state: AppState
    @Binding var helperEnabled: Bool   // parent still owns
    ...
}
```

Parent ownership of `helperEnabled` preserved because the Advanced-settings
toggle still reads it. Codex flagged that elevating this to `AppState`
would belong in a macOS-specific settings model, not in `CLIPulseCore.AppState`
— deferred as a future decision.

### Dead-code cleanup (during the move)

- **Deleted** `setupStep<Content>` — unused in SettingsTab (different
  `setupStep` in `OnboardingWizardView.swift` is unrelated)
- **Deleted** `@State private var showSetupGuide = false` — Codex
  caught this during review; no references anywhere in the tree

### `SettingsTab.swift`

- Call site: `pairingSection` → `PairingSection(helperEnabled: $helperEnabled)`
- All pairing-related code removed
- Line count: **1137 → 904 (-233 lines this slice)**

### Cumulative P2-2 delta across all 4 slices

| file | original | slice 1 | slice 2+3 | slice 4 | Δ |
|---|---|---|---|---|---|
| `SettingsTab.swift` | 1381 | 1314 | 1137 | **904** | **-477 (-34.5%)** |
| 5 extracted files | 0 | 144 | 345 | **575** | +575 |

### pbxproj wiring

- 4-entry pattern (PBXBuildFile, PBXFileReference, group child, Sources)
- Hex IDs: A10045/B10045 (PairingSection)
- `xcodebuild build` macOS → `** BUILD SUCCEEDED **`

## Review

- **Codex rescue** — **ship-with-notes**. Verified:
  - Parent `helperEnabled` ownership correct; binding writes land cleanly
  - `modeIndicator` and `copyButton` correctly kept private — neither has
    any external caller today; promotion would be premature
  - `copyButton` uses `NSPasteboard`, so moving it to CLIPulseCore would
    be the wrong layer anyway
  - `setupStep<Content>` deletion verified safe — no surviving caller
  - **Caught residual dead `showSetupGuide` state** — actioned

## Files changed

```
CLI Pulse Bar/CLI Pulse Bar/PairingSection.swift              (new, 230 lines)
CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift                 (-234 lines incl. dead-var cleanup)
CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj         (4 entries for PairingSection)
docs/PROJECT_FIX_v1.10_p2_2_settings_split_slice4.md          (this doc)
```

## Next P2-2 slices

Remaining big methods in SettingsTab (no tight ordering dependencies):
- `generalSection` (~200 lines; carries `alertThresholdRow` with it)
- `advancedSection` (~190 lines; `helperEnabled` toggle lives here)
- `providerSettingsSection`
- `displaySection`
- `loginSection` (if still present)

After P2-2 done → P2-3 AppState god-object split (the main event).
