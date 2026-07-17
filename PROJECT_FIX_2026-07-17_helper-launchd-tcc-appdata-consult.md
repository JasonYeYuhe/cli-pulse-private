# PROJECT_FIX 2026-07-17 — helper launchd respawn loop → the real cause is a TCC consult, not containermanagerd

**Supersedes `PROJECT_FIX_2026-07-11_helper-launchd-container-watchdog.md`, whose
diagnosis was wrong and whose fix made the failure worse.**

## Symptom
Shipped helper (`.pkg`, frozen Python, v1.29.0) cannot recover from a
mid-session restart on macOS 26.5 (Darwin 25.5.0):

```
launchctl bootout   gui/$UID/yyh.cli-pulse.helper
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/yyh.cli-pulse.helper.plist
```

→ respawn loop, `helper.err.log` filling with `app-group container access
exceeded 12s at startup …`, UDS socket never bound, app reports the helper as
not running. `kickstart -k` doesn't help; waiting 30s between bootout and
bootstrap doesn't help. A fresh `.pkg` install hits the same thing —
`postinstall.log` (Jul 11 11:35) already recorded `WARNING: Helper did not bind
UDS … within 10s`, and the helper only came up at the *next login*.

## Root cause — TCC `kTCCServiceSystemPolicyAppData`, not containermanagerd

`~/Library/Group Containers/group.yyh.CLI-Pulse/` is protected by TCC's
"access data from other apps" policy. **The first `open(2)` for write in that
directory blocks on a tccd consult that must attribute and code-sign-validate
the calling process.** Measured on this Mac:

| context | first container `open()` |
|---|---|
| from a shell | **~0.03s** — responsible process (Terminal/iTerm) already holds the grant, attribution short-circuits |
| under launchd | **1–10s, wildly variable; a >20s tail observed** — no responsible app to inherit from, so tccd does the full evaluation |
| client with no TCC grant row | **instant `EPERM`** — a fast deny, not a hang |

Three experiments pin it (probes under a throwaway LaunchAgent, `ppid=1`):

1. **It is not the app-group entitlement, and not our binary at all.**
   `/opt/homebrew/anaconda3/bin/python3.12` — unrelated, unentitled, nothing to
   do with CLI Pulse — reproduces the identical stall on the same path under
   launchd: **7.8s / 9.9s / 1.3s** across three runs.
2. **It is TCC.** `/usr/bin/python3` (no `kTCCServiceSystemPolicyAppData` row in
   `TCC.db`) gets `PermissionError: Operation not permitted` in 0.05s on the same
   path. Grant row present → slow allow. Grant row absent → instant deny.
   `~/Library/Group Containers/` itself (the *parent*) is not gated: 0.016s. Only
   the per-container subdirectory is.
3. **The cost is per-process and is never shared.** `os.stat()` is free (TCC
   doesn't gate it, so it can't be used to pre-warm); the first `open()` pays in
   full; every subsequent `open()` in that process is ~0.02s. Nothing about the
   *machine* gets warmer.

`containermanagerd` was never involved: it was running with zero error/deny/
timeout lines, and the container's metadata plist has existed since Apr 2. The
entitlement is correct and irrelevant to this failure.

## Why the 2026-07-11 watchdog made it worse

The old fix wrapped `rotate_token()` in a 12s `threading.Timer` and, on
overrun, `os._exit(75)` so `KeepAlive` would "respawn the helper against a warm
container". Given (3), **there is no warm container to respawn against** — each
respawn is a brand-new process paying a brand-new full-price consult, killed at
the same ceiling. The watchdog converted a slow-but-completing operation into an
infinite loop. Whether a given machine escapes is pure luck against a 1–10s
variable cost versus a 12s ceiling; the owner's Mac lost ~6 times consecutively.

The 07-11 doc's own evidence contradicted its conclusion and was dismissed: it
recorded that a *warm-system* bootstrap did **not** hang and that a stuck sample
"only ever showed a transient TLS handshake, never `os_open`" — i.e. it never
actually caught the hang it theorised about. Its "clears within a few seconds of
login" premise is false for the mid-session case, which never clears.

## Fix

`helper/cli_pulse_helper.py`: `_rotate_token_or_respawn` → **`_rotate_token_best_effort`**.

- Rotate on a background thread; the caller waits a bounded, generous slice
  (`_CONTAINER_ACCESS_WAIT_S = 25.0`, vs. an observed 1–10s).
- **Never `os._exit`. Never respawn.** Respawning cannot speed up a TCC consult.
- On overrun: return `None` and keep the rotation running. The call site already
  treats a token-less start as supported ("token rotation is best-effort … `hello`
  is unauthenticated … authenticated methods fail closed downstream"), so the
  socket still binds. Because `_get_token()` re-reads the token from disk on every
  request, **authentication starts working the moment the write lands — no restart,
  no respawn.**
- Log the elapsed consult past `_CONTAINER_ACCESS_SLOW_S = 3.0`, and on overrun log
  an accurate diagnostic naming tccd, so a pathological machine is visible in the
  log without a repro.
- `token_path_for_log()` resolves the path for that diagnostic and can never raise.

Note the socket `bind()` is the same process's second gated touch, so it waits on
the same in-flight consult — the daemon still takes ~1–10s to bind on a cold
process. That is unavoidable and correct. The point of the fix is that it now
always *converges* instead of looping.

## Verification

- `helper/test_container_access_wait.py` (renamed from `test_container_watchdog.py`,
  5 cases, green): fast path returns the token and never exits; **an overrunning
  consult returns `None`, does not exit, and returns at the ceiling rather than
  blocking for the whole call**; the abandoned rotation still lands on disk; a
  rotation exception propagates; the diagnostic never raises.
- Full helper suite: **947 passed, 1 skipped**. `ruff check`: clean.
- **E2E under real launchd against the real container** (`ppid=1`):
  - Real ceiling → token returned in 2.30s, no exit.
  - Cold process, ceiling forced to overrun → returned `None` at 0.57s, **process
    survived** (old code would have `os._exit(75)` into the loop here), background
    rotation landed at **8.67s**, token on disk → `_get_token()` self-heals.

## Owner state — machine restored, no action needed

The Mac was left with two helpers (a detached shell-spawn stopgap from the prior
session plus a socket-shadowed launchd helper, both syncing to Supabase and
duplicating heartbeats). Now: **one helper, pid owned by launchd, socket bound,
`paired=True`, syncing every 2 min.** The stopgap was SIGTERM'd; the LaunchAgent
plist was never modified. The shipped 1.29.0 binary still carries the old
watchdog — this fix ships with the next helper release.

## Follow-ups (not done here)

- The `.pkg` postinstall's 10s UDS-bind wait is below the observed consult cost —
  it will keep emitting its false-alarm WARNING on fresh installs. Raise it or drop
  the warning.
- Consider whether the app should surface "macOS is still authorising the helper"
  rather than "not installed" during the first-bind window.
- The Swift helper (`HelperSwift`) pays the same TCC toll on the same path; worth
  measuring whether its smaller signature evaluates faster.

Supersedes memory `feedback_helper_pkg_launchd_entitlement` (the watchdog half).
