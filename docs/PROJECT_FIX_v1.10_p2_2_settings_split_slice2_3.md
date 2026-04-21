# PROJECT_FIX v1.10 — P2-2 slices 2+3: HowItWorksCard + SubscriptionSection

**Date**: 2026-04-21
**Scope**: macOS `SettingsTab.swift` structural refactor. No behavior change.

---

## What shipped

### Slice 2 — `HowItWorksCard`

- **New** `CLI Pulse Bar/CLI Pulse Bar/HowItWorksCard.swift` (44 lines)
  - Stateless `struct HowItWorksCard: View`; no `AppState` access
  - Renders "How it works" explainer with Local Mode + Cloud Mode rows
  - Private `row(icon:title:desc:)` helper
- SettingsTab call site: `howItWorksCard` → `HowItWorksCard()`;
  extracted bodies removed; -~30 lines

### Slice 3 — `SubscriptionSection`

- **New** `CLI Pulse Bar/CLI Pulse Bar/SubscriptionSection.swift` (157 lines)
  - Extracts the **cohesive IAP cluster** per Codex slice-1 guidance:
    `subscriptionSection` + `inlineIAPCards` + `inlineProductRow(...)`
    helper + `iapError: String?` state
  - `@EnvironmentObject state` + `@Environment(\.openWindow)`
  - `import StoreKit` for `Product`
  - Renders: current plan / provider / device / retention rows,
    Manage button (Pro+), or inline IAP purchase cards (free-tier)
- SettingsTab call site: `subscriptionSection` → `SubscriptionSection()`;
  extracted bodies + `iapError` state removed; -~149 lines

### Cumulative line delta for P2-2

| file | original | slice 1 | slice 2+3 | Δ |
|---|---|---|---|---|
| `SettingsTab.swift` | 1381 | 1314 | **1137** | -244 (-17.7%) |
| 4 extracted section files | 0 | 144 | **345** | +345 |

### pbxproj wiring

- 4 entries per extraction (PBXBuildFile, PBXFileReference, group, Sources)
- Hex IDs: A10043/B10043 (HowItWorks), A10044/B10044 (Subscription)
- `xcodebuild build` macOS → `** BUILD SUCCEEDED **`

## Codex review → SHIP (unqualified)

- Both extractions verified behavior-identical
- Call-site swaps + pbxproj wiring both clean
- `iapError` state stays stable during StoreKit purchase flow because
  `SubscriptionSection()` occupies a fixed structural slot inside
  `authenticatedSection` — identity preserved across parent re-renders

## Next: Pairing cluster (slice 4)

Codex guidance adopted for the next slice:
- Move `pairingInProgress`, `nativePairingError`, `pairAndStartNativeHelper`
  together (single state machine)
- Move `copyButton` + `modeIndicator` (pairing-only today)
- Decide `helperEnabled` ownership up front — write path in pairing,
  toggle lives in Advanced; don't split
- `setupStep` is dead code; delete during move

## Files changed

```
CLI Pulse Bar/CLI Pulse Bar/HowItWorksCard.swift                     (new, 44)
CLI Pulse Bar/CLI Pulse Bar/SubscriptionSection.swift                (new, 157)
CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift                        (-177 total across both)
CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj                (8 entries, 2 files registered)
docs/PROJECT_FIX_v1.10_p2_2_settings_split_slice2_3.md               (this doc)
```
