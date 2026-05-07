# PROJECT_FIX — v1.12.2 — Poll Timeout + Risk Classifier Hardening

**Date:** 2026-05-07
**Branch:** `v1.12.2-poll-timeout-and-risk-classifier` (cut from `main` after v1.12.1 merged)
**Source:** Sprint B of cross-team backport from cli-pulse-desktop's v0.7.0
Gemini 3.1 Pro post-impl review. See
`memory/feedback_mac_windows_remote_track_alignment.md` items #7b (M2) and #1 (M3).
Both **P2** — quality of service / robustness, not the immediately-exploitable
class that gated v1.12.1.

## Why two fixes in one release

Both items live entirely in the Python helper, and both harden the same
remote-approval hook flow against silent-degraded-mode failures:

- **M2** caps a single Supabase call so a hung request can't burn the
  whole hook budget.
- **M3** fixes whitespace-perturbed evasions of the high-risk Bash
  classifier, which currently silently misroutes truly destructive
  commands through the remote-approval channel instead of failing
  closed locally.

## Files changed

| File | Change |
|---|---|
| [helper/cli_pulse_helper.py](helper/cli_pulse_helper.py) | `supabase_rpc` accepts a new keyword-only `timeout: float = 30.0` and forwards it to `urllib.request.urlopen`. Default preserves the historical 30s for daemon bulk-sync callers (commits / sessions / alerts). |
| [helper/remote_hook.py](helper/remote_hook.py) | `HookConfig` gains `request_timeout_s: float = 2.5`; both the `create_permission_request` and `poll_permission_decision` rpc_caller calls now pass `timeout=cfg.request_timeout_s`; CLI gains `--request-timeout` arg threading through to `HookConfig`. |
| [helper/provider_adapters/claude.py](helper/provider_adapters/claude.py) | New `_is_high_risk_bash` token-level classifier replaces the substring-loop in `_classify_risk`. Token-equality on `_SINGLE_TOKEN_DANGER` prevents false positives like `sudoer-config-tool` matching `sudo`; whitespace-tolerant via `command.split()`; `rm` paired with destructive flag clusters covered for both single-token (`rm -rf`) and split-flag (`rm -r -f`) forms. |
| [helper/test_remote_hook.py](helper/test_remote_hook.py) | All existing `def fake_rpc(name, params)` updated to `def fake_rpc(name, params, **_kwargs)` to tolerate the new `timeout` kwarg. New "M2 per-request HTTP timeout" section: 5 tests covering urlopen kwarg pass-through, 30s default, create-RPC timeout pass-through, configurable request_timeout_s, CLI `--request-timeout` flag plumbing. New "M3 token-level high-risk Bash classifier" section: 33 tests covering canonical destructive forms, whitespace-perturbed forms, non-destructive `rm`, single-token dangers, remote-transfer tokens, chmod 777 root vs local, fork bomb, history clear, kextload/csrutil, substring false-positive guards, `dd if=` requirement, low-risk-tool regression guard, missing-command graceful-medium. |

## Per-fix root cause + what changed

### M2 — per-request HTTP timeout (cli-pulse-desktop v0.7.0 P2 backport)

**Root cause:** the remote-approval hook poll loop calls `rpc_caller(...)` →
`cli_pulse_helper.supabase_rpc(...)` → `urllib.request.urlopen(request, timeout=30)`.
A single hung Supabase call therefore blocked for up to 30s, which is 3× the
hook's overall `cfg.timeout_s = 10.0` budget. In practice the urlopen 30s
ceiling rarely triggered (TCP / TLS errors fail much faster), but a slow
Supabase status (high-latency datacenter, congested upstream proxy, or a
single stuck server-side connection) could observably make the hook itself
hang well past its advertised 10s budget — bypassing Claude's expectation
that the hook returns quickly.

cli-pulse-desktop's v0.7.0 already uses `tokio::time::timeout(2.5s)` per
RPC call, so each poll iteration is bounded; if a single call stalls the
2.5s ceiling fires, the hook treats it as a transient error, sleeps the
poll-interval, and tries again on the next cycle until the overall
`cfg.timeout_s` budget expires.

**Fix:**
- New `timeout` keyword-only parameter on `supabase_rpc`. Forwarded to
  `urllib.request.urlopen`. Default 30.0s to preserve all existing daemon
  callers.
- `HookConfig.request_timeout_s = 2.5` matches Windows v0.7.0 exactly.
- Both `remote_helper_create_permission_request` and
  `remote_helper_poll_permission_decision` calls now pass
  `timeout=cfg.request_timeout_s`. The create call also benefits — it's a
  single RPC at the top of the hook, and a 30s stall there means Claude's
  user sees a 30s freeze before the local-fallback fires.
- `--request-timeout` CLI flag threads through to `HookConfig`. Useful
  for environments where the operator wants a tighter (or looser) ceiling
  than the default; tests use small values (e.g. 0.75) to exercise the
  pass-through quickly.

**Test coverage (5 new tests):**
- `test_supabase_rpc_passes_timeout_kwarg_to_urlopen` — mock urlopen,
  verify the kwarg is forwarded.
- `test_supabase_rpc_default_timeout_is_30s` — regression guard for
  non-hook callers.
- `test_run_hook_create_passes_request_timeout_to_rpc` — kwargs capture
  on the create RPC.
- `test_run_hook_request_timeout_is_configurable` — non-default
  `HookConfig.request_timeout_s` threads through to every RPC call.
- `test_main_cli_request_timeout_arg_threads_through` — the CLI flag
  populates `HookConfig`.

