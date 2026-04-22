# PROJECT_FIX v1.10.6 — P3-6: HelperAPIClient configuration self-check

**Date:** 2026-04-22
**Commit:** (pending)
**Scope:** Surface missing `SUPABASE_ANON_KEY` at app launch. Previously,
release builds silently fell through to an empty anon key
(`HelperAPIClient.swift:152-159`) and the user saw a blank dashboard with no
hint why. Now the top-level view on both macOS and iOS renders a
persistent, non-dismissable red banner announcing the problem.

## Shipped

### HelperAPIClient.swift
- Moved `#if os(macOS)` guard so only the `HelperAPIClient` actor is
  macOS-only. `SupabaseConstants` and `HelperAPIError` are now cross-platform
  and visible to iOS imports.
- Moved `import Foundation`, `import os`, and `helperLogger` above the
  platform guard. `os.Logger(subsystem:category:)` is available on
  iOS 14+/macOS 11+, so this is safe.
- Added `public static var isConfigured: Bool { !anonKey.isEmpty }` to
  `SupabaseConstants`. Release builds set `anonKey = ""` when missing +
  log an error; DEBUG still `fatalError`s at init.

### MenuBarView.swift (macOS)
- Wrapped body in a `VStack(spacing: 0)` that renders
  `configurationErrorBanner` above the existing auth/connected switch when
  `!SupabaseConstants.isConfigured`. Banner is persistent (no dismiss
  button, no `@State`) because this is an app-misconfiguration condition
  the user can't fix in-UI — they need a new build.

### iOSMainView.swift (iOS)
- Same wrap. Body now renders banner above the `Group { login | iPad |
  iPhone }` switch when `!isConfigured`.

### Banner styling
Both banners use the red palette + `exclamationmark.octagon.fill` icon +
two-line copy ("Configuration error" / "SUPABASE_ANON_KEY missing — API
calls will fail."), scaled for each form factor (size 10/9 on the
compact macOS popover, footnote/caption on iOS).

## Why this matters
Jason ships release builds signed outside the local dev env (App Store
Connect + manual signing). If the `SUPABASE_ANON_KEY` Info.plist key was
ever forgotten during a release build, the binary would ship with every
API call returning `HelperAPIError.notConfigured`, and the user would see a
silent, always-loading dashboard with no clue. The banner can't make a
misconfigured build work, but it makes the failure mode visible — Jason
(or a TestFlight reviewer) can file a ticket instead of guessing.

## Review verdict
- **Codex codex-rescue:** skipped (session flake pattern).
- **Gemini 3.1 Pro scan:** timed out at 180s (recurring flake on small
  Swift diffs). Self-review verified all 5 target points:
  1. `isConfigured` derives from `!anonKey.isEmpty` ✓
  2. `#if os(macOS)` now scopes only HelperAPIClient; SupabaseConstants +
     HelperAPIError cross-platform ✓
  3. Banner is persistent + rendered above all other UI in both targets ✓
  4. DEBUG `fatalError` path unchanged ✓
  5. `os.Logger` moved above guard — API is iOS 14+/macOS 11+ compatible ✓

## Baselines
- `swift test` CLIPulseCore: all passing ✓
- `xcodebuild -scheme "CLI Pulse Bar" -destination platform=macOS`: BUILD
  SUCCEEDED ✓
- `xcodebuild -scheme "CLI Pulse iOS" -destination generic/platform=iOS
  Simulator`: BUILD SUCCEEDED ✓

## Follow-ups
- **L10n pass (P3-2)** should pick up the two new English strings
  ("Configuration error" / "SUPABASE_ANON_KEY missing — API calls will
  fail.") into the `L10n.common.*` hierarchy.
- This completes P3-6. Remaining from v1.11 scope: P2-8 Sentry (blocked on
  user-supplied DSN), P3-1A/P3-2/P3-3/P3-4/P3-5.
