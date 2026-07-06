# MachineRootHelper — M2 root privileged-helper (SKELETON / DRAFT)

**Status:** draft on branch `m2-root-helper-skeleton`. **NOT shipped. NOT merged. NOT wired into any app build.** Runs only if the owner explicitly installs it. Gated until the M0 go/no-go and M3.

This is milestone **M2** from `DEV_PLAN_2026-07-06_machine_controls.md`: the reviewed *root IPC foundation* on top of which fan control (M3) and root/other-user process-kill (M4) will eventually be built. It is deliberately a **separate SwiftPM package** the Xcode project does not reference, so it cannot end up in a shipped MAS or DEVID build by accident.

## What M2 does — and deliberately does NOT do

- ✅ A root daemon (`machine-root-helper`) that binds a Mach service and exposes an XPC interface.
- ✅ The **security gate**: authenticate every incoming connection by its per-message **`audit_token` → `SecCode` → designated requirement** (Apple-anchored + Team-ID `KHMK6Q3L3K` + one of our bundle identifiers). Reject everything else. Fail closed on every error path.
- ✅ A **dead-man's-switch** scaffold and **command guards** (fan clamp, kill deny-list) — pure, unit-tested — ready for M3/M4 to wire, so the dangerous milestones don't invent safety logic under pressure.
- ❌ **No fan write.** The protocol has only `ping` / `capabilities` (both privileged capabilities report `false`). There is no `setFan`, no `killPid`. Nothing privileged is reachable.

## Why these design choices (the security-review-critical bits)

- **`audit_token`, not PID.** A socket/`processIdentifier` peer check is TOCTOU-vulnerable to PID reuse. The per-connection audit token pins the exact sender; building the `SecCode` from it (`SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit:)`) is the only race-free authentication. See `PeerAuthenticator` + the `NSXPCConnection.auditTokenData` extension.
- **Compiled Swift, never Python.** A root Python daemon is a critical risk (`PYTHONPATH`/dylib injection). The user-tier helper stays Python; this root tier is a minimal compiled binary with a tiny typed surface.
- **Strictly-typed, whitelisted commands.** The daemon never accepts an arbitrary SMC key/value or an arbitrary `(pid, signal)`. Each future command is one narrowly-typed method with server-side validation (`CommandGuard`).
- **Layered dead-man's-switch (for M3).** `SIGKILL`/panic can't run cleanup, so a forced-manual fan must not stay stuck: heartbeat-or-revert in the daemon + short manual re-assert window + a user-helper watchdog + hardware TjMax as the ultimate backstop. `DeadMansSwitch` models the heartbeat/revert state machine now (revert is a no-op in M2).

## Deferred decisions (owner)

- **Install/launch mechanism** — pending M0: `SMAppService.daemon` (recommended: admin-auth-once, clean unregister on app delete) **vs** a system-domain root `.pkg` LaunchDaemon. Nothing here hard-codes it; both register the Mach service name in `RootHelperInterface.machServiceName`.
- **Final bundle identifiers** — `kAllowedIdentifiers` in `main.swift` is a `TODO(owner)` placeholder; confirm the real app + user-helper identifiers before this ever installs.

## Before M3 (fan write) can ship — non-negotiable gates

1. **M0 go/no-go**, incl. the `SIGKILL` self-revert observation (does the firmware revert to auto, how fast). Run the `spike/m0_fan_feasibility.swift` write + revert-test as root on real hardware.
2. A **hard security review** of the auth path (audit_token retrieval on the target OS, requirement string, uninstall leaves no orphan root daemon).
3. A **real-hardware fan test** (set 40 % / 100 % / auto; confirm the SMC target takes, temps respond, and force-quitting the helper reverts to auto).

## Layout

```
Sources/RootHelperCore/       reviewed, testable core (no privileged effects)
  RootHelperProtocol.swift    the tiny @objc XPC command surface + interface constants
  PeerAuthenticator.swift     audit_token→SecCode→requirement decision (the gate)
  DeadMansSwitch.swift        heartbeat/revert state machine (M3 wires the revert)
  CommandGuard.swift          fan clamp + kill deny-list (M3/M4 wire these)
Sources/machine-root-helper/  the root daemon entry (only file touching XPC/tokens)
  main.swift
Tests/RootHelperCoreTests/    20 tests over the gate, dead-man's-switch, guards
```

Build/test: `cd MachineRootHelper && swift build && swift test` (does not install or run anything privileged).
