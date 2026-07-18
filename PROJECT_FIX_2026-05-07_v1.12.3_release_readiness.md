# PROJECT_FIX — v1.12.3 Release Readiness

**Date:** 2026-05-07
**Branch:** `v1.12.3-release-readiness` (cut from `main` after Slice 2d merge `7647e4f`)
**Type:** Release-readiness preparation. NOT a code-change PR.

## Summary

Prepares an ASC-shippable release based on the current `main`. Bumps marketing version `1.12.0 → 1.12.3` and build `48 → 49` across all targets (macOS app, iOS app, Watch app, Widgets, CLIPulseHelper). No code changes other than version-string bumps. Documents what this release contains and what's deferred.

## What ships in v1.12.3

The release content reflects 9 PRs merged to `main` since v1.12.0:

| PR | Sprint | Customer-visible? | Summary |
|---|---|---|---|
| [#21](https://github.com/cli-pulse/cli-pulse-private/pull/21) | A — v1.12.1 | **Yes (privacy)** | M1 redaction +5 patterns (Stripe / Slack / NPM / PyPI) + M4 user_settings PATCH→UPSERT (privacy toggle no longer silently lies for first-time togglers) |
| [#22](https://github.com/cli-pulse/cli-pulse-private/pull/22) | B — v1.12.2 | Indirect | M2 per-request 2.5s HTTP timeout + M3 token-level Bash risk classifier (`rm  -rf` / `rm\t-rf` / `rm -r -f` now correctly classified HIGH) |
| [#20](https://github.com/cli-pulse/cli-pulse-private/pull/20) | Phase 4D | No (internal) | Swift HelperKit base — 14 modules, 132 tests |
| [#23](https://github.com/cli-pulse/cli-pulse-private/pull/23) | Phase 4E plan | No (docs) | Phase 4E dev plan v2.1 (Gemini-double-reviewed) |
| [#24](https://github.com/cli-pulse/cli-pulse-private/pull/24) | Slice 1 | No (internal) | `GitCollector.swift` Swift port + 13 tests |
| [#25](https://github.com/cli-pulse/cli-pulse-private/pull/25) | prep | No (test fix) | fake_rpc kwargs hotfix + Slice 2 sub-slicing amendment |
| [#26](https://github.com/cli-pulse/cli-pulse-private/pull/26) | Slice 2a | No (internal) | DeviceSnapshotCollector + SessionDetector + SubprocessRunner |
| [#27](https://github.com/cli-pulse/cli-pulse-private/pull/27) | Slice 2b | No (internal) | AlertGenerator + OAuthBackoff + KeychainReader |
| [#28](https://github.com/cli-pulse/cli-pulse-private/pull/28) | Slice 2c | No (internal) | 3 Quota fetchers (Claude/Codex/Gemini) + QuotaProvenance |
| [#29](https://github.com/cli-pulse/cli-pulse-private/pull/29) | Slice 2d | No (internal) | SystemCollector facade + ClaudeSnapshotWriter |

The customer-visible delta from v1.12.0 → v1.12.3 is:
- **Privacy toggle no longer lies** for users who hadn't toggled `remote_control_enabled` or `track_git_activity` before (M4 fix in v1.12.1).
- **5 new credential redaction patterns** prevent Stripe live-key leaks via the helper's stdout uploader (M1 in v1.12.1).
- **`rm  -rf` (double-space) and split-flag forms now correctly classified HIGH** by the remote-approval risk classifier (M3 in v1.12.2).
- **Per-RPC 2.5s HTTP timeout** caps a single hung Supabase call (M2 in v1.12.2).

The Phase 4D + Phase 4E Slice 2 work is **shipped in the bundle but not activated** — the Python helper continues to be the live LaunchAgent runtime. The Swift HelperKit code is dead code on disk for v1.12.3, intentionally. Phase 4E Slices 3+4 (cloud-sync port + LaunchAgent cutover) are deferred to v1.13.

## Files changed

| File | Change |
|---|---|
| `CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj` | 20 occurrences updated: `MARKETING_VERSION = 1.12.0` → `1.12.3` and `CURRENT_PROJECT_VERSION = 48` → `49` |
| `CLI Pulse Bar/CLI Pulse Bar/Info.plist` | `<string>1.12.0</string>` → `<string>1.12.3</string>` (CFBundleShortVersionString) |
| `CLI Pulse Bar/CLI Pulse Bar iOS/Info.plist` | same |
| `CLI Pulse Bar/CLI Pulse Bar Watch/Info.plist` | same |
| `CLI Pulse Bar/CLI Pulse Widgets/Info.plist` | same |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/PDFReportGenerator.swift` | fallback string in `appVersion` accessor updated `1.12.0` → `1.12.3` |

## Verification

| Step | Result |
|---|---|
| `xcodebuild -scheme "CLI Pulse Bar" -configuration Release clean build` | **BUILD SUCCEEDED** (post version bump) |
| `swift test --package-path HelperSwift` | 243/243 passed (verified at slice 2d merge) |
| `swift test --package-path "CLI Pulse Bar/CLIPulseCore"` | 918/918 passed (verified at sanity check) |
| `python3 -m pytest helper/` | 413/413 passed (verified at sanity check) |
| All blocking CI green on PRs #21-29 | Confirmed at each merge |

## What this release does NOT do

- **Does NOT activate the Phase 4E Swift helper.** The Python helper (`helper/cli_pulse_helper.py`) remains the LaunchAgent runtime. Slice 4 cutover is v1.13's task.
- **Does NOT include Phase 4E Slice 3** (RemoteAgentCloud — cloud-sync port). Deferred to v1.13.
- **Does NOT include Slice 2c.5** (ChromiumCookieReader, Claude OAuth refresh, Gemini OAuth refresh). Python helper continues to serve those paths.
- **Does NOT include any UI changes.** All deltas from v1.12.0 are privacy + classifier + redaction fixes operating below the UI layer, plus dead-code Swift port additions.

## ASC submission steps (Jason's call per `feedback_appstore_update.md`)

When Jason chooses to submit:

1. Verify `xcodebuild archive -scheme "CLI Pulse Bar" -archivePath /tmp/v1.12.3.xcarchive -configuration Release` succeeds.
2. Validate via `xcodebuild -exportArchive -archivePath /tmp/v1.12.3.xcarchive -exportPath /tmp/v1.12.3-export -exportOptionsPlist ...`.
3. Upload via `altool` or `Transporter.app` with the API key from `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_*.p8`.
4. In ASC, create the iOS+macOS submission for v1.12.3, releaseType=AFTER_APPROVAL.
5. Apple typically reviews in 24-48 h.

The build artifacts and version bumps in this PR are the prerequisite — actual upload waits for Jason's go signal per the autonomy contract.

## Cross-team note

Mac v1.12.3 represents the full backport of the Mac M1-M4 Windows alignment items + Phase 4D HelperKit + Phase 4E Slice 2 system collection. Windows v0.7.0 is unaffected; v0.8.0 (ConPTY) ships independently per their own track.
