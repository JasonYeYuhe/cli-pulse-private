# PROJECT_FIX 2026-07-17 — helper watchdog respawned 2,816× over 10h → wait out the TCC consult, never respawn

## Symptom (P0, silent)
The `.pkg` helper (1.29.0) was **down for 10 hours 7 minutes** on the owner's Mac
and nothing surfaced it. `helper.err.log`:

```
$ grep -c "exceeded 12s" helper.err.log
2816
first: 2026-07-17T00:44:46     last: 2026-07-17T10:52:24     median gap: 13s
```

The UDS socket never bound, so the app reports the helper "not running" — the same
end-user symptom the 1.29.0 watchdog was written to fix, reached by a different road.

## How it got there
`_rotate_token_or_respawn` (shipped 1.29.0, see
`PROJECT_FIX_2026-07-11_helper-launchd-container-watchdog.md`) guards the first
app-group-container access with a 12s watchdog and, on trip, `os._exit(75)` so
launchd's `KeepAlive` respawns the helper "against a now-warmer containermanagerd".

That rests on a premise stated in the fix doc: the stall is a **cold-login race**
that *"self-clears within seconds of login"*. **The premise is false.** The machine
was warm (up 4 days), awake (trips evenly spaced 13s apart for the full 10h — no
sleep gaps), and lightly loaded for most of the window. It never cleared. An
unbounded respawn isn't self-healing; it's an invisible outage plus a battery
drain — each cycle re-execs a PyInstaller binary that re-parses the entire OpenSSL
CA bundle at startup (visible in a `/usr/bin/sample`: 397/3244 samples in
`_ssl__SSLContext_set_default_verify_paths_impl` → `X509_load_cert_crl_file_ex`).

Triggered by stopping the LaunchAgent mid-session while verifying #364. Not exotic:
any helper crash, `.pkg` upgrade, or `launchctl` cycle reaches the same state. Note
`postinstall.log` (Jul 11 11:35) already recorded `WARNING: Helper did not bind UDS
... within 10s` — a **fresh install** hits this and only recovers at the next login.

## Root cause: a TCC consult, not containermanagerd

