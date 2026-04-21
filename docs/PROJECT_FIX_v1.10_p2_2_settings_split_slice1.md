# PROJECT_FIX v1.10 — P2-2 slice 1: SettingsTab extraction (DangerZone + AccountCard)

**Date**: 2026-04-21
**Scope**: macOS `SettingsTab.swift` structural refactor. No UI or logic change.

---

## Why

Plan P2-2 targets `SettingsTab.swift` (1381 lines) — split into smaller
sub-views. Previous Codex analysis flagged the real split targets as:
Account card, Subscription cluster, Providers, Alerts, Git-tracking
consent, About, Danger Zone. This slice ships the two lowest-risk
extractions: `DangerZoneSection` and `AccountCardView`.

## What shipped

### Extraction 1 — `DangerZoneSection`

- **New** `CLI Pulse Bar/CLI Pulse Bar/DangerZoneSection.swift` (104 lines)
  - `struct DangerZoneSection: View`
  - Owns `@EnvironmentObject state`, `@Environment(\.openWindow)`,
    and the 4 `@State` vars previously on SettingsTab:
    `showDeleteAccountAlert`, `showDeleteAccountConfirm`,
    `deleteConfirmText`, `isDeletingAccount`
  - `performDeleteAccount()` helper moved with it
  - Renders: About / Privacy / Terms links, Sign Out, Delete Account
    (two-step confirmation), Quit

### Extraction 2 — `AccountCardView`

- **New** `CLI Pulse Bar/CLI Pulse Bar/AccountCardView.swift` (40 lines)
  - `struct AccountCardView: View` with `@EnvironmentObject state`
  - No local state
  - Renders: user avatar, name, email (if `!state.hidePersonalInfo`),
    paired/not-paired `StatusBadge`

### `SettingsTab.swift`

- Two call sites: `dangerZone` → `DangerZoneSection()`,
  `accountCard` → `AccountCardView()`
- Extracted view bodies removed; 4 `@State` vars removed;
  `performDeleteAccount()` removed
- Line count: **1381 → 1314 (-67, -4.9%)**

### pbxproj wiring

- Both files registered in `CLI Pulse Bar` target via the 4-entry pattern
  (PBXBuildFile, PBXFileReference, group child, Sources build phase)
- Codex confirmed the hand-edit pattern is acceptable for single-target
  extractions at this cadence

## State-lifecycle note

The 4 delete-account `@State` vars now live on `DangerZoneSection` instead
of `SettingsTab`. Codex reviewed this:
> `DangerZoneSection()` is an unconditional child at a fixed position
> inside `authenticatedSection`, so normal parent re-renders do not
> change its identity or reset those states; they will reset only when
> the authenticated subtree itself goes away, which is already a
> natural boundary for sign-out/delete-account flow.

No observable behavior regression.

## Verification

- `xcodebuild build` (CLI Pulse Bar, macOS) → `** BUILD SUCCEEDED **`
- CLIPulseCore tests still green

## Remaining P2-2 work (plan per Codex guidance)

Extract in clusters to preserve related state together:

1. **`howItWorksCard`** — self-contained, low-risk. Good next step.
2. **Subscription cluster** (`subscriptionSection` + `inlineIAPCards` +
   `iapError` state). Must move as one unit.
3. **Pairing cluster** (`pairingSection` + `howItWorksCard` [if not
   already moved] + `setupStepsView` + `pairingInProgress` +
   `nativePairingError` + `pairAndStartNativeHelper`). Co-owned state.
4. **`generalSection`** (biggest remaining, ~200 lines). Binding-heavy
   but straightforward; `alertThresholdRow` must come with it.
5. **`advancedSection`** (~190 lines).
6. **`providerSettingsSection`**.
7. **`displaySection`**.

After P2-2: P2-3 AppState split (the main event).

## Files changed

```
CLI Pulse Bar/CLI Pulse Bar/DangerZoneSection.swift           (new, 104)
CLI Pulse Bar/CLI Pulse Bar/AccountCardView.swift             (new, 40)
CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift                 (-67, delegation)
CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj         (8 entries, 2 files registered)
docs/PROJECT_FIX_v1.10_p2_2_settings_split_slice1.md          (this doc)
```

## Review audit trail

- **Codex rescue** — **ship-with-notes**, no must-fix. Behavior
  regression-free; state lifecycle OK given the fixed-identity parent;
  hand-edit pbxproj pattern acceptable; recommended cluster-extraction
  order for subsequent slices (adopted above).
