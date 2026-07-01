# PROJECT FIX — helper .pkg build: durable fix for the Uninstaller.app codesign xattr race

**Date:** 2026-07-01 · **Found by:** the v1.22.0 helper `.pkg` build (Step 3b hard-failed).

## Problem
`scripts/build_helper_pkg.sh` aborted at Step 3b (embed Uninstaller.app) when
`build_helper_uninstaller.sh` signed the app:

```
CLI Pulse Helper Uninstaller.app: resource fork, Finder information, or similar detritus not allowed
```

The script already ran `xattr -cr "$APP_BUNDLE"` immediately before `codesign` (the
v1.16.1/1.16.2 hotfixes), but the build directory lives under `~/Documents/` which is
**iCloud "Desktop & Documents" synced**. The `fileprovider`/`mds` daemons **re-attach
`com.apple.FinderInfo` in the window between `xattr -cr` and `codesign`** — a race the
build loses intermittently. It won on the v1.19.0/v1.20.0 builds and lost on v1.22.0.
`set -e` then aborted the whole pipeline (no `.pkg` produced).

## Fix (durable)
`scripts/build_helper_uninstaller.sh` Step 3 now **signs the bundle in a non-indexed
temp dir**, then copies the signed bundle back:

```sh
SIGN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/uninstaller-sign.XXXXXX")"
cp -R "$APP_BUNDLE" "$SIGN_TMP/$APP_NAME"
xattr -cr "$SIGN_TMP/$APP_NAME"
codesign --force --timestamp --options runtime --sign "$DEV_ID_APP" "$SIGN_TMP/$APP_NAME"
codesign --verify --strict --verbose=2 "$SIGN_TMP/$APP_NAME"   # --strict is safe: temp dir isn't indexed
rm -rf "$APP_BUNDLE"; cp -R "$SIGN_TMP/$APP_NAME" "$APP_BUNDLE"; rm -rf "$SIGN_TMP"
```

Nothing re-attaches `com.apple.FinderInfo` in a temp dir, so the sign wins the race.
`pkgbuild` stores the payload in a xar/cpio archive that does **not** carry extended
attributes, so a FinderInfo xattr re-attached to the copied-back bundle never reaches
the `.pkg` and never touches the (embedded, byte-preserved) code signature. This also
lets us restore the stricter `--verify --strict`.

## Belt-and-suspenders for this run
The v1.22.0 build was additionally run with `--output-dir /private/tmp/clipulse-helper-build`
so the **entire** pipeline (PyInstaller staging + the Step-4 main-helper signing, which
has no `xattr` strip of its own) also ran outside `~/Documents`, dodging the race
everywhere.

## Latent follow-up (not blocking)
`build_helper_pkg.sh` Step 4 (main-helper Mach-O signing) has the same theoretical race
when run with the default `--output-dir` under `~/Documents` (it does no `xattr -cr`
before signing). It didn't bite because we build in `/tmp`. A future hardening could add
the same temp-dir-sign pattern (or a pre-sign `xattr -cr "$STAGING"`) to Step 4. Tracked
here rather than fixed to keep this change surgical.

## Verification
- v1.22.0 `.pkg` built end-to-end: notarytool **Accepted**, stapler validated, spctl
  **accepted**; live-download from the release URL sha-matches + Gatekeeper-accepts.
- CI unaffected (GitHub runners aren't under `~/Documents`; the temp-dir sign is a no-op
  behavior change there).

See `feedback_icloud_dup_artifacts` (iCloud repo hazards), `feedback_v116_helper_pkg_shipped`.
