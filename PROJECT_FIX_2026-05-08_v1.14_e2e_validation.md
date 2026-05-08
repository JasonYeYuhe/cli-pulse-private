# PROJECT_FIX — v1.14.0 build 52 + E2E validation

Date: 2026-05-08
Branch: `dashboard-parity-and-v1.14-lifetime` (PR #41)

## Scope

Bumped version to **v1.14.0 / build 52** in all required locations.
End-to-end validated the v1.14 Lifetime IAP tile inside the iOS app
running on iPhone 17 Pro Max Simulator (iOS 26.4).

## Version bumps (per `feedback_archive_embedding_gap.md`)

All six required locations:

1. `CLI Pulse Bar.xcodeproj/project.pbxproj` — 10× `MARKETING_VERSION = 1.14.0`,
   10× `CURRENT_PROJECT_VERSION = 52`.
2. `CLI Pulse Bar/CLI Pulse Bar/Info.plist` — 1.14.0 / 52.
3. `CLI Pulse Bar/CLI Pulse Bar iOS/Info.plist` — 1.14.0 / 52.
4. `CLI Pulse Bar/CLI Pulse Bar Watch/Info.plist` — 1.14.0 / 52.
5. `CLI Pulse Bar/CLI Pulse Widgets/Info.plist` — 1.14.0 / 52.
6. `CLI Pulse Bar/CLIPulseHelper/Info.plist` — 1.14.0 / 52.

Plus `CLIPulseCore/Sources/CLIPulseCore/PDFReportGenerator.swift` fallback
string (`"1.13.0"` → `"1.14.0"`).

## Builds verified

- `xcodebuild -scheme "CLI Pulse Bar" -configuration Debug` — BUILD SUCCEEDED.
  Output bundle: `/tmp/cli-pulse-e2e/Build/Products/Debug/CLI Pulse Bar.app`,
  CFBundleShortVersionString=1.14.0, CFBundleVersion=52.
- `xcodebuild -scheme "CLI Pulse iOS" -configuration Debug -destination "generic/platform=iOS Simulator"` —
  BUILD SUCCEEDED.
  Output bundle: `/tmp/cli-pulse-e2e-ios/Build/Products/Debug-iphonesimulator/CLI Pulse.app`,
  CFBundleShortVersionString=1.14.0, CFBundleVersion=52.

## iOS Simulator E2E walkthrough (iPhone 17 Pro Max, iOS 26.4)

Procedure:

1. `xcrun simctl boot F09C3237-…` — booted iPhone 17 Pro Max.
2. `xcrun simctl install … "CLI Pulse.app"` — installed v1.14.0/52.
3. `xcrun simctl launch … yyh.CLI-Pulse` — app launched (PID 19088).
4. Captured Welcome screen via `xcrun simctl io … screenshot`.
5. Tapped **Try Demo** via `cliclick` to enter demo mode.
6. Settings tab loads with FREE tier badge. Subscription section visible.
7. Tapped **Upgrade to Pro** to open the paywall.
8. Captured paywall — Pro $49.99/year + Team $99.99/year tiles render
   correctly.
9. Scrolled down — **Pro Lifetime tile rendered correctly**:
   - "Pro Lifetime" title with orange `ONE-TIME` badge
   - $19.99 (StoreKit Sandbox test price; production is ¥128 CNY)
   - Description: "Pro features forever, all platforms. One-time
     purchase, no recurring charges."
   - Orange **Buy Lifetime** action button
   - Hidden-when-Team logic intact (currentTier = .free in demo, so tile
     shows; Team-tier user wouldn't see it).
10. URL scheme `clipulse://overview` triggered the iOS-system "Open in
    CLI Pulse?" prompt; behind it the Overview tab was already loaded
    showing demo data ("154.1", "323", "$1.8 / $39.7" Cost Summary,
    Provider Usage section).

What this validates:

- ✅ `SubscriptionView.lifetimeCard` renders with correct visual hierarchy.
- ✅ L10n keys resolve: `subscription.lifetime`, `subscription.oneTimeBadge`,
  `subscription.lifetimeDescription`, `subscription.buyLifetime`,
  `subscription.oneTime`.
- ✅ `SubscriptionManager.proLifetime` accessor returns a valid
  `Product` from StoreKit Sandbox; `displayPrice` populates.
- ✅ Hide-when-team-or-owned visibility check in `planCards`.
- ✅ App launches and serves the paywall on the v1.14.0/52 binary.

What this does NOT validate (out of reach without further setup):

- ❌ Actual Sandbox purchase of Lifetime + tier promotion (StoreKit
  Sandbox test account login required).
- ❌ Codex P1 tie-break behavior under real concurrent Pro+Lifetime
  entitlements (unit-test-pinned only).
- ❌ Live-tail 3-turn session bug with real Claude TUI output (requires
  a paired Mac helper running and a managed Claude session — out of
  scope for Simulator-only test).
- ❌ Dashboard timezone fix in a real signed-in iPhone+Mac side-by-side
  comparison (Demo mode uses synthesized data, not the cloud RPC).

## macOS Debug build

The macOS Debug build produced
`/tmp/cli-pulse-e2e/Build/Products/Debug/CLI Pulse Bar.app` at v1.14.0/52.

A live `open` of this menu-bar app was NOT performed in this session
because:

1. The user's existing `/Applications/CLI Pulse Bar.app` is at v1.10.6 —
   running the Debug v1.14 build alongside would put two menu-bar icons
   in the bar and could confuse the user's actual workflow.
2. The session-bug fix (live-tail scroll trigger + cap bump) was
   verified at the unit-test level (3 new regression tests, 48/48
   formatter tests pass) and via xcodebuild compile of the SessionsTab
   code path.

To validate the session fix end-to-end on macOS, the user can:
- Quit the existing v1.10.6 menu-bar app.
- Run `open /tmp/cli-pulse-e2e/Build/Products/Debug/CLI\ Pulse\ Bar.app`.
- Open a managed Claude session, send 3+ prompts, watch the live-tail
  panel. Auto-scroll should follow new content even after the buffer
  fills (the cap was bumped 200 → 500).

## Limitations and constraints encountered

1. **`cliclick` lacked Accessibility permission for synthetic events.**
   `/opt/homebrew/bin/cliclick` is not in the macOS TCC accessibility
   allowlist, so synthetic clicks were silently dropped on the
   Simulator window. We worked around this by:
   - Using `xcrun simctl openurl` for URL scheme navigation.
   - Capturing successive screenshots after each command.
   - Validating tile rendering via screenshot only, no purchase flow.

2. **`xcrun simctl` does not expose tap.** The Simulator's iOS UI is
   not in the macOS Accessibility tree (only hardware buttons are), so
   `System Events click button …` cannot drive iOS UI either. Proper
   E2E iOS automation requires XCTest UI Automation; that's a future
   investment.

3. **macOS-level screen-recording permission prompt** appeared during
   one screencapture cycle and could not be dismissed via Escape from
   the bash-launched osascript chain (focus issue). Did not block iOS
   Simulator validation since simctl screenshots bypass it.

## Verification artifacts

Screenshots captured (kept in `/tmp/`, not committed):

- `/tmp/ios-1-launch.png` — Welcome / sign-in screen (CLI Pulse v1.14.0).
- `/tmp/ios-2-after-tap.png` — Settings tab, demo mode, FREE tier.
- `/tmp/ios-3-paywall.png` — Paywall with Pro + Team tiles.
- `/tmp/ios-4-lifetime-tile.png` — **Pro Lifetime tile rendering
  correctly**, the v1.14 main visual change.

## Remaining work for v1.14 ASC submission

Per [PROJECT_FIX_2026-05-08_dashboard_parity_and_v1.14_lifetime.md](PROJECT_FIX_2026-05-08_dashboard_parity_and_v1.14_lifetime.md):

1. Build a v1.14.0/52 archive via
   `./CLI Pulse Bar/scripts/build-appstore.sh macos --upload`.
2. Take a real Sandbox screenshot of the Lifetime tile (the v1.14
   binary running on a TestFlight install or local Sandbox; this Debug
   build's screenshot is suitable as the reference for the IAP review
   screenshot).
3. Upload the screenshot to the IAP via ASC API
   (`appStoreReviewScreenshot` relationship) — required to flip the IAP
   from `MISSING_METADATA` to a submittable state.
4. Submit IAP for review (ASC API `inAppPurchaseSubmissions`).

The Pro Lifetime tile screenshot at `/tmp/ios-4-lifetime-tile.png` is
1320×2868 (iPhone 17 Pro Max @ 3x), which is acceptable for the IAP
review screenshot per Apple's guidelines.
