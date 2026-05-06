# Phase 4D Xcode setup — swapping PyInstaller for the Swift helper

Phase 4 (PR #19) embedded the Python helper via PyInstaller (12 MB
binary). Phase 4D ships a native Swift port (~480 KB binary, 30x
smaller, ~13x faster cold start) using the existing LaunchAgent
architecture from PR #19. The macOS app's Sandbox / Group Container
contracts don't change; the only difference is the binary inside
`Contents/Helpers/`.

## What changed vs PR #19

The Phase 4 work in PR #19 already documents three Xcode UI
changes (Resources, Run Script, Copy Files). For Phase 4D:

| Phase 4 (PyInstaller)                                   | Phase 4D (Swift)                                          |
|---------------------------------------------------------|-----------------------------------------------------------|
| Run Script: `scripts/build_helper_binary.sh`            | Run Script: `scripts/build_helper_swift.sh`               |
| Copy: `helper/dist/cli_pulse_helper`                    | Copy: `HelperSwift/.build/release/cli_pulse_helper`       |
| Required: `pip3 install pyinstaller`                    | Required: nothing (Swift toolchain ships with Xcode)      |
| Binary size: ~12 MB                                     | Binary size: ~480 KB                                      |
| Cold start: ~400 ms (PyInstaller bootloader)            | Cold start: ~30 ms (Mach-O startup)                       |
| Notarisation: needs `cs.allow-jit` + similar entitlements| Notarisation: standard Hardened Runtime works as-is       |

`HelperAgent.plist` template + `HelperLifecycleManager.swift` from
Phase 4 stay the same — the LaunchAgent installation flow is
unchanged because the binary is still at the same
`Contents/Helpers/cli_pulse_helper` path.

## Three Xcode UI changes (the diff vs Phase 4)

### 1. Replace the Run Script Phase script

In the existing `Build Helper Binary` Run Script phase from
Phase 4, replace the script body:

```bash
"${SRCROOT}/../scripts/build_helper_binary.sh"
```

with:

```bash
"${SRCROOT}/../scripts/build_helper_swift.sh"
```

(rename the phase to `Build Helper Binary (Swift)` for clarity).

Input File Lists update:

```
$(SRCROOT)/../HelperSwift/Package.swift
```

Output Files:

```
$(SRCROOT)/../HelperSwift/.build/release/cli_pulse_helper
```

### 2. Update the Copy Files Phase source path

In the existing `Embed Helper Binary` Copy Files phase, remove
the reference to `helper/dist/cli_pulse_helper` and add a
reference to:

```
HelperSwift/.build/release/cli_pulse_helper
```

Destination unchanged: **Wrapper** + custom subpath
`Contents/Helpers`. Keep "Code Sign On Copy" ticked (same Team ID
as the app — required for `SMAppService.agent` to accept the
embedded plist).

### 3. (No change) `HelperAgent.plist` resource

The Resources entry from Phase 4 stays as-is.

## Verification (same as Phase 4 plus a binary-shape check)

```
$ xcodebuild -scheme "CLI Pulse Bar" -configuration Debug build
$ APP=/path/to/build/products/Debug/CLI\ Pulse\ Bar.app

$ ls -la "$APP/Contents/Helpers/cli_pulse_helper"
-rwxr-xr-x  1 ...  staff  481536  ...  cli_pulse_helper

$ file "$APP/Contents/Helpers/cli_pulse_helper"
... Mach-O 64-bit executable arm64

$ codesign -dv "$APP/Contents/Helpers/cli_pulse_helper" 2>&1 | head
... Authority=Developer ID Application: ...
```

After launching the .app once, the LaunchAgent should auto-install
exactly like Phase 4:

```
$ ls ~/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist
$ ls ~/Library/Group\ Containers/group.yyh.CLI-Pulse/clipulse-helper.sock
$ tail ~/Library/Logs/CLI\ Pulse/helper.err.log
... cli_pulse_helper (Swift): listening on /Users/.../clipulse-helper.sock
```

## Rolling back to PyInstaller

If a notarisation issue surfaces post-Phase 4D and you need to
ship Phase 4 (PyInstaller) instead:

1. Revert the Run Script body to `build_helper_binary.sh`.
2. Revert the Copy Files source to `helper/dist/cli_pulse_helper`.
3. Re-run `pip3 install pyinstaller`.

Both binaries respect the SAME `Contents/Helpers/cli_pulse_helper`
naming + the SAME LaunchAgent plist, so the macOS app side doesn't
need to change at all between the two backends.

## Cloud sync (heartbeat / sync subcommands) deferral

Phase 4D iter 1-6 covers the **local UDS surface only** — every
method the macOS app's `LocalSessionControlClient` calls (hello,
ping, get_local_control_status, set_local_control_enabled,
start_session, list_sessions, stop_session, send_input,
subscribe_events, hook_create_approval, hook_wait_decision,
get_pending_approvals, approve_action, install_claude_hook).

The cloud-side subcommands (`pair`, `heartbeat`, `sync`,
`run-demo`, `inspect`, `remote-approval-hook`,
`remote-approvals`) still live in the Python helper at
`helper/cli_pulse_helper.py`. Two ways to ship v1.13:

  - **Recommended for v1.13**: ship Swift helper as the
    LaunchAgent (handles UDS — the user-facing Sessions feature),
    AND keep the Python helper as an optional sidecar the user
    runs from Terminal for cloud sync. v1.14 finishes the port.
  - **Aggressive**: revert this iteration and ship the
    PyInstaller-frozen Python helper from PR #19 for v1.13.
    Wait until the Swift port covers cloud sync (Phase 4D iter
    7-10 — 1-2 weeks of additional work) before ship.

The PR will recommend the first option in its description so
v1.13 ships on time + benefits from the lighter Swift binary +
cleaner native macOS integration.
