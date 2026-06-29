# PROJECT FIX — R4-prep (CI): install sentry-cli + wire token in devid-dmg.yml

**Date:** 2026-06-29
**Train:** v1.34 ship (R4-prep, CI side)
**Area:** `.github/workflows/devid-dmg.yml`

## Problem
PR #253 added a Sentry dSYM upload to `build_devid_dmg.sh` (Step 2b). When the
v1.34 DMG was staged via the `app-v1.34.0` CI tag, Step 2b **ran but skipped**:
`"⚠ sentry-cli not installed — skipping dSYM upload."` The `devid-dmg.yml` runner
has no `sentry-cli`, and the build step didn't pass `SENTRY_AUTH_TOKEN`. So the
best-effort guard worked (no build failure), but v1.34 DEVID crashes would not
symbolicate from a CI-built DMG.

## Fix
- Add an `Install sentry-cli` step (`brew install getsentry/tools/sentry-cli || true`,
  matching `build-appstore.sh`) before the build — best-effort so a brew hiccup
  can't fail a release build.
- Pass `SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}` into the build step's
  env (build_devid_dmg.sh `load_sentry_auth_token` checks the env first).

Once the **owner adds the `SENTRY_AUTH_TOKEN` repo secret** (org scope: Source Map
Upload + Release Creation), future `app-v*` tag builds upload dSYMs automatically.
Without the secret it still skips cleanly.

## Note on the already-staged v1.34.0 DMG
The `app-v1.34.0` DMG already in `cli-pulse-distrib` was built BEFORE this fix, so
its dSYMs are not in Sentry. Options for the owner:
- Upload locally: `sentry-cli debug-files upload --org jason-yeyuhe --project
  apple-macos <dSYMs>` (dSYMs match by Mach-O UUID, which codesign/notarize don't
  change), OR
- Add the secret, then delete + re-push the `app-v1.34.0` tag to re-run the build.

## Verification
- `ruby -ryaml` parse: YAML OK.
- The build step's dSYM skip path is proven (it ran + skipped gracefully in the
  v1.34.0 CI run, exit 0).