**No protocol change.** Existing tests using `def fake_rpc(name, params)`
were updated to `def fake_rpc(name, params, **_kwargs)` so they tolerate
the new kwarg without asserting on it; tests that explicitly inspect the
kwarg use a separate fake.

### M3 — token-level high-risk Bash classifier (cli-pulse-desktop v0.7.0 P1 backport)

**Root cause:** `_classify_risk` in `claude.py` matched dangerous bash
patterns by raw substring (`tok in cmd`). The token tuple included
`"rm -rf"` and `"rm -fr"` — exactly one space between the verb and flag.
Any whitespace perturbation evaded the match:

- `rm  -rf /tmp` (double space) — fails `"rm -rf" in cmd`
- `rm\t-rf` (tab between) — fails
- `rm -r -f /tmp` (split flags) — fails
- `rm -rfv /tmp` (extra verbose flag) — fails

LLMs driving Claude's Bash tool are statistically more likely than humans
to emit non-canonical whitespace (multi-space alignment, tab indentation
of multi-line commands). A successful evasion routes the command through
the remote-approval channel as MEDIUM risk, where the user sees a
non-fail-closed prompt — the exact bypass the high-risk classifier exists
to prevent.

The classifier also had substring-style false positives on the inverse:
`./sudoer-config-tool` contains `"sudo "` (note: the tuple had `"sudo "`
with trailing space) — actually no, with the trailing-space form the false
positive doesn't fire on `./sudoer-config-tool`. But `"curl "` (trailing
space) DOES match `forecast-curl-stats /` because the substring `"curl "`
appears in `"-curl-stats "`. Token-level matching avoids this entirely.

**Fix (mirrors `risk.rs::is_high_risk_bash`):**
- Substrings reserved for patterns where whitespace IS the structural
  signature (fork bomb, `chmod 777 /`, `history -c`).
- Single-token equality for the rest (`sudo`, `mkfs`, `shutdown`,
  `reboot`, `killall`, `kextload`, `csrutil`, `curl`, `wget`, `ssh`,
  `scp`, `rsync`).
- `dd` only triggers if the command also contains `if=` (avoids
  false-positive on `cd dd-folder/`).
- `rm` paired with destructive flag clusters: scan tokens after `rm`,
  check both single-token form (next token contains both `r` and `f`)
  and split-flag form (consecutive flag tokens collectively contain `r`
  and `f`).

**Behavioral parity with cli-pulse-desktop v0.7.0:**
- `mkfs.ext4 /dev/sda1` is MEDIUM (`mkfs` is the bare-token danger;
  the suffixed `mkfs.ext4` is a different token). Tested explicitly so
  drift surfaces here, not in production.
- `chmod 777 ./file.sh` is MEDIUM (matches Windows; setting permissive
  perms on a project file is recoverable).
- `rm -i file.txt` is MEDIUM (interactive flag, not `-r` / `-f`).
- Bare `dd` is MEDIUM (no `if=` flag).
- `pip install requests` is MEDIUM (`requests` is a project name, not
  the `rsync` / `ssh` / `scp` token list).

**Test coverage (33 new tests, mostly parametrized):**
- 8 destructive `rm` forms classified HIGH.
- 3 non-destructive `rm` forms classified MEDIUM.
- `sudo` / `mkfs` token coverage incl. trailing-pipe `find … | sudo cat`.
- `curl` / `wget` HIGH; `ssh` / `scp` / `rsync` HIGH.
- chmod 777 root HIGH vs local MEDIUM.
- Fork bomb HIGH; `history -c` HIGH; `kextload` / `csrutil` HIGH.
- 5-fixture parametrized substring-false-positive guard
  (`sudoer-config-tool`, `forecast-curl-stats`, `ssh-keygen`,
  `less /var/log/messages`, `pip install requests`).
- `dd if=` HIGH vs `ls dd-folder/` MEDIUM vs bare `dd` MEDIUM.
- LOW-risk-tool regression guard (Read / Glob / Grep / WebFetch /
  WebSearch / TodoRead).
- Unknown-tool default MEDIUM.
- Bash with missing/non-string command degrades gracefully to MEDIUM.

## Verification

| Step | Result |
|---|---|
| `python3 -m pytest helper/test_remote_hook.py -v` | **59/59 passed** (21 existing + 38 new) |
| `python3 -m pytest helper/` | **326/326 passed** (288 → 326, no regressions) |

No Swift changes in this PR — the M2 and M3 fixes both live entirely in the
Python helper. Phase 4E will port these to Swift later (see Sprint C).

## Out of scope / remaining TODOs

- **HelperKit Swift parity** (Sprint C / Phase 4E): when the Swift
  helper takes over the live runtime, both `_is_high_risk_bash` and the
  per-request 2.5s timeout need a Swift mirror. Track in
  `docs/PHASE_4E_DEV_PLAN.md` (to be drafted in Sprint C).
- **Sensitive-filename blocklist** (`.env`, `id_rsa`, `*.pem`,
  `credentials.json`, `~/.aws/credentials`): tracked in
  `provider_adapters/claude.py`'s "Future work (Gemini review P3 #9)"
  comment block. v0.7.x cli-pulse-desktop will land first, then Mac
  ports.

## Cross-team note

Closes Mac M2 + M3 from
`memory/feedback_mac_windows_remote_track_alignment.md` Mac sprint table.
With v1.12.1 (M1+M4) already merged, the entire 4-item cross-team
backport is now complete on Mac. Windows v0.7.0 has no reciprocal action
items from this sprint — Windows track remains 0 blocking.
