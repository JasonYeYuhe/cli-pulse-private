# Phase 4D Xcode setup — swapping PyInstaller for the Swift helper

Phase 4 (PR #19) embedded the Python helper via PyInstaller (12 MB
binary). Phase 4D ships a native Swift port (~552 KB binary, 22x
smaller, ~13x faster cold start) using the existing LaunchAgent
architecture from PR #19. The macOS app's Sandbox / Group Container
contracts don't change; the only difference is the binary inside
`Contents/Helpers/`.

**P1.5 update (Codex review iter8)**: instead of editing Xcode
build phases by hand, the canonical build path is now
`scripts/build_signed_app.sh`. A clean checkout + that script
produces a fully-signed .app with the helper at
`Contents/Helpers/cli_pulse_helper` and the LaunchAgent plist at
`Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist`. CI
runs the same script — green CI proves the embedded helper is
present + signed.

```
$ ./scripts/build_signed_app.sh Debug
==> [1/7] Building Swift helper (release) ...
==> [2/7] Building CLI Pulse Bar.app (Debug) ...
==> [3/7] Embedding helper at Contents/Helpers/ ...
==> [4/7] Embedding LaunchAgent plist ...
==> [5/7] Resolving signing identity ...
==> [6/7] Codesigning helper + re-signing .app ...
==> [7/7] Verifying bundle ...
    OK: ...CLI Pulse Bar.app is signed + has helper + has plist
```

For `Release` / notarisation, set `CODE_SIGN_IDENTITY` env to
your Developer ID Application identity before invoking the
script. The script handles `--deep --options runtime` so the
helper inherits Hardened Runtime.

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

Phase 4D iter 1-8 covers the **local UDS surface only** + the
Claude hook CLI adapter — every method the macOS app's
`LocalSessionControlClient` calls AND the
`remote-approval-hook --provider claude` subcommand Claude itself
spawns:

  hello, ping, get_local_control_status, set_local_control_enabled,
  start_session, list_sessions, stop_session, send_input,
  subscribe_events, hook_create_approval, hook_wait_decision,
  get_pending_approvals, approve_action, install_claude_hook,
  remote-approval-hook --provider claude (CLI subcommand)

The cloud-side subcommands (`pair`, `heartbeat`, `sync`,
`run-demo`, `inspect`) still live in the Python helper at
`helper/cli_pulse_helper.py`.

### v1.13 release modes (mutually exclusive)

**Pick exactly one.** The two helpers MUST NOT coexist — both
contend for the same `~/Library/Group Containers/group.yyh.CLI-Pulse/`
auth token + `clipulse-helper.sock`, and a `set_local_control_enabled`
flip would land on whichever helper happened to win the race. P1.3
in PR #20's Codex review pinned this as a release blocker.

**Option A — Swift-only v1.13 (this PR, recommended)**:
   * Ship the Swift LaunchAgent.
   * Drop cloud-side device tracking (`heartbeat`, `sync`,
     `system_collector`) for ONE release. The macOS app reads
     heartbeat data via direct Supabase queries
     (`HelperAPIClient`) so the Overview tab keeps working.
   * v1.14 finishes the Swift port (cloud sync + system
     collector); the Python helper retires after that.

**Option B — Python-only v1.13 (PR #19's PyInstaller path)**:
   * Ship the Python LaunchAgent embedded via PyInstaller (12 MB).
   * The Swift port (this PR) continues as a non-blocking spike
     for v1.14.
   * Notarisation needs `cs.allow-jit` etc. (PyInstaller
     bootloader); Option A doesn't.

### What about a sidecar?

The "Swift LaunchAgent + Python sidecar for cloud sync" model the
earlier PR description proposed has been **retracted**. Both
helpers would race the auth token + UDS socket, leaving the
Sessions toggle ambiguous and the structured-approval flow
nondeterministic. There is no valid coexistence story; pick one.
