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

## Codex review 2026-05-07: archive missing Swift helper — FIXED

After my first pass, Codex independently inspected the archive and flagged that the Phase 4E Swift LaunchAgent helper was NOT actually in the Release archive — meaning v1.13.0 could not be described as "Phase 4E runtime cutover / Python retirement" until the archive was fixed. Two distinct issues:

1. **Swift helper + LaunchAgent plist absent from Release archive.** `xcodebuild archive` does not trigger any Run Script / Copy Files build phase for the `cli_pulse_helper` binary or `HelperAgent.plist` because those phases were never wired into the `.xcodeproj`. The same gap existed in the v1.12.3 archive currently in ASC.
2. **Embedded `CLIPulseHelper.app` LoginItem stuck on `1.10.7 / 41`.** The LoginItem's `Info.plist` hard-codes its version, and that source had not been bumped through any release since v1.10.7. Old version metadata visible in the bundle.

Both fixed in this commit. Details:

### Fix 1: Helper + plist embedding

New script `scripts/embed_helper_in_archive.sh`:

- Builds the Swift helper via `swift build -c release`.
- Locates the `.app` inside an existing `.xcarchive`.
- Copies the helper to `<app>/Contents/Helpers/cli_pulse_helper`.
- Copies `HelperAgent.plist` to `<app>/Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist`.
- Detects the existing signing identity (extracted from the archive's `codesign -dvv`); falls back to ad-hoc `-` for unsigned CI archives.
- Codesigns the helper with **its own minimal entitlements** (`HelperSwift/cli_pulse_helper.entitlements`, Hardened Runtime on, no sandbox).
- Re-signs the parent app with `--preserve-metadata=entitlements,requirements,flags` so the Xcode-emitted sandbox + app-group + .xcent survive.
- Verifies (a) helper is Mach-O + executable, (b) plist has `BundleProgram = "Contents/Helpers/cli_pulse_helper"`, (c) `codesign --verify --deep --strict` passes, (d) parent app entitlements still include sandbox + app-group, (e) helper does NOT have sandbox entitlement.

`build_macos()` in `CLI Pulse Bar/scripts/build-appstore.sh` now calls this script after `xcodebuild archive`. The exportArchive + upload steps run unchanged.

### Fix 2: CLIPulseHelper.app LoginItem version

`CLI Pulse Bar/CLIPulseHelper/Info.plist` bumped `1.10.7 → 1.13.0`, build `41 → 50`. Verified inside the rebuilt archive.

### Fix 3: CI verification

New CI job `verify-archive-embedding` in `.github/workflows/swift-ci.yml`:

- Runs `xcodebuild archive` with ad-hoc signing (mimicking ASC's archive shape).
- Runs `embed_helper_in_archive.sh`.
- Asserts Codex's four conditions: helper Mach-O exists, plist exists, `codesign --verify --deep --strict` passes, plist `BundleProgram` value matches the embedded path.

This catches the bug Codex found if it ever regresses. Runs only on full matrix (PR / main push), not smoke pushes.

## Verification (after fix)

Rebuilt archive at `/tmp/v1.13.0-archives/CLIPulse-macOS-v1.13.0.xcarchive`:

```
$ defaults read .../CLI\ Pulse\ Bar.app/Contents/Info CFBundleShortVersionString
1.13.0
$ defaults read .../CLI\ Pulse\ Bar.app/Contents/Info CFBundleVersion
50
$ defaults read .../CLI\ Pulse\ Bar.app/Contents/Library/LoginItems/CLIPulseHelper.app/Contents/Info \
    CFBundleShortVersionString
1.13.0
$ defaults read .../CLI\ Pulse\ Bar.app/Contents/Library/LoginItems/CLIPulseHelper.app/Contents/Info \
    CFBundleVersion
50

$ find .../CLI\ Pulse\ Bar.app -name "cli_pulse_helper"
.../Contents/Helpers/cli_pulse_helper
$ file .../Contents/Helpers/cli_pulse_helper
... Mach-O 64-bit executable arm64
$ /usr/libexec/PlistBuddy -c "Print :BundleProgram" \
    .../Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist
Contents/Helpers/cli_pulse_helper

$ codesign --verify --deep --strict \
    .../CLI\ Pulse\ Bar.app
# (no output → success)
```

All four Codex conditions pass.

## ASC submission

The xcarchive is now ready for ASC submission via:

```bash
./CLI\ Pulse\ Bar/scripts/build-appstore.sh macos --upload
```

The script's `build_macos()` flow:

1. `xcodebuild archive` (Xcode does Automatic signing).
2. `embed_helper_in_archive.sh` (this fix — adds helper + plist + re-signs).
3. `xcodebuild -exportArchive method=app-store` (re-signs for distribution + writes export).
4. `upload_to_appstore` (uploads via `xcodebuild -exportArchive destination=upload` + ASC API key).

Per `feedback_appstore_update.md`, the actual upload step is Jason's call.

After upload, in ASC web UI pick build 50 for v1.13.0 macOS submission. Apple review typically 24-48 h.

## Out of scope

- iOS xcarchive build (BLOCKED by pre-existing Xcode "Multiple commands produce CLIPulseCore.o / SentryCppHelper.o" issue — orthogonal to v1.13.0).
- Phase 4E Slice 4 deferred items (crash-loop launcher script, atomic Python test retirement, native Swift heartbeat/sync) — see `PROJECT_FIX_2026-05-07_phase4e_slice4_cutover.md`.
- Computer-use M4 toggle E2E (机会做) — Jason's manual session.
- Wiring the embedding directly into `.xcodeproj` build phases (so plain `xcodebuild archive` is self-sufficient) — left as a future cleanup. The script-based path is the canonical entry point per the existing PHASE4D_XCODE_SETUP.md decision.