Established by a **concurrent effort** (PR #366, since reverted — see below), whose
diagnosis this fix is built on. On macOS 26.5 the first container `open(2)` from a
launchd-spawned process is a **TCC `kTCCServiceSystemPolicyAppData` consult**:

| Context | First container open(2) |
|---|---|
| shell | **~0.03s** — the responsible process (Terminal/iTerm) holds the grant, so attribution short-circuits |
| **launchd** | **1–10s, wildly variable, >20s tail** — no responsible app, so tccd does full attribution + code-sign validation every time |
| no grant row at all | **instant EPERM** — a fast deny, not a hang. This is the tell that pins it to TCC |

Reproduced with an unrelated, **unentitled** anaconda python under launchd
(7.8s / 9.9s / 1.3s) → it is neither our binary nor the app-group entitlement.
Only the per-container subdir is gated; `Group Containers/` itself is not.

**The decisive property: the cost is per-PROCESS and is never shared.** The first
`open(2)` pays in full; later opens in that process are ~0.02s; `os.stat()` is free
and cannot pre-warm it. **Nothing about the machine ever gets "warmer."**

That is exactly why 1.29.0 could not work, and why my own first draft of this fix
(bound the respawns to 3, then degrade) was still solving the wrong problem: a
respawn starts a FRESH full-price consult and meets the same ceiling. It was a coin
flip against a 1–10s variable cost, re-flipped forever. 2,816 losses in a row.

(My own probe measured a launchd-spawned **bash** touching the container in 41ms,
which looked like it exonerated launchd. It doesn't — bash has its own TCC grant
row, so its attribution short-circuits like a shell's. The differential only shows
up with an interpreter whose grant forces the full consult.)

## Fix — wait it out, never exit, and don't touch the container again if it stalls

1. `rotate_token` runs on a **daemon thread** with a bounded wait
   (`_CONTAINER_ACCESS_WAIT_S = 25s`, sized to the measured 1–10s + >20s-tail
   distribution rather than 1.29.0's imagined ~2s "warm" cost). Most starts that
   the 12s ceiling was killing now simply succeed. 1.29.0 ran it on the MAIN
   thread, where the only escape was `os._exit` from a Timer — which is precisely
   why it had no option but to die. A daemon thread can just be abandoned.
2. **Never `os._exit`. Never respawn.** The consult is per-process; retrying cannot
   help, and retrying forever is what produced the outage. This also deleted the
   respawn counter and every hazard attached to it (unpersistable counter, corrupt
   negative values, reset-on-exception) that review had found in the earlier draft.
3. If the wait expires → **skip the local UDS surface** and keep the cloud loop.

**Skipping the socket is load-bearing, not tidiness** (review: agy, and
independently the reason #366 was reverted). `default_socket_path()` is
`container_dir() / SOCK_FILENAME` — the socket lives INSIDE the stalled container.
`LocalSessionServer.start()` does mkdir/exists/unlink/bind/chmod on that path, on
the main thread, unguarded. Binding right after the wait expired would hang the
daemon forever: the pre-1.29 permanent silent hang, which is *worse* than the loop
(launchd cannot restart a hung process). 1.29.0's "once the canary succeeds the
container is warm, so bind is safe" holds wherever the canary SUCCEEDS; it doesn't
extend to the path where it failed. Both #366 and my first draft got this wrong.

Cloud sync — heartbeat, sync, remote sessions — keeps running throughout, exactly
as that block's own preamble prescribes: *"the daemon still services
Supabase-routed sessions even if the local socket can't bind"*. Only the
same-machine fast path is out, and it returns on the next helper start.

**A token-less start is safe**: with no socket there is no local auth surface at
all; and `compare()` is `if not expected or not supplied: return False`, so an
empty token could never authenticate even if one were bound.

**It does not self-heal in place.** An earlier draft of this doc (and #366) claimed
it did, via `_get_token()`'s per-request re-read. That is true only of a design
that binds the socket — which is the design that hangs. With no server, nothing
re-reads the token; the local path returns on the next start.

## Tests
`helper/test_container_watchdog.py`, 6 cases, all green. The one that matters —
`test_stall_returns_none_and_never_exits` — was verified to FAIL against 1.29.0's
semantics (put the `os._exit(75)` back on the stall path and it goes red).

Also pinned: a slow-but-COMPLETING consult still returns its token (the case the
12s ceiling kept killing); an abandoned worker still lands its token for the next
start; a raise propagates (a raise is not a stall — the container answered); and
an empty token never authenticates.

The earlier draft's counter tests are gone with the counter. Worth recording why
they existed: both reviewers independently found that an unpersistable counter
recreated the unbounded loop, and codex found that `int()` parses `-1000000` and
keeps the budget open for a million restarts. One of my own tests
(`test_unreadable_counter_still_bounds_the_loop`) was **fiction** — a single boot
asserting `codes == [75] or token is None`, a condition the bug itself satisfies.
Deleting the respawn deleted that whole class of hazard, which is the strongest
argument that the simpler design is the right one.

## Not done here
- **Root cause of the stall itself.** Still open. Next probe: a `spindump` of the
  stalled process (plain `sample` misses it — the watchdog `os._exit`s every 12s;
  raise `_CONTAINER_ACCESS_WATCHDOG_S` temporarily to catch it), and check whether
  the stall is in the entitlement-mediated container vend rather than plain file IO.
- **The Swift helper has no equivalent guard**, and its entitlements are empty — it
  works today only because it's launched with inherited FDA. Worth auditing.

## Not done here
- **The `_get_token()` read is still unguarded.** It does an unbounded
  `read_text()` from the container on every authenticated request (codex). Today
  that's fine — the token is only re-read on a start whose canary SUCCEEDED, so
  the consult is already paid for that process. Worth a look if the stall is ever
  observed mid-life rather than at startup.
- **The Swift helper has no equivalent guard** and ships empty entitlements; it
  works today only via inherited FDA, so a launchd-spawned Swift helper would hit
  the same consult. Worth auditing.
- **The 25s ceiling is a measurement, not a law.** It covers the observed >20s
  tail with margin; if a longer tail turns up, prefer raising it over reviving any
  form of retry.

## Provenance
The root-cause diagnosis is PR #366's, from a concurrent session; it was reverted
(e7fd5ec) because it carried the same bind-into-a-stalled-container defect agy had
already found here, and because it was merged without checking for concurrent work
on the same bug. This branch keeps its diagnosis and drops its design. See memory
`feedback_launchd_tcc_appdata_consult`.

See memory `feedback_helper_pkg_launchd_entitlement`.
