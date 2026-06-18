# PROJECT FIX — companion CLI "未安装 after install" (unpaired helper) — 2026-06-18

User report (macOS 1.30.1, Developer ID build): installed the companion CLI;
it still showed "Not installed". Sharp observation: the menu-bar UI is a
`MenuBarExtra(.window)` popover that closes when they click over to
Installer.app, and after the install finishes, reopening still shows
"Not installed".

Root-caused via an adversarially-verified 7-agent workflow. **3 real causes**
(RC-4/RC-5 — token race, App Nap, socket-unlink — were investigated and
confirmed NON-causes).

## RC-1 (helper + new .pkg) — the structural cause for a FRESH install
The Python helper bound its local UDS socket **only when paired**: the
`LocalSessionServer.start()` call lived inside `if remote_agent_manager is not
None:`, and the manager is built from `load_config()`, which raises
`ConfigError` when `~/.cli-pulse-helper.json` is absent (unpaired). Worse, the
daemon's main loop treated a heartbeat `ConfigError` as **fatal**
(`except ConfigError: raise`); with the installed LaunchAgent's
`KeepAlive=true`, an unpaired helper **crash-looped** and never kept the socket
bound. The app probes that socket via `hello` to decide installed/running, so
an installed-but-unpaired helper looked "not installed" forever. (App pairing
writes app-group/Keychain while the helper reads the JSON file — a known drift,
so "installed but no helper config" is a real state, not a corner case.)

Fix (`helper/cli_pulse_helper.py`, `helper/local_session_server.py`,
`helper/system_collector.py` → HELPER_VERSION 1.18.0 → **1.18.1**):
- Stand up the local UDS surface **unconditionally** (moved out of the
  `if manager is not None` guard). Manager-dependent methods (start/stop/
  send_input) return a clear "not paired" error; `hello`, `ping`,
  detected-session listing, and the control-enabled getter all work without a
  manager. `rotate_token()` is now best-effort (a token failure must not stop
  the bind — `hello` is unauthenticated).
- Heartbeat `ConfigError` is **no longer fatal**: the daemon idles and retries
  each cycle (no exit ⇒ no launchd restart ⇒ no crash-loop), keeping the socket
  bound. `config` is initialised to `None` before the loop and the swarm
  heartbeat is guarded.
- `hello` reply now carries a **`paired`** flag (default True for older callers)
  so the app can show "installed — pair to activate" instead of "not installed".

## RC-2 (app, 1.30.2) — no re-detection when the popover reopens
`MenuBarExtra(.window)` reuses the popover content view across open/close, so
`CompanionCLISection`'s one-shot `.task { refresh() }` never re-fires, and the
only continuous self-heal (SessionsTab poll) requires `hello()` to already
succeed and only runs on the Sessions tab. So even after the helper came up,
the Settings-tab UI stayed stale until a manual "Re-check".

Fix: `MenuBarView` observes `@Environment(\.controlActiveState)` and calls
`helperInstaller.refreshIfStale()` whenever the popover (re)gains focus.
`refreshIfStale` delegates to a pure, unit-tested `HelperInstaller.shouldReprobe`
gate (re-probe any settled state older than `maxAge`=8s; never mid-flight).

## RC-3 (app, 1.30.2) — premature `.notInstalled` during the install flow
`waitForInstallerToTerminate` returned `true` immediately if Installer.app
wasn't yet in the running-apps list — but `NSWorkspace.open` returns ~50–200ms
*before* Installer.app registers, so it entered the post-quit branch
prematurely. And the post-quit grace was only 10×1s, far shorter than a human
clicking through Installer + admin auth + the daemon's first launch → premature
`refresh()` → `.notInstalled`.

Fix (`HelperInstaller.swift`): wait up to 5s for Installer.app to **appear**
before treating "empty" as terminated; extend the post-quit grace from 10s to
**45s** (the parallel 120s pollTask still covers a genuinely slow case).

## Verification
- `helper` pytest: **568 passed** (2 new: `hello` reports `paired:false` for an
  unpaired helper + still answers, default `paired:true`).
- CLIPulseCore `swift test`: **1673 passed / 0 failures** (new: 4
  `shouldReprobe` + 2 `paired` plumbing tests).
- **On-device Python smoke**: ran the daemon unpaired with an isolated `HOME` →
  socket bound in ~1s, `hello` returned `ok:true paired:false`, daemon stayed
  alive (no crash-loop), log: "local UDS server started (paired=False)" +
  "helper has no usable config yet … idling".
- **PyInstaller-frozen smoke** + signed/notarized .pkg ship: see ship notes.

## Shipping split
- App **1.30.2** (App Store + DEVID + public): RC-2 + RC-3 + `paired` rendering.
- New signed/notarized **helper .pkg 1.18.1** → `cli-pulse-helper-releases`
  (RC-1). Promoted only after on-device install smoke (per the v0.8.0 rule).
