# CLI Pulse Release Workflow

Source of truth: 4-channel ship across Mac DEVID DMG, Mac App Store
(MAS), iOS App Store, and Android Google Play. Plus a sidecar helper
.pkg channel for users on DEVID. Last rewritten 2026-05-15 (was
previously describing a stale 2-version-old macOS-only flow).

## Repo Topology

| Remote | URL | Visibility | Role |
|---|---|---|---|
| `origin` | `JasonYeYuhe/cli-pulse-private` | Private | All source: app, helper, backend, tests, internal docs |
| `public` | `JasonYeYuhe/cli-pulse` | Public | `README.md`, `PRIVACY.md`, `TERMS.md`, `docs/` (Pages), release notes — NO source |
| (n/a) | `JasonYeYuhe/cli-pulse-distrib` | Public | DEVID DMG release artifacts (`app-vX.Y.Z` tag) + `latest.json` manifest |
| (n/a) | `JasonYeYuhe/cli-pulse-helper-releases` | Public | Helper `.pkg` release artifacts + `latest.json` manifest |

Never push product source to `public`. The pre-push hook
(`.githooks/pre-push`) blocks accidents.

## Channels overview

| Channel | Target | Build script | Upload target | CI workflow |
|---|---|---|---|---|
| DEVID DMG | macOS users with `Developer ID Application` notarized DMG | `scripts/build_devid_dmg.sh` (or `.github/workflows/devid-dmg.yml` via `workflow_dispatch`) | `cli-pulse-distrib` GitHub release | `devid-dmg.yml` |
| Mac App Store | Mac users via MAS sandbox | `CLI Pulse Bar/scripts/build-appstore.sh` | App Store Connect (Transporter/altool) | none (local-only) |
| iOS App Store | iPhone + iPad + Watch | Same `build-appstore.sh` (iOS scheme) | App Store Connect | none (local-only) |
| Android Play Store | Android | `./gradlew bundleRelease` (under `android/`) | Play Console (manual upload) | `android-ci.yml` (test only; AAB build needs keystore secret not yet wired) |
| Helper .pkg | DEVID-channel users with self-managed helper | `scripts/build_helper_pkg.sh` | `cli-pulse-helper-releases` GitHub release | none (local-only) |

## Pre-ship validation

Before any ship, in the source root:

```bash
# Helper Python
(cd helper && python -m pytest -q)
# Swift package
swift test --package-path "CLI Pulse Bar/CLIPulseCore"
# Android unit tests (needs Android Studio JBR java in PATH)
(cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
    ./gradlew testDebugUnitTest --no-daemon)
# Helper Swift package
swift test --package-path HelperSwift
```

Then a local Xcode smoke build of the target scheme + a manual
launch of the built `.app` is mandatory for any Apple channel.

## Version bump

Single source of truth: `MARKETING_VERSION` in
`CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj`. The 5
embedded `Info.plist` files reference `$(MARKETING_VERSION)` so
bumping one place propagates to all (D8 in v1.20 plan).

Android: edit `android/app/build.gradle.kts` `versionName` +
`versionCode`.

`scripts/sync-versions.sh --dry-run` should be CI-gated on pushes
that touch `project.pbxproj` or Android `build.gradle.kts` to
catch drift between platforms (v1.21 G6).

## Signing credentials

Apple side — both DEVID and MAS:

- Distribution cert at `~/Library/Application Support/CLI-Pulse-Secrets/apple-distribution-2026-05-13/`
- Developer ID Application cert at `~/Library/Application Support/CLI-Pulse-Secrets/devid-application-2026-05-14/`
- App Store Connect API key (`.p8` + key-id + issuer-id) used by
  `build-appstore.sh` for ASC upload — see
  `reference_appstore_creds` memory.
- Notarytool — `AC_NOTARY_PROFILE` keychain profile has been
  unreliable on macOS 26.x (memory `feedback_keychain_notary_vanished`).
  Inline env vars (`xcrun notarytool submit --apple-id ... --team-id ... --password ...`) is the
  reliable path.

Android:

- Upload keystore at `~/Library/Application Support/CLI-Pulse-Secrets/cli-pulse-upload.jks`
  (memory `reference_google_play_signing`).
- CI does NOT have the keystore today, so CI's `bundleRelease`
  step fails. AAB build runs locally for now.

