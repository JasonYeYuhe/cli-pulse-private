# Fan control — ship runbook (DEVID only)

Everything code/build/test is done and **hardware-validated** (real-fan selftest: boost holds, revert, heartbeat-lapse revert, crash-recovery revert — see `SAFETY.md`). What remains is packaging a **root daemon** into the signed app + publishing. Two steps are owner-only and cannot be automated:

- 🔒 **macOS forces a user approval** — `SMAppService.register()` puts the daemon in *requires approval*; the user must enable it in **System Settings ▸ Login Items & Extensions**. No app can install a root daemon silently. (This is the whole point of SMAppService.)
- 🔒 **Publishing** the DEVID DMG is outward-facing/irreversible, and this is the project's **first root component** — do the on-device signed-install smoke first (this class of thing crash-looped before; don't skip it).

MAS ships unchanged (no daemon; the fan card is `#if DEVID_BUILD` and absent from the MAS archive).

## 0. Decisions (taken)
- **Mechanism:** `SMAppService.daemon` (modern; admin-approve once; clean unregister on delete).
- **Policy:** boost-only, off by default, behind the existing "Machine controls" toggle, DEVID only.
- **Version:** bump when you ship — feature → **v1.39.0** (all targets + Android lockstep, per `[[feedback_version_drift_gate]]`), Python helper unaffected.

## 1. Build the daemon (release)
```bash
cd MachineRootHelper
swift build -c release            # -> .build/release/machine-root-helper
```

## 2. Embed into the app bundle (DONE — `scripts/build_signed_app.sh`)
`scripts/build_signed_app.sh` now builds `MachineRootHelper` (release) and embeds
+ signs the daemon into the app, **DEVID-gated** (never in MAS):
- `Contents/MacOS/machine-root-helper`  (release binary, Hardened-Runtime signed)
- `Contents/Library/LaunchDaemons/yyh.CLI-Pulse.machine-root-helper.plist`

Verified 2026-07-07: `DEVID_BUILD_FLAG=1 CODE_SIGN_IDENTITY="Developer ID
Application: Yuhe Ye (KHMK6Q3L3K)" scripts/build_signed_app.sh Release <out>` → app
signed Dev ID (id `yyh.CLI-Pulse`), embedded daemon signed Dev ID + runtime,
`codesign --verify --deep` OK. `build_devid_dmg.sh` calls this script so the DMG
picks up the daemon automatically; MAS's `build-appstore.sh` never runs it → daemon
absent from MAS, as required.

## 3. Sign (Developer ID, hardened runtime, same team KHMK6Q3L3K)
Sign the daemon **before** the outer app is sealed:
```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: … (KHMK6Q3L3K)" \
  "…/CLI Pulse Bar.app/Contents/MacOS/machine-root-helper"
```
The daemon needs no special entitlements (root SMC write needs no entitlement; the XPC gate authenticates the *app* by Team-ID/designated-requirement — `PeerAuthenticator`). Confirm `kAllowedIdentifiers`/`kTeamID` in `main.swift` match the real signing identity before this step.

## 4. Notarize + staple (whole app), then DMG
Reuse the existing DEVID DMG + notarize flow (`[[reference_devid_installer_cert]]`, `[[feedback_keychain_notary_vanished]]` — re-import the notary profile if it vanished). `codesign --verify --deep` + `spctl -a -t exec -vv` the app, incl. the embedded daemon.

## 5. 🔒 ON-DEVICE SMOKE (owner-run, before publish — NON-NEGOTIABLE)
Install the signed/notarized app, then:
1. Launch → **Machine** tab → turn on **Machine controls** (Settings).
2. The Fan card shows **Install fan control** → click → **System Settings** opens → **enable "CLI Pulse"** under Login Items & Extensions.
3. Back in the app, the daemon comes up → the Fan card appears with live RPM + Auto/Cool/Full Blast.
4. Validate on real fans (same as the selftest, but via the installed daemon + app):
   - Cool/Full Blast → fans spin up; the "Boosting" badge shows.
   - Auto → fans return.
   - **Quit the app while boosting** → fans must return to auto within ~8s (heartbeat-lapse).
   - `sudo kill -9 <machine-root-helper pid>` while boosting → **launchd relaunches it and fans revert to auto** (the crash-recovery layer). Measure the window.
5. **Uninstall check:** delete the app → confirm no orphaned `machine-root-helper` LaunchDaemon remains (`launchctl print system/yyh.CLI-Pulse.machine-root-helper` → not found; SMAppService unregisters on delete).

If any of 4/5 misbehaves, STOP and report — do not publish.

## 6. Publish (owner call)
Only after §5 passes: bump version (§0), merge the branch, cut the DEVID DMG, update `latest.json` in `cli-pulse-helper-releases` (`[[reference_helper_releases_repo]]`), Android lockstep + version-drift gate green. MAS submission optional/unchanged (no fan feature there).

## Quick local validation (no packaging) — already done
`sudo .build/debug/machine-root-helper selftest write` drives the real FanController+RealSMC through every safety layer on hardware; `selftest read` (no root) validates the SMC read. Both green on the owner's 2-fan Mac 2026-07-07.
