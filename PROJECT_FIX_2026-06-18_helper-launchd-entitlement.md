# PROJECT FIX — companion-CLI helper hangs under launchd (app-group entitlement) — 2026-06-18

Found during the on-device .pkg install smoke for the unpaired-detection fix
([[PROJECT_FIX_2026-06-18_helper-unpaired-detection]]). Distinct from RC-1/2/3.

## Symptom
After installing the helper .pkg, the LaunchAgent daemon started (logged
"remote agent manager initialised") but then **hung in `os.open()`** and never
bound its UDS socket — so the app showed the helper as not running. The stuck
processes were **unkillable** (`STAT` showed uninterruptible sleep in the
`__open` kernel syscall) and only clear on reboot. The **same binary run
foreground bound the socket in ~1s**.

## Root cause (confirmed on-device, macOS 26)
The helper's UDS socket + auth token live in the **MAS app's app-group
container** (`~/Library/Group Containers/group.yyh.CLI-Pulse/`) — the only path
a sandboxed app and an external Developer-ID helper can both reach. On
macOS 26, a **launchd agent that touches another app's group container without
the `com.apple.security.application-groups` entitlement blocks in-kernel**
(the access neither succeeds nor returns a TCC denial — `os.open` just never
returns). The previously-shipped helper avoided this via a per-cdhash Full Disk
Access grant; a `.pkg` upgrade **replaces the binary (new cdhash) and
invalidates that grant**, so the new daemon hangs. The foreground run worked
only because it inherited the calling shell's FDA. (Matches the
`feedback_helper_entitlements_bug` pattern — the Swift Phase-4D helper hit the
same kernel block with empty entitlements.)

## Fix
Sign the helper's entry executable with the matching app-group entitlement so
the launchd agent is granted group-container access directly (no FDA needed).
- New `scripts/pkg-scripts/cli_pulse_helper.entitlements`:
  `com.apple.security.application-groups = [group.yyh.CLI-Pulse]`.
- `scripts/build_helper_pkg.sh` Step 4 now passes
  `--entitlements .../cli_pulse_helper.entitlements` to the **entry-binary**
  codesign (nested `.so`/`.dylib` signing is unchanged).

## Validation (on this Mac, real signed+notarized .pkg, under launchd)
- **Notarization Accepted** with the app-group entitlement on a Developer ID
  binary (the key risk — Apple accepts it; no provisioning profile needed for
  Developer ID app groups).
- Entitlement embedded in the packaged binary (`codesign -d --entitlements`).
- **Paired** install → launchd → socket bound ~4s, `hello` paired:True.
- **Unpaired** (the reported user scenario) → launchd → socket bound, `hello`
  paired:false, daemon idles (no crash-loop), the macOS app probed it
  (`local_rpc method=hello`). The ~27s unpaired bind latency also confirms the
  RC-3 45s post-quit grace was right-sized.
- Restored the test Mac's paired config afterward → paired:True, syncing.

## Ships in
The new helper **.pkg 1.18.1** (alongside the RC-1 fix). The macOS app 1.30.2
(RC-2/RC-3 + paired rendering) is unaffected by this — it's a signing change.

## Note for the next helper .pkg
Always sign the entry binary with the app-group entitlement (now in
`build_helper_pkg.sh`). Do NOT rely on a per-cdhash FDA grant surviving an
upgrade — it won't.
