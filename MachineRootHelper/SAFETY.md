# Fan control — safety model (READ BEFORE TOUCHING THIS)

Fan control writes SMC keys as **root** on users' Macs. On this hardware the
**firmware does NOT self-revert** a manual fan setting when the controlling
process dies — the M0 spike (2026-07-07) confirmed a `kill -9` left the fan stuck
at the manual target until it was reset by hand. That single fact drives the
entire design. Get this wrong and a stuck fan can overheat (or, harmlessly but
annoyingly, run full-blast) until reboot.

## The one invariant

> A fan that ends up **stuck in manual** (because every software layer failed at
> once) must be stuck at a speed that is **at least as cool as Apple auto**.

Everything below serves that invariant.

## Boost-only (the primary safety rule)

The daemon only ever sets a manual target **≥ the fan's current auto RPM**
(`CommandGuard.clampBoostTarget`, captured once per boost session from the auto
reading — never re-derived from a fan already in manual, which would ratchet).
Consequence: a stuck fan is **stuck-HIGH** (loud, extra cooling) — never
stuck-LOW (under-cooled). "Quiet mode" (below auto) is **out of scope** precisely
because a stuck quiet fan is the dangerous case.

A **full-blast** boost (target == max) has **zero** residual risk — it can't be
below any future auto demand — and is the unconditionally-safe default the UI
should lead with.

## Layered dead-man's-switch (defense in depth)

Because the firmware won't help, revert-to-auto is guaranteed by four independent
layers, in order of how fast they act:

1. **Revert-on-startup** — `FanController.init` reverts every fan to auto the
   instant the daemon launches. Combined with **launchd `KeepAlive`**, a `kill -9`
   of the daemon → launchd relaunches it (~1 s) → it reverts. This is the ONLY
   thing that saves a SIGKILL (which runs no cleanup). **`KeepAlive` is mandatory**
   in the LaunchDaemon plist — see `install/`.
2. **Heartbeat-gated hold** — a boost is held only while the app keeps calling
   `fanHeartbeat` (interval must be well under the daemon's
   `kHeartbeatTimeoutSeconds`, default 8 s). App crash / disconnect / sleep →
   heartbeat lapses → `tick()` reverts to auto.
3. **Graceful-signal revert** — `SIGTERM`/`SIGINT` (launchd stop, logout) revert
   before exit, via a `DispatchSource` handler (safe SMC writes, unlike a raw
   signal handler).
4. **Hardware TjMax throttling** — the CPU/GPU throttle themselves before thermal
   damage regardless of fan state. The design must never try to defeat this.

(A future **user-helper watchdog** — the always-running Python LaunchAgent noticing
the root daemon is gone and forcing auto — is a worthwhile 5th layer; not yet built.)

## Residual risk (honest)

The boost-only floor is captured at set time. If **load rises after** a boost AND
the daemon has died AND launchd hasn't relaunched it yet, the stuck target can be
below the *new* auto demand for the relaunch window (~1 s) — bounded by layer 1's
speed and covered by TjMax (layer 4). A **full-blast** boost removes even this.

## What the real-hardware test MUST confirm (OWNER-RUN — cannot be unit-tested)

Before ANY of this ships:

1. `setFanBoost` actually moves the fans and holds (already partly seen in the M0
   spike: `F0Md=1 + F0Tg` takes, no `Ftst` needed).
2. Kill the **daemon** with `kill -9`; confirm **launchd relaunches it and it
   reverts to auto**, and measure the stuck window.
3. Stop heart-beating (quit the app); confirm the daemon reverts within
   `kHeartbeatTimeoutSeconds`.
4. `SIGTERM` the daemon; confirm it reverts before exit.
5. On app **uninstall**, confirm no orphaned root daemon remains (SMAppService
   unregister / launchd unload).

## Unit-test coverage (offline, `swift test`)

`FanControllerTests` proves: revert-on-init reverts all fans; boost-only clamp
(below-auto raised to floor, above-max capped, floor non-ratcheting); no
half-applied boost on an unreadable fan; heartbeat lapse reverts once; heartbeat
re-arms; explicit revert. `CommandGuardTests` proves the clamp math incl. the
bogus-high-auto and unknown-range refusals.
