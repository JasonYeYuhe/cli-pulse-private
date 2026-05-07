# PROJECT_FIX — v1.13 MAS Archive Contract

Date: 2026-05-08
Branch: `codex/v113-mas-launchagent-strip`

## Context

The v1.13.0 Phase 4D/4E Swift LaunchAgent helper is intentionally
unsandboxed. App Store Connect rejects sandboxed macOS apps that embed
unsandboxed nested executables (`ITMS-90296`). The successful ASC upload
therefore stripped:

- `Contents/Helpers/cli_pulse_helper`
- `Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist`

from the MAS-bound archive before upload.

That strip decision was not encoded in the canonical
`CLI Pulse Bar/scripts/build-appstore.sh` path. Running the script later
would have re-embedded the helper and reproduced the ASC rejection.

## Fix

- `build-appstore.sh macos` now treats MAS archives as a no-LaunchAgent
  contract.
- The script fails fast if a MAS archive contains the Swift helper binary or
  LaunchAgent plist.
- `--upload` mode skips the local export step and directly uses the ASC API
  key upload export. This avoids blocking uploads on machines without an Xcode
  account/certificate configured locally.
- Local export failures are no longer swallowed by `|| true`.
- iOS and watchOS export failures are no longer swallowed either.
- iOS/watchOS archive/export directories are cleaned before each build, matching
  the macOS path and avoiding stale artifacts.
- Swift CI's ASC-path archive job now verifies the MAS contract: no
  `cli_pulse_helper`, no LaunchAgent plist, and the sandboxed
  `CLIPulseHelper.app` LoginItem remains present.

## Verification

- `bash -n CLI Pulse Bar/scripts/build-appstore.sh`
- `bash -n scripts/embed_helper_in_archive.sh`
- `bash -n scripts/build_signed_app.sh`
- Real `./CLI Pulse Bar/scripts/build-appstore.sh macos` reached archive
  verification and confirmed the generated MAS archive excludes the helper.
  Local export then failed due missing local Xcode account/cert, as expected now
  that failures are not swallowed.
- Fake-`xcodebuild` upload simulation confirmed `macos --upload`:
  - runs archive once,
  - skips the local export plist,
  - runs exactly one API-key upload export,
  - verifies the MAS archive contains no Swift LaunchAgent helper.

## Remaining Product Decision

The Swift LaunchAgent runtime remains a Developer ID distribution feature, not
an App Store feature. MAS v1.13 ships through the sandboxed
`CLIPulseHelper.app` LoginItem runtime.
