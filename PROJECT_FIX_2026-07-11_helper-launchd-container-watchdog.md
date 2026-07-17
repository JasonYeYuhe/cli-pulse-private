# PROJECT_FIX 2026-07-11 — helper launchd cold-login container hang → watchdog respawn

> **SUPERSEDED 2026-07-17 — THE DIAGNOSIS BELOW IS WRONG. DO NOT BUILD ON IT.**
> The hang is not a containermanagerd cold-login race. It is a TCC
> `kTCCServiceSystemPolicyAppData` consult on the first container `open(2)`,
> which costs 1–10s in *any* launchd-spawned process (reproduced with an
> unrelated, unentitled interpreter) and is **per-process — nothing ever gets
> "warm"**. The 12s watchdog + `os._exit(75)` respawn therefore could not work:
> each respawn restarted a full-price consult and killed it at the same ceiling,
> turning a slow-but-completing operation into an infinite respawn loop that also
> broke fresh installs and every mid-session restart.
> See **`PROJECT_FIX_2026-07-17_helper-launchd-tcc-appdata-consult.md`**.

## Symptom (P0, held the helper .pkg 1.29.0 rollout)
On **macOS 26.5.0** the `.pkg`-installed Python helper (`yyh.cli-pulse.helper`
LaunchAgent, `RunAtLoad=true`) would, **at login**, block forever on its first
app-group-container access — `rotate_token()`'s `os.open` of
`~/Library/Group Containers/group.yyh.CLI-Pulse/helper-auth-token.tmp`. The UDS
socket never bound, so the macOS app showed the companion CLI "not installed",
and `KeepAlive` could not recover it (a hung process never exits). The same
binary run foreground bound in ~1s (it inherits the shell's Full Disk Access).
The app-group entitlement shipped in 1.18.1 (`PROJECT_FIX_2026-06-18…`) fixed
the older **in-kernel** variant (STAT `U`, unkillable) but does **not** cover
this 26.5 **containermanagerd consult** variant (STAT `S`, killable).

## Diagnosis on this Mac (26.5.1, build 25F80, Darwin 25.5.0)
Reproduced by bootstrapping the LaunchAgent while the system was **warm**: the
`.pkg` 1.28.0 helper under launchd did **NOT** hang — it rotated the token in
~2s and ran normally (helper.err.log: `rotated local auth token` → cleanly
ceded the socket → `synced 7 sessions`). A stuck sample only ever showed a
transient TLS handshake, never `os_open`. Conclusion: the hang is a
**cold-login race** — the LaunchAgent fires before `containermanagerd` has
provisioned the group container for this Developer-ID (non-sandboxed) process;
once containermanagerd is warm the access is instant. The 26.5.1 point release
+ warm state clears it, but the cold-login path cannot be proven gone without a
logout/login, and shipping on that assumption is unsafe.

## Fix — convert an infinite hang into a self-healing respawn
`helper/cli_pulse_helper.py`: new module-level `_rotate_token_or_respawn()`
wraps the startup `rotate_token()` call in a `threading.Timer` watchdog
(`_CONTAINER_ACCESS_WATCHDOG_S = 12.0`, a generous 6× the ~2s warm cost). If
the container access exceeds the ceiling, the watchdog logs a clear line and
`os._exit(75)` (EX_TEMPFAIL) so the LaunchAgent's `KeepAlive` respawns the
helper against a now-warmer containermanagerd. On the warm path (2s ≪ 12s) the
watchdog is cancelled cleanly — **zero behavior change**. Worst case at cold
login: a few ~22s respawn cycles that self-clear within seconds of login,
instead of a permanent silent hang + manual `nohup` stopgap.

Call site (`daemon()`): `rotate_token()` → `_rotate_token_or_respawn(rotate_token)`.
`os`, `threading`, `logging` already imported. The watchdog fires the process
exit from a Timer thread, which works because 26.5's variant is interruptible
(STAT `S`); the older unkillable in-kernel variant is separately covered by the
still-present app-group entitlement.

## Tests
`helper/test_container_watchdog.py` (3 cases, all green): fast rotation returns
the token and never exits; a hang past the ceiling hard-exits `75` near the
ceiling (not after the full slow call); a `rotate_token` exception propagates
and the watchdog is cancelled (never fires).

## Not done here / ships with 1.29.0
- End-to-end cold-login validation happens at the owner's next login/reboot
  (part of the normal on-device smoke). The change is strictly safer than
  1.28.0 regardless.
- The socket bind is the second container touch; once `rotate_token` (the
  canary) succeeds the container is warm, so bind was left unguarded.

See memory `feedback_helper_pkg_launchd_entitlement`.
