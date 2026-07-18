# PROJECT_FIX — v1.19 Developer ID DMG distribution channel foundation (2026-05-12)

## Summary

Stand up a second distribution channel for CLI Pulse Mac running
parallel to the existing Mac App Store (MAS) path: Developer ID
notarized `.dmg`, hosted on a new public GitHub repo
(`cli-pulse-distrib`), consumed in-app via a new `AppUpdater` (manifest
fetch + SHA-256 verify + URLSession download + Finder handoff).

Foundation ships in this commit. Real Developer ID sign + notarize +
clean-Mac smoke + public repo creation + first release are gated on
user authorization (version bump to v1.19.0 + `gh repo create
cli-pulse-distrib`).

## Why

Three pre-built branches (`v1.18.2-impl`, `v1.18.x-helper-label-collision`,
`v1.18.x-helper-config-bridge`) are MAS-strip-inert today: under MAS
distribution, `build-appstore.sh` strips the unsandboxed
`cli_pulse_helper` LaunchAgent and re-signs with Apple Distribution,
so Phase 4D/4E fixes never run in production. They sit unused
awaiting a ship vehicle. The DMG channel is that vehicle.

Secondary motivation: ASC review queue (1-5 day median for macOS) is
the iteration bottleneck. macOS v1.18.1 has been in WAITING_FOR_REVIEW
for ~28h as of this work. DMG channel lets us ship in ~30 minutes from
commit.

## How shipped — file inventory

### Build pipeline

