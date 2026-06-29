# PROJECT FIX — R1b: make build_signed_app.sh LoginItem signing strict (match the verifier)

**Date:** 2026-06-29
**Train:** v1.34 ship (R1 pre-ship hardening)
**Area:** `scripts/build_signed_app.sh`
**Origin:** Gemini 3.5 Flash finding #4 on the in-app-terminal/OAuth changeset
(build-script consistency).

## Problem
`build_signed_app.sh` had an internal inconsistency about whether the embedded
LoginItem (`Contents/Library/LoginItems/CLIPulseHelper.app`) is mandatory:

- **Signing step (step 6):** guarded by `if [[ -d "$LOGIN_ITEM_APP" ]]` — a
  missing LoginItem was a soft `else` skip ("note: no LoginItem … skipping").
- **Verifier step (step 7):** asserts the LoginItem present **unconditionally**
  (`check(os.path.isdir(login_app), "LoginItem not found …")`).

So a missing LoginItem would silently skip signing and then fail the verifier
with a more confusing error. Worse, the bottom-up nested-bundle re-sign earlier
in the script re-signs nested `.app`s with **no** entitlements — so if the
explicit LoginItem re-sign were ever skipped, the LoginItem would ship
entitlement-stripped (sandbox/app-group/keychain gone), which taskgated rejects
at `SMAppService.loginItem` launch.

## Fix
Make the signing step equally strict — assert the LoginItem present (the
verifier's stance is the correct one). Replace the
`if [[ -d ]] … else (note+skip)` with a hard guard:

```bash
[[ -d "$LOGIN_ITEM_APP" ]] || {
    echo "error: LoginItem missing at $LOGIN_ITEM_APP — expected Xcode to embed …" >&2
    exit 2
}
```

followed by the (now-unconditional) entitlement expansion + `codesign`. A missing
LoginItem now fails **here**, early and clearly, instead of slipping through
unsigned. The LoginItem is always present in a real build (Xcode Copy Files
phase / target dependency), so this never triggers on a valid build.

## Verification
- `bash -n scripts/build_signed_app.sh` — syntax OK.
- CI's **"Signed-app reproducible build (Phase 4D)"** job runs this script
  end-to-end and the step-7 verifier already proves the LoginItem is present on
  every green run — so a green PR proves the new hard-assert doesn't fire on a
  valid build (and the signed LoginItem is verified semantically). This is the
  authoritative validator for a build-script change.

## Notes
MAS path (`CLI Pulse Bar/scripts/build-appstore.sh` via xcodebuild) is untouched.