## DEVID DMG ship

```bash
# Bump MARKETING_VERSION + Android version
# Edit project.pbxproj + build.gradle.kts + commit
./scripts/build_devid_dmg.sh   # → ~/Library/Caches/CLI-Pulse-Bar-release/CLI-Pulse-Bar-vX.Y.Z-<arch>.dmg
# Upload to cli-pulse-distrib
gh release create "app-vX.Y.Z" "<dmg-path>" -R JasonYeYuhe/cli-pulse-distrib \
    --title "CLI Pulse Bar vX.Y.Z" --notes-file docs/release-notes/vX.Y.Z.md
# Promote to latest (after clean-Mac smoke!)
# update cli-pulse-distrib's latest.json to point to the new tag
```

Or, on a clean GitHub-hosted runner via `.github/workflows/devid-dmg.yml`:
trigger `workflow_dispatch` with version input. Builds + signs +
notarizes + uploads in one ~25-min run.

## MAS + iOS ship

```bash
cd "CLI Pulse Bar"
./scripts/build-appstore.sh --target=mac    # MAS build
./scripts/build-appstore.sh --target=ios    # iOS build
# Both upload to ASC via altool / asc-rest API. Then in ASC Web:
# 1. Add the new build to the version
# 2. Fill in "What's New"
# 3. Submit for review
```

Five ASC gotchas codified in `build-appstore.sh` per memory
`feedback_asc_release_workflow`. Per-version `submit_v*.py` script
proliferation should be replaced by a single
`scripts/submit_asc.py` + `docs/release-notes/vX.Y.Z.md` (deferred
to v1.22 — R-F1).

## Helper .pkg ship

```bash
./scripts/build_helper_pkg.sh             # → dist/cli-pulse-helper-vX.Y.Z.pkg
# Notarize + staple
xcrun notarytool submit ... && xcrun stapler staple ...
# Upload to cli-pulse-helper-releases
gh release create "v1.18.0" "<pkg-path>" -R JasonYeYuhe/cli-pulse-helper-releases \
    --title "Helper v1.18.0"
# Update releases/download/latest/latest.json to point at the new tag
```

Code at `HELPER_VERSION=1.18.0` in `scripts/build_helper_pkg.sh`.
Production `.pkg` published at 1.17.3 currently; A1 in v1.20 plan
covers the publish.

## Android ship

```bash
(cd android && ./gradlew bundleRelease)   # → app/build/outputs/bundle/release/app-release.aab
# Manual upload to Play Console
# Internal track → 10% staged rollout → 100%
```

## Public repo distribution work

After the release artifacts are uploaded:

1. `docs/release-notes/vX.Y.Z.md` committed to private repo.
2. Public repo (`public` remote) gets release notes published (and
   any `docs/` updates that should ship publicly).
3. Public GitHub Release on `JasonYeYuhe/cli-pulse` if we want a
   discoverable changelog separate from the channel-specific repos.

## Post-ship verification

- DEVID: download from `cli-pulse-distrib` `latest.json`, install on
  a clean Mac, launch, verify version + Sentry event arrives.
- Apple: TestFlight or ASC build status visible.
- Play: internal track installable, Sentry Android event arrives.
- Helper: install `.pkg`, watch helper restart, verify version log.

Reference incident: `feedback_v080_crash_on_launch_incident` —
skipping the clean-machine smoke is what produced v0.8.0's
crash-on-launch on Windows. Same discipline applies to all four
channels.

## Forbidden in `public`

- App source
- Helper source
- Backend SQL or edge functions
- Test files
- Internal `PROJECT_FIX_*.md` / `PROJECT_PLAN_*.md` notes
- Credentials of any kind

## Quick checklist

- [ ] Tests pass: helper pytest + Swift CLIPulseCore + Android unit + HelperSwift
- [ ] Version bumped in project.pbxproj + build.gradle.kts (sync-versions.sh)
- [ ] All 4 channels built (DEVID DMG, MAS, iOS, Android AAB)
- [ ] All 4 channels uploaded (cli-pulse-distrib, ASC×2, Play Console)
- [ ] Helper .pkg published if helper version changed
- [ ] Release notes committed to private repo + published to public repo
- [ ] Clean-Mac / clean-Android smoke verified before promoting to "latest"
- [ ] Sentry shows post-release events tagged with new version