| File | Change | Purpose |
|---|---|---|
| `scripts/build_signed_app.sh` | modified | Add `CODESIGN_TIMESTAMP` env opt-in (switches `--timestamp=none` → `--timestamp` for notarization-compatible signatures) + `DEVID_BUILD_FLAG` env opt-in (sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEVID_BUILD`). Backward-compatible: CI's default-args call works exactly as before. |
| `scripts/build_devid_dmg.sh` | NEW | Orchestrate build → sign → notarize-app → DMG → sign-dmg → notarize-dmg → staple → manifest-fragment. G8 parameterization: notarytool credentials use inline flags when `APPLE_NOTARY_USER + APPLE_NOTARY_APP_PASSWORD + APPLE_TEAM_ID` all set (CI-friendly); else fall back to `AC_NOTARY_PROFILE` keychain. |

### App-side updater (CLIPulseCore)

| File | Change | Purpose |
|---|---|---|
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppUpdater.swift` | NEW | State machine (`checking`/`upToDate`/`updateAvailable`/`downloading`/`readyToInstall`/`error`). G2: `install()` opens DMG in Finder then `NSApp.terminate(nil)` 500ms later (drag-replace requires app quit). G7: manifest fetch uses `.reloadIgnoringLocalCacheData` cache policy. Manifest schema extends HelperInstaller's with `build` + `channel` fields. |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/HelperInstaller.swift` | modified | G7 retrofit: same cache-policy fix on the helper-manifest fetch (latent same-class bug). |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppPermissionMigrationChecker.swift` | NEW | G1: detect TCC permission revocations on MAS → DEVID migration (cert chain change → Designated Requirement change → silent permission revoke). Snapshot writer runs on both MAS and DEVID launches; DEVID-only comparison + nudge logic. Read-only — no `requestAuthorization` calls (owned by `DataRefreshManager`). |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift` | modified | Wire `@Published var appUpdater` (gated `#if os(macOS) && DEVID_BUILD`) + `@Published var permissionMigrationChecker` (macOS-only, runs on both channels). Add `runOnLaunch()` invocation to AppState init macOS block. |

### UI

| File | Change | Purpose |
|---|---|---|
| `CLI Pulse Bar/CLI Pulse Bar/AppUpdaterSection.swift` | NEW | SwiftUI section in Settings. Three banners: G1 permission migration nudge (conditional, with deep-links to System Settings + dismiss), G5 MAS auto-update warning (permanent banner reminding beta users to disable App Store auto-updates), and the state-machine UI mirroring `CompanionCLISection`. Gated `#if DEVID_BUILD` so MAS builds compile out the whole file. |
| `CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift` | modified | Insert `AppUpdaterSection` right after `CompanionCLISection`, gated `#if DEVID_BUILD`. |
| `CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj` | modified | Add `AppUpdaterSection.swift` file reference + sources-build-phase entry. Done via `xcodeproj` Ruby gem (safer than sed; same pattern as B3). |

### Tests

| File | Change | Purpose |
|---|---|---|
| `CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/AppUpdaterTests.swift` | NEW | 8 tests covering `compareVersions`, `assertArchitectureMatches`, manifest decode (minimal fields + full fields), `installedVersion`. All pass. |

### Docs

| File | Change | Purpose |
|---|---|---|
| `docs/v1.19_DEVID_CHANNEL.md` | NEW | Operating notes: pipeline, env vars, notarytool credential modes, release flow (gated on user auth), rollback pattern. Cross-references all related memory + code paths. |

## Plan adjudication trail

Wrote a comprehensive plan at
`/Users/jason/.claude/plans/state-on-2026-05-12-unified-canyon.md`
covering the full v1.19 scope. Sent to Gemini 3.1 Pro for review; all
8 findings adopted:

| # | Severity | Finding | Disposition |
|---|---|---|---|
| G1 | CRITICAL | TCC permission revocation on MAS → DEVID swap (Designated Requirement change) | ADOPTED — `AppPermissionMigrationChecker` + nudge banner in `AppUpdaterSection` |
| G2 | CRITICAL | Finder can't drag-replace a running .app | ADOPTED — `AppUpdater.install()` quits self after opening DMG |
| G3 | CRITICAL | Sandboxed download → DMG lives in container/tmp/ hidden from user | PARTIAL ADOPT — replicate HelperInstaller's `NSWorkspace.open(NSTemporaryDirectory()-relative URL)` pattern; verify in clean-Mac smoke; fall back to `~/Downloads/` write if needed |
| G4 | SHOULD_FIX | Sandbox + Sparkle are fundamentally incompatible | ADOPTED — plan note: custom DMG flow is permanent for sandboxed builds; Sparkle would require dropping sandbox |
| G5 | SHOULD_FIX | MAS auto-update silent overwrite of DEVID install | ADOPTED — permanent banner in AppUpdaterSection with deep-link to App Store settings |
| G6 | SHOULD_FIX | StoreKit-receipt-validated backend may 403 DEVID requests | ADOPTED-DEFERRED — local-only premium for v1.19.0; backend allow-list bypass via `X-CLI-Pulse-Channel: beta` header in v1.19.1 (backend schema touch needs user auth) |
| G7 | SHOULD_FIX | URLSession default cache can mask new manifests | ADOPTED — both AppUpdater AND HelperInstaller use `.reloadIgnoringLocalCacheData` |
| G8 | SUGGEST | Parameterize notarytool credentials for CI | ADOPTED — `build_devid_dmg.sh` honors `APPLE_NOTARY_USER` / `APPLE_NOTARY_APP_PASSWORD` / `APPLE_TEAM_ID` env vars, falls back to keychain profile |

## What's NOT in this commit

Deliberate scope-bounding for v1.19.0 MVP:

- ❌ SubscriptionManager `#if DEVID_BUILD` short-circuit to return
  `.premium` tier (~30min follow-up; documented in
  `docs/v1.19_DEVID_CHANNEL.md`)
- ❌ Real Developer ID sign + notarize + clean-Mac smoke (gated on
  v1.19.0 version bump + `gh repo create cli-pulse-distrib` user auth)
- ❌ Public repo creation + first release publish
- ❌ Merging B3, B3-bis, v1.18.2 to main (still on stacked branches
  pending user OK)
- ❌ CI workflow extension for `build_devid_dmg` job (deferred to v1.19.1)
- ❌ Server-side `X-CLI-Pulse-Channel: beta` allow-list (G6 follow-up;
  backend schema touch needs user auth per `feedback_cli_pulse_autonomy`)
- ❌ Sparkle 2 migration (G4 fundamentally blocked by sandbox; possible
  in v1.20+ if sandbox drop is approved)
- ❌ Universal x86_64 binary (arm64-only per
  `feedback_v116_helper_pkg_shipped` §3)
- ❌ Phase 4D/4E Swift LaunchAgent runtime cutover (B3 + B3-bis sit
  in the bundle, MAS-strip-inert; their activation lives in v1.19.x
  or v1.20)

## Verification

### Build tests (PASSED)

- `cd "CLI Pulse Bar/CLIPulseCore" && swift build` — Build complete!
- `cd "CLI Pulse Bar/CLIPulseCore" && swift build -Xswiftc -DDEVID_BUILD` — Build complete!
- `xcodebuild -scheme "CLI Pulse Bar" -configuration Debug build CODE_SIGNING_ALLOWED=NO ...` — BUILD SUCCEEDED
- `xcodebuild -scheme "CLI Pulse Bar" -configuration Debug build ... SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(inherited) DEVID_BUILD"` — BUILD SUCCEEDED

### Test suite (PASSED)

- `swift test --filter AppUpdaterTests` — 8/8 pass
- `swift test --filter HelperInstallerTests` — 5/5 pass (no regression from G7 retrofit)

### Structural smoke (PASSED)

`bash scripts/build_devid_dmg.sh --skip-sign --output-dir /tmp/cli-pulse-v1.19-smoke`:

- ✅ build_signed_app.sh built helper + macOS app with ad-hoc signing
- ✅ Helper embedded at `Contents/Helpers/cli_pulse_helper`
- ✅ LaunchAgent plist at `Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.agent.plist`
- ✅ Bottom-up codesign worked; sandbox + app-group entitlements preserved
- ✅ `hdiutil create` produced 16MB DMG
- ✅ SHA-256 + manifest-fragment-arm64.json emitted

Manifest sample output:
```json
{
  "version": "1.18.1",
  "build": "57",
  "channel": "devid",
  "arch": "arm64",
  "url": "https://github.com/cli-pulse/cli-pulse-distrib/releases/download/app-v1.18.1/CLI-Pulse-1.18.1-arm64.dmg",
  "sha256": "752e018a1f34af463616a705e18530723de851f390d84b9996dda3cedbb11fab",
  "size_bytes": 16939442,
  "min_os_version": "13.0",
  "release_notes_url": "https://github.com/cli-pulse/cli-pulse-distrib/releases/tag/app-v1.18.1"
}
```

### Deferred verification (requires user-authorized ship steps)

- ❓ Real Developer ID sign + notarize via `xcrun notarytool submit
  --wait` (consumes Apple notary quota; needs v1.19.0 version bump)
- ❓ `spctl --assess` on the notarized DMG (only validates with real
  Developer ID signature + stapler)
- ❓ Clean-Mac install smoke per [feedback_v080_crash_on_launch_incident](../docs/feedback_v080_crash_on_launch_incident.md)
  (MANDATORY before any DMG promotion to `latest.json`)
- ❓ AppUpdater state-machine smoke against the published manifest

## Branch state

- Work branch: `v1.19-devid-impl`
- Parent: `v1.18.x-helper-config-bridge` (HEAD 390f687) — which is
  on top of `v1.18.x-helper-label-collision` (B3, 93cb0d4) — which is
  on top of `v1.18.2-impl` — which is off `main`.
- Three commits on this branch:
  - `0635e30` — v1.19 foundation: AppUpdater + build_devid_dmg.sh pipeline (build pipeline + AppUpdater + AppState wire + tests)
  - (this commit) — UI + permission migration + docs
- Total branch delta vs B3-bis: ~1100 LOC new + ~50 LOC modified, across 11 files.

## Anti-footgun reminders for next session

- B3, B3-bis, v1.18.2 are NOT in `main`. v1.19 is NOT in `main`. No
  public-remote pushes have happened.
- ASC `v1.18.1` macOS train is unaffected — review continues
  naturally; no DEVID work touches it.
- `cli-pulse-distrib` repo does NOT exist yet — creation needs user
  authorization per autonomy contract.
- Real Developer ID notarize runs consume Apple notary quota; the
  next session should bump app version to `1.19.0` BEFORE the first
  real run so the artifact name matches the intended ship version.

## Related memory

- [[reference_devid_installer_cert]] — Developer ID Application cert details
- [[reference_helper_releases_repo]] — proven manifest pattern (mirror for cli-pulse-distrib)
- [[feedback_keychain_notary_vanished]] — defensive password file already in place
- [[feedback_mas_vs_devid_helper]] — why this channel must exist
- [[feedback_loginitem_launchagent_collision]] — B3 + B3-bis are the riders on this channel
- [[feedback_v080_crash_on_launch_incident]] — mandatory clean-Mac smoke gate before promotion
- [[feedback_cli_pulse_autonomy]] — autonomy contract; public-repo writes need explicit auth
- [[feedback_appstore_update]] — v1.19 does NOT submit anything to ASC
