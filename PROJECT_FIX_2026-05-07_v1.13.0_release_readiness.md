# v1.13.0 release-readiness

**Date:** 2026-05-07
**Branch:** `v1.13.0-release-readiness`
**Version:** `1.12.3 / 49 → 1.13.0 / 50`

## Summary

v1.13.0 closes Phase 4E. The macOS app's LaunchAgent surface now drives cloud-side managed-session sync entirely in Swift via the `RemoteAgentCloud` actor wired into `cli_pulse_helper daemon` (Slice 4 — PR [#34](https://github.com/JasonYeYuhe/cli-pulse-private/pull/34)). The cloud-sync layer of `helper/remote_agent.py` has been ported to Swift (Slice 3 — PR [#33](https://github.com/JasonYeYuhe/cli-pulse-private/pull/33)).

## Phase 4E delta vs v1.12.3

| Slice | PR | What |
|---|---|---|
| 3 | [#33](https://github.com/JasonYeYuhe/cli-pulse-private/pull/33) | `RemoteAgentCloud` actor + `EventUploader` (256-event bounded queue, drop-oldest, 5 s flush budget) + `SupabaseRPCCaller` (2.5 s per-request timeout) + extracted `Redactor` module |
| 4 | [#34](https://github.com/JasonYeYuhe/cli-pulse-private/pull/34) | `DaemonConfig` argv parser + cloud-sync wiring inside `cli_pulse_helper daemon` (1 s tick) + `--legacy-python` opt-out flag + bounded 4.5 s SIGTERM drain |

Combined: 49 new Swift tests (HelperKit 258 → 307), 0 new test failures, 0 P0/P1 Gemini findings unresolved.

## Files bumped

| File | Before | After |
|---|---|---|
| `CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj` | `MARKETING_VERSION = 1.12.3; CURRENT_PROJECT_VERSION = 49;` | `1.13.0; 50` |
| `CLI Pulse Bar/CLI Pulse Bar/Info.plist` | `1.12.3 / 49` | `1.13.0 / 50` |
| `CLI Pulse Bar/CLI Pulse Bar iOS/Info.plist` | `1.12.3 / 49` | `1.13.0 / 50` |
| `CLI Pulse Bar/CLI Pulse Bar Watch/Info.plist` | `1.12.3 / 49` | `1.13.0 / 50` |
| `CLI Pulse Bar/CLI Pulse Widgets/Info.plist` | `1.12.3 / 49` | `1.13.0 / 50` |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/PDFReportGenerator.swift:262` | `?? "1.12.3"` | `?? "1.13.0"` |

`grep -rn "1\.12\.3\|\"49\""` against the six locations returns zero residuals.

## Test gates

```
swift test --package-path HelperSwift                    307/307 ✓
swift test --package-path "CLI Pulse Bar/CLIPulseCore"   918/918 ✓
python3 -m pytest -q helper/                             413/413 ✓
```

## Archive build

```
xcodebuild archive
  -project "CLI Pulse Bar/CLI Pulse Bar.xcodeproj"
  -scheme "CLI Pulse Bar"
  -destination "generic/platform=macOS"
  -archivePath /tmp/v1.13.0-archives/CLIPulse-macOS-v1.13.0.xcarchive
  -configuration Release
  SKIP_INSTALL=NO
```

**Result:** `** ARCHIVE SUCCEEDED **` — 148 MB at `/tmp/v1.13.0-archives/CLIPulse-macOS-v1.13.0.xcarchive`.

Verification:

```
$ defaults read .../CLI\ Pulse\ Bar.app/Contents/Info CFBundleShortVersionString
1.13.0
$ defaults read .../CLI\ Pulse\ Bar.app/Contents/Info CFBundleVersion
50
```

## Observation: Swift helper not in Release archive (pre-existing, ≥v1.12.3)

The Phase 4D Swift LaunchAgent binary (`Contents/Helpers/cli_pulse_helper`) and its plist (`Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist`) ship in **Debug** builds (`build_app_output/DerivedData/Build/Products/Debug/`) but **NOT** in Release archives. This is true for both `/tmp/v1.12.3-archives/CLIPulse-macOS-v1.12.3.xcarchive` and the new v1.13.0 archive — so v1.13.0 is at parity with v1.12.3 on this front.

**Impact for v1.13.0 release:**

- The actual production helper surface today is `Contents/Library/LoginItems/CLIPulseHelper.app` (XPC-based LoginItem helper with its own `HelperDaemon`). That continues to work unchanged.
- The Phase 4E Swift cloud-sync code (Slices 3 + 4) is correctly compiled into the HelperKit/CLIPulseCore frameworks shipped in the .app bundle, but the standalone `cli_pulse_helper` LaunchAgent binary that activates `RemoteAgentCloud.tick()` is not in the Release archive.
- Effectively, v1.13.0 ships Slice 3 + 4 as **bundled dead code** ready to be activated whenever the Xcode "Copy Files" build phase for `cli_pulse_helper` and the `HelperAgent.plist` gets switched on for Release.

**Remediation deferred to v1.14:** investigate the project's Copy Files build phase configuration for the helper binary and plist. This is an orthogonal Xcode project-config issue and was the same in v1.12.3 (which is currently WAITING_FOR_REVIEW in ASC), so v1.13.0 is not introducing a regression.

This issue shouldn't block ASC submission for v1.13.0 — the user-visible behavior is identical to v1.12.3.

## ASC submission

The xcarchive is ready for ASC submission via:

```bash
./CLI\ Pulse\ Bar/scripts/build-appstore.sh macos --upload
```

Per `feedback_appstore_update.md`, the actual upload step is Jason's call.

After upload, in ASC web UI, pick build 50 for v1.13.0 macOS submission. Apple typically reviews within 24-48 h.

## Out of scope

- iOS xcarchive build (BLOCKED by pre-existing Xcode "Multiple commands produce CLIPulseCore.o / SentryCppHelper.o" issue — orthogonal to v1.13.0).
- Phase 4E Slice 4 deferred items (crash-loop launcher script, atomic Python test retirement, native Swift heartbeat/sync) — see `PROJECT_FIX_2026-05-07_phase4e_slice4_cutover.md`.
- Computer-use M4 toggle E2E (机会做) — Jason's manual session.
