# PROJECT FIX — R4-prep: dSYM/Sentry upload for the Developer-ID DMG build

**Date:** 2026-06-29
**Train:** v1.34 ship (R4 — promote/release prep)
**Area:** `scripts/build_devid_dmg.sh`
**Origin:** Gemini 3.1 Pro DEV_PLAN review ("don't ship blind") — the MAS path
uploads dSYMs in `build-appstore.sh`, but the DEVID DMG path did not, so
Developer-ID production crashes came back unsymbolicated.

## Problem
`build_devid_dmg.sh` builds + notarizes the Developer-ID DMG but never uploaded
dSYMs to Sentry. v1.34 (in-app terminal + the OAuth/billing change) ships on the
DEVID channel, so any production crash there would be unsymbolicated.

## Fix
Add a Sentry dSYM upload mirroring the proven `build-appstore.sh` approach
(same `SENTRY_ORG=jason-yeyuhe`, token-file path, `apple-macos` project slug):
- `load_sentry_auth_token()` + `upload_dsyms_to_sentry()` helpers.
- Adapted for the DEVID build's lack of an xcarchive: `build_signed_app.sh` runs
  `xcodebuild build` (not `archive`), so dSYMs land alongside the `.app` in
  `$APP_STAGING/DerivedData/Build/Products/Release/*.dSYM`. The new step collects
  the top-level `*.dSYM` (app + framework dSYMs, `-maxdepth 1` to avoid walking
  the `.app`) into a flat dir and uploads it, then finalizes the Sentry release
  `cli-pulse@${APP_VERSION}+${APP_BUILD}`.
- Runs as **Step 2b**, after build/hoist and BEFORE notarization — codesign /
  notarization do not change the Mach-O `LC_UUID`, so the pre-notarized dSYMs
  match the shipped binary exactly.
- Gated to real signed release builds (`SKIP_SIGN==0 && DRY_RUN==0`); a
  `--skip-sign` run is a throwaway test and must not pollute Sentry.
- **Best-effort:** every guard (no `sentry-cli`, no token, no dSYMs) skips with a
  warning and returns 0 — the DMG build never fails on a dSYM-upload problem.

## Review fix applied (Gemini 3.1 Pro)
`load_sentry_auth_token()` did `extracted=$(grep … | head | cut …)` on its own
line; under `set -euo pipefail` a no-match `grep` (exit 1) or `head` SIGPIPE
(141) would abort the **entire** build. Added `|| true` inside the subshell so
the loader stays best-effort. (Codex: no further issues; confirmed `OUTPUT_DIR`
is globally initialized, spaces handled, UUID-before-notarize correct, the
`| sed` pipeline doesn't mask the upload exit code under `pipefail`.)

## Verification
- `bash -n` clean; `--skip-sign --dry-run` completes and correctly skips Step 2b.
- No PR-level CI runs `build_devid_dmg.sh` (only `devid-dmg.yml` on an `app-v*`
  tag), so this was validated by static review (Gemini 3.1 Pro + Codex) + dry-run.
- **Owner note:** for CI (`devid-dmg.yml`) to actually upload, wire a
  `SENTRY_AUTH_TOKEN` secret; otherwise it skips gracefully. Local runs read the
  token from `~/Library/Application Support/CLI-Pulse-Secrets/…`.

## Follow-up (out of scope, flagged)
`CLI Pulse Bar/scripts/build-appstore.sh` has the same `extracted=$(…)` pattern
without `|| true` — same latent abort if the token file exists without the line.
