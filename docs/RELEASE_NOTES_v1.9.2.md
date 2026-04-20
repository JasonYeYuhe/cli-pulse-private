# CLI Pulse v1.9.2 — Release Notes

**Build:** 30
**Date:** 2026-04-18

This release covers both macOS (already in App Store review) and iOS/iPadOS.

---

## macOS 1.9.2

### Short "What's New" (≤170 chars)

```
Test any provider's credentials in one click. Show/hide API keys while you type. Smoother Provider Settings window. Fixes a Keychain autofill quirk.
```

### Fixes
- Keychain AutoFill no longer surfaces a demo login (`demo@clipulse.app`) in the Provider Settings editor. Fields now opt out of system AutoFill via AppKit-bridged `NSSecureTextField` with `contentType = nil`.
- Clicking Cancel in Provider Settings no longer collapses the menu-bar popover. The editor now opens in its own window via `WindowGroup` scene, independent of `MenuBarExtra` lifecycle.

### Features
- **Test connection** button under each Provider's API/Cookie section. Validates credentials live against the provider's quota endpoint and reports `OK (latency) remaining: N` or the specific error.
- **Show/Hide API key** eye toggle next to the API key field, for pasted-value verification.

---

## iOS / iPadOS 1.9.2

### Short "What's New" (≤170 chars)

```
Ask Siri for your CLI usage. Tap the widget to refresh. Richer iPad dashboard that scales to every screen size.
```

### Features
- **Siri & Shortcuts**: "Hey Siri, get CLI Pulse status" speaks today's token usage, cost, active sessions, and open alerts. "Check CLI Pulse quota" takes a provider parameter and reports remaining.
- **Interactive widget refresh**: Medium and Large usage widgets now have a refresh button. Tapping it brings CLI Pulse to the foreground so it can sync the latest data — the widget updates itself once the app finishes refreshing.
- **iPad polish**: Overview metric grid now adapts to iPad Pro 11" and 13" widths (showing 3, 4, or 5 cards per row instead of a fixed 4). Split-view sidebar width is constrained to a more natural 240–340 pt range.

### Review notes for Apple (if asked)
No new entitlements, no new network domains, no changes to subscription or IAP behavior. AppIntents read the same App Group cache already used by the home-screen widgets; no new user data is collected. The widget refresh button opens the app so the authenticated sync can run in the main process.

### Internal
- New files: `Intents/CLIPulseIntentCache.swift`, `Intents/GetStatusIntent.swift`, `Intents/GetProviderQuotaIntent.swift`, `Intents/RefreshWidgetIntent.swift`, `Intents/CLIPulseShortcuts.swift`.
- `UsageOverviewWidget` medium & large views: added `Button(intent: RefreshWidgetIntent())`.
- `iOSOverviewTab.metricsGrid`: iPad columns switched to `GridItem(.adaptive(minimum: 180))`.
- `iPadSplitView`: `.navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)` + `.balanced` style.
- MARKETING_VERSION 1.9.1 → 1.9.2, CURRENT_PROJECT_VERSION 29 → 30 across all iOS targets.
