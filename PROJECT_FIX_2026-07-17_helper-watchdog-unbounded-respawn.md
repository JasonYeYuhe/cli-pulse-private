# PROJECT_FIX 2026-07-17 — helper watchdog respawned 2,816× over 10h → bound it, then start degraded

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

## What we measured (and what we still don't know)
Measured on the affected machine (macOS 26.5, Darwin 25.5.0):

| Probe | Result |
|---|---|
| launchd-spawned process: `ls` + create file in the container | **41ms** — the container is not slow |
| helper's `com.apple.security.application-groups` entitlement | present, `group.yyh.CLI-Pulse` — not the empty-entitlement bug |
| containermanagerd | running, **zero** error/deny/timeout lines during the failures |
| tccd | **zero** events mentioning the helper |
| a **second** live helper as the cause | **refuted** — 0 trips with one running |
| machine sleep as the cause | **refuted** — no gaps >2min across 10h |
| same binary from a **shell** | binds in ~2s — but a shell inherits the terminal's Full Disk Access, so that path never exercises the entitlement |
| unentitled process under launchd touching the container | instant `EPERM` — the path is TCC-protected |

**Root cause: NOT established.** The stall is real and reproducible in the field but
did not reproduce on demand afterwards. The "cold-login containermanagerd race"
label is a *hypothesis*, and 1.29.0 staked the helper's availability on it being
right. This fix deliberately does not.

## Fix — bound the optimism, then honour the policy the call site already declares
`daemon()` has always documented the correct fallback for a token failure:

> "Token rotation is best-effort: `hello` is unauthenticated, so a token failure
> must NOT stop the socket from binding (that would regress detection).
> Authenticated methods fail closed downstream."

`os._exit(75)` **violates that policy** — it guarantees the socket never binds. So:

1. `rotate_token` now runs on a **daemon thread** with a deadline. 1.29.0 ran it on
   the main thread, where the only escape from a stall was `os._exit` from a Timer —
   which is *why* it had no option but to die. A daemon thread can be abandoned.
2. First `_MAX_CONTAINER_RESPAWNS` (3) consecutive stalls still hard-exit 75 —
   cheap, ~13s each, and it genuinely clears a transient stall. ~40s of retrying.
3. After that: **give up on the token and start degraded** — return `None`, skip
   the local UDS surface (see below), and keep the cloud loop running.
4. Counter lives at `~/Library/Logs/CLI-Pulse-Helper/.container-respawn-count` —
   deliberately **not** in the app-group container (the one resource we can't
   reliably touch; a counter we can't read is a counter that never stops the loop).
   Reset on success **and on a fast raise** (a raise is not a stall — the container
   answered). If it can't be **written** we refuse to respawn at all: an
   uncountable respawn is an unbounded one. Out-of-range values (`int()` parses
   `-1000000`) clamp to "spent" — failing toward degraded, never toward a loop.
5. The log line no longer asserts a root cause it doesn't have.

**Degraded does NOT bind the socket** (review: agy — this was the fix's critical
flaw on first draft). `default_socket_path()` is `container_dir() / SOCK_FILENAME`
— the socket lives INSIDE the stalled container. `LocalSessionServer.start()` does
mkdir/exists/unlink/bind/chmod on that path, on the main thread, unguarded, so
binding after the canary just timed out would hang the daemon forever: the
pre-1.29 permanent silent hang, which is *worse* than the loop (launchd can't
restart a hung process). 1.29.0's reasoning — "once rotate_token, the canary,
succeeds the container is warm, so bind is safe" — is sound wherever the canary
SUCCEEDS; it simply doesn't extend to the path where it failed. So degraded skips
the local surface entirely and keeps the cloud loop, exactly as that block's own
preamble prescribes: "the daemon still services Supabase-routed sessions even if
the local socket can't bind".

**Degraded is safe**: with no socket there is no local auth surface at all. And
`compare()` is `if not expected or not supplied: return False`, so an empty token
could never authenticate even if one were bound. Pinned by
`test_empty_token_never_authenticates`.

**Degraded does not self-heal in place** — an earlier draft of this doc claimed it
did, via `_get_token()`'s per-request re-read. That was true only of the design
that bound the socket. With no server, nothing re-reads the token: the local fast
path returns on the next restart (login / `.pkg` upgrade / crash + KeepAlive).
Cloud sync runs throughout.

Giving up **resets** the counter on purpose: a later boot may be a genuinely
different situation (a real cold login) and deserves its retries. That cannot
re-loop, because the degraded process stays alive — nothing restarts it.

## Tests
`helper/test_container_watchdog.py`, 10 cases, all green. The two that matter were
verified to **FAIL against the 1.29.0 semantics** (restore the unconditional
hard-exit and they go red):
- `test_stall_past_budget_starts_degraded_instead_of_looping`
- `test_respawn_budget_is_actually_bounded` (fake `os._exit` **raises** rather than
  returning — a fake that returns doesn't test the real control flow, and the first
  draft of this test passed for exactly that wrong reason)
- `test_unpersistable_counter_refuses_to_respawn` — an uncountable respawn IS an
  unbounded one (both reviewers). My first version of this test was fiction: one
  boot, asserting `codes == [75] or token is None`, which the bug itself satisfies.
- `test_corrupt_counter_cannot_reopen_the_loop` — `int()` parses `-1000000`, which
  keeps the budget open for a million restarts (codex).
- `test_rotation_exception_resets_the_consecutive_run` — a raise is not a stall
  (codex).

Also: an explicit `return None` after `os._exit` so the respawn branch can't fall
through into the give-up path and silently un-bound the budget.

## Not done here
- **Root cause of the stall itself.** Still open. Next probe: a `spindump` of the
  stalled process (plain `sample` misses it — the watchdog `os._exit`s every 12s;
  raise `_CONTAINER_ACCESS_WATCHDOG_S` temporarily to catch it), and check whether
  the stall is in the entitlement-mediated container vend rather than plain file IO.
- **The Swift helper has no equivalent guard**, and its entitlements are empty — it
  works today only because it's launched with inherited FDA. Worth auditing.

See memory `feedback_helper_pkg_launchd_entitlement`.
