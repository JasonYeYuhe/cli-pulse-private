# PROJECT_FIX v1.9.7 — P1-5: Android CI AAB + mapping upload

**Date**: 2026-04-21
**Scope**: `.github/workflows/android-ci.yml` only.

---

## Why

Plan P1-5 flagged two gaps: (1) CI built an APK but never captured it as
an artifact; (2) no instrumented tests against the `MIGRATION_1_2` Room
migration. Part (1) is a release-hygiene hole — if a release CI run is
green but the artifact isn't downloadable, we lose the chain between
commit SHA and ship-ready bundle.

## What shipped

### `android-ci.yml`
- Added `bundleRelease` to the `./gradlew assembleRelease` step (now
  `./gradlew assembleRelease bundleRelease`)
- New step: upload `app/build/outputs/bundle/release/*.aab` as artifact
  `release-aab-<sha>`, 30-day retention, `if-no-files-found: error`
- New step (per Codex review): upload
  `app/build/outputs/mapping/release/mapping.txt` as
  `release-mapping-<sha>`, 30-day retention, `if-no-files-found: warn`
  (R8 minification is on — mapping is required to symbolicate Play
  Console crashes)

## Deferred

- **connectedAndroidTest + Room migration test**
  GitHub Ubuntu runners lack KVM for Gradle Managed Devices. Shipping
  this path would need:
  1. macOS runners (slow + $$) **or** Robolectric + room-testing
     dependency with a JVM-friendly migration helper
  2. New `androidTest/` or Robolectric test source root
  3. Migration test file + build.gradle wiring
  Not cheap enough to clear Codex's "same session" bar. Tracked as
  a separate v1.9.7+ task.

## Verification

- `android/app/build/outputs/bundle/release/app-release.aab` exists
  locally from previous builds — confirms `bundleRelease` is a valid
  Gradle task in this project (can't run it fresh in this session due
  to local JAVA_HOME not being on PATH)
- Signing env vars (`STORE_PASSWORD`, `KEY_PASSWORD`) are already
  plumbed from Secrets in the existing `assembleRelease` step, so
  adding `bundleRelease` reuses the same signing config

## Separate note (outside scope but flagged)

Codex noticed `android/app/build.gradle.kts:35` still has
`versionName = "1.9.5"`. We're working on v1.9.7. The version bump
is a separate release task and not in P1-5's scope.

## Files changed

```
.github/workflows/android-ci.yml                   (added bundleRelease + 2 artifact steps)
docs/PROJECT_FIX_v1.9.7_p1_5_android_ci.md         (this doc)
```

## Review audit trail

- **Codex rescue** — **ship-with-notes**. Confirmed pattern is right,
  `if-no-files-found: error` is correct failure mode, deferring the
  instrumented test is acceptable given no existing `androidTest/`
  tree. Suggested `mapping.txt` upload — actioned.
