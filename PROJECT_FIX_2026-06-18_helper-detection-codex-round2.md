# PROJECT FIX — helper detection, Codex-review round 2 (2026-06-18)

Acts on the owner's Codex app review of the helper-detection fixes (#187/#188).
Codex **validated** both shipped fixes (fileExists no-hard-fail + bookmark
activation) and its P1 "NSHomeDirectory fallback" was already fixed in #188.
This lands Codex's remaining concrete findings. Self-review + Gemini 3.1 Pro
review (one HIGH from Gemini fixed before merge).

## Shipped
- **P1 #3 — live-socket unlink race (sharpest "running but not detected" match).**
  `LocalSessionServer.start()` unconditionally `removeItem`'d any existing socket
  — during an update/restart overlap it could delete a LIVE instance's socket,
  leaving it running with no path → app "not detected". Now: connect-probe via
  `isSocketAlive(atPath:)`; if alive → `throw ServerError.alreadyRunning` (before
  the listen fd is created, so no leak); else unlink stale. After bind, record
  `boundSocketInode`; `stop()` only unlinks if the path still resolves to that
  inode (don't delete a newer instance's socket). Daemon `main` catches
  `.alreadyRunning` → `exit(0)` (defer to the live instance, no throttle-loop).
  New tests: 2nd start refused + 1st's socket survives & still answers; stale dead
  socket cleaned + bound.
- **P1 #1 — run-user guard.** Helper daemon logs `uid/home/socketContainer` at
  startup and, if `getuid()==0`, prints a fatal message + `exit(78)` (a root-run
  helper binds `/var/root/...`, unreachable by the user's sandboxed app, and
  would leave root-owned files in the group container).
- **P2 #5 — connect leak.** `LocalSessionControlClient.connect()` timeout now
  calls `connection.cancel()` before resuming with `.timeout` (the resumeOnce
  guard makes the resulting `.cancelled` a no-op), so a never-ready NWConnection
  isn't left pending.

## Gemini 3.1 Pro review outcome
- **HIGH (fixed):** `boundSocketInode` was touched from `start()` (boot thread) and
  `stop()` (SIGTERM `DispatchSource` global queue) — now guarded by the existing
  `connsLock` (read-under-lock, I/O outside). (In practice start() completes
  before signals are armed, but the guard removes the theoretical race and matches
  no worse than the pre-existing `listenFD`.)
- **TOCTOU (acknowledged, not changed):** connect-probe→unlink and stat→removeItem
  have a tiny window; a lost race yields `EADDRINUSE` → `ServerError.bind`
  (handled). `flock` serialization would be over-engineering for a transient
  overlap; matches the Python helper's behavior.
- Q's on exit(0)/exit(78)/double-resume: all confirmed correct.

## Still-deferred backlog (recommend next)
- **P2 #4 / state machine:** `HelperInstaller.refresh()` still collapses every
  `hello()` error to `.notInstalled` (vs `.unreachable` + retry); needs a new
  state + UI + reconcile with the live `localHelperReachable` signal + a Re-check
  button + auth-token diagnostic surfacing (Codex P3 #6).
- **P1 #1 (b) — postinstall:** derive the console user explicitly and bootstrap
  `gui/<console-uid>` (vs trusting `$HOME`/`id -u`) for `sudo`/MDM installs. Ships
  via the helper `.pkg` (`scripts/pkg-scripts/postinstall`).

## Verification
- CLIPulseCore full suite 1668 (0 failures); HelperSwift full suite 421 (0 failures, +2).
- Self-review + Gemini 3.1 Pro: LGTM after the connsLock fix. Helper changes ship via a new `.pkg`.
