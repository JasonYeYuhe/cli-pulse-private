# PROJECT_FIX — v1.18.2 codex_exec.py P1 集合 (A–E)

**Date:** 2026-05-12
**Branch:** `v1.18.2-impl` (off `v1.18.1-hotfix @ 0ef3400`)
**Status:** **Implementation complete + tested + Gemini reviewed; awaiting user
ship decision** (no public push, no helper-releases publish, no ASC)
**Reviewers:** Gemini 3.1 Pro (plan review + final patch review) + self-review
**Scope:** Defensive hardening of `helper/transports/codex_exec.py`, single
file. Zero app-side / iOS / macOS / Android changes. Ship vehicle when
authorized: helper `.pkg v1.17.3` republish only.

---

## The 5 P1 fixes

| # | Defect | Root cause | Fix shape |
|---|---|---|---|
| **A** | stderr fd leak per turn | `_reader_loop` finally only reads stderr on error path; never closes either pipe. GC eventually reclaims fds but timing is unpredictable, so a 100+ turn session can hit ulimit. | `_close_proc_pipes(proc)` helper closes stdout + stderr fds explicitly in every finally exit. |
| **B** | 64KB pipe-buffer deadlock | codex emits > pipe buffer to stderr (64KB Linux / 16-64KB macOS) → blocks on write(2) → reader never sees stdout EOF → turn deadlocks until helper death. | `_stderr_drainer` daemon thread per turn drains stderr concurrently into `s.stderr_buf` (32KB cap, tail-rotates). |
| **C** | Silent network hang bypasses timeout | `if time.time() > deadline:` inside `for raw_line in proc.stdout:` never fires when stdout blocks waiting for TCP packets that never arrive. | External `threading.Timer` armed at spawn; `_timeout_kill` SIGTERMs proc + sets `s.timed_out`. Reader's finally cancels timer on normal exit and emits a precise `codex turn timed out` marker. |
| **D** | SIGINT cancel UX | User's Ctrl-C → proc dies rc=-2 → finally enqueues `✗ codex exec failed: exit code -2` → looks like a codex bug, not a deliberate cancel. | `interrupt()` sets `s.cancel_pending = True` under lock before SIGINT. Reader's finally consults this and emits `✗ codex turn cancelled` instead. |
| **E** | First-turn crash silently resets conversation | If turn 1 crashes before `thread.started`, `s.thread_id` stays None. User types again, `_build_exec_argv` falls back to first-turn branch and starts a brand-new conversation. User has no signal. | Orthogonal append in reader's finally: if primary marker emitted AND `s.thread_id is None`, also emit `⚠ Session reset — your next prompt will start a new conversation`. |

---

## State additions to `_CodexExecState`

```python
stderr_drainer_thread: Optional[threading.Thread] = None   # P1-B
stderr_buf: bytearray = field(default_factory=bytearray)   # P1-B (32KB cap)
timeout_timer: Optional[threading.Timer] = None            # P1-C
timed_out: bool = False                                    # P1-C
cancel_pending: bool = False                               # P1-D
# P1-E uses existing `s.thread_id is None` check — no new flag
# (Gemini SUGGESTION 1: thread_id_captured boolean was redundant)
```

All flags cleared at turn start; consumed and reset in reader's finally
under lock.

## `_reader_loop` finally cleanup order (load-bearing)

Order revised twice by Gemini review:
1. **plan review CRITICAL**: reap proc before joining drainer (forces stderr EOF)
2. **final-patch review CRITICAL**: read `stderr_buf` *under lock*, not lock-free, in case a child process inherited the stderr fd and kept the drainer alive past its bounded join

Final sequence:
```
① timer.cancel()             — disarm watchdog
② proc.wait(timeout=2)/kill  — forces stderr EOF
③ drainer_thread.join(1.0)   — now instant; safety belt only
④ with s.lock:                — read buf + consume per-turn flags atomically
     stderr_text = bytes(s.stderr_buf).decode(...)
     timed_out, cancel = s.timed_out, s.cancel_pending
     s.timed_out = False; s.cancel_pending = False
⑤ pick marker (decision table)
⑥ _close_proc_pipes(proc)    — release fds (P1-A)
⑦ with s.lock:                — _maybe_flush_next_turn  (caller-holds-lock contract)
```

## Marker decision table

Precedence: **`timed_out` > `cancel_pending` > `(no agent + rc≠0)` failure > `(no agent + rc=0)` quiet exit > happy path**.

Session-reset is appended orthogonally to any non-happy primary marker
when `s.thread_id is None`. Cancel + session-reset is the
first-turn-cancelled case and both markers fire intentionally.

| primary marker | when |
|---|---|
| `✗ codex turn timed out` | watchdog fired |
| `✗ codex turn cancelled` | interrupt() set cancel_pending |
| `✗ codex exec failed: <stderr or rc>` | rc≠0 + no agent text |
| `⚠ codex exited without reply` | rc=0 + no agent text (corrupt JSONL / unsupported events) |
| (none — happy) | rc=0 + agent text emitted |

---

## Tests added (6, in `TestV182P1Defenses`)

1. `test_stderr_drainer_survives_80kb_emission` — 80KB stderr; turn completes; `stderr_buf ≤ 32KB`
2. `test_proc_pipes_closed_after_turn` — drainer thread dead after turn end (transitive proof of pipe closure)
3. `test_timeout_watchdog_kills_silent_hang` — monkeypatched `_TURN_TIMEOUT_SEC=0.5`; sleeping fake codex; `codex turn timed out` marker fires; no generic failure marker
4. `test_interrupt_emits_cancelled_marker` — spawn → interrupt; `codex turn cancelled` marker; no generic failure marker
5. `test_first_turn_crash_emits_session_reset_marker` — rc=1 + no thread.started; both `codex exec failed` AND `Session reset` markers present
6. `test_no_session_reset_marker_when_thread_started_seen` — thread.started then rc=1; `codex exec failed` present; `Session reset` NOT present

`_make_fake_codex_script` fixture extended with `stderr_lines`, `stderr_bulk_bytes`, `sleep_before_exit`, `name` knobs.

**Gates:** 14 pre-existing + 6 new = **20 passed / 1 skipped** in `test_codex_exec_transport.py`. Full helper suite: **434 passed / 1 skipped in 28s** (the 1 skip = pre-existing `CLI_PULSE_TEST_CODEX_REAL=1` integration gate).

PyInstaller smoke build (onedir mode, host arm64): clean — no missing imports, binary boots, `--help` lists all subcommands, all 5 new state fields imported and instantiable.

---

## Gemini 3.1 Pro review trail

- **Plan review** (`/tmp/clipulse-review/gemini-plan-v1.18.2.out`):
  - 1 CRITICAL: finally ordering — reap proc before joining drainer (adopted)
  - 1 SHOULD_FIX: `_timeout_kill` must set a flag so we emit a precise `timed out` marker, not generic `exit code -15` (adopted)
  - 1 SHOULD_FIX: session-reset must append on ANY non-happy path, including `rc==0` (adopted)
  - 1 SUGGESTION: drop `thread_id_captured` boolean — use `s.thread_id is None` directly (adopted)
  - 1 SUGGESTION: marker text — prefix `codex turn …` so user can tell helper-side intervention vs codex bug (adopted)
- **Final-patch review** (`/tmp/clipulse-review/gemini-patch-v1.18.2.out`):
  - 1 CRITICAL: read `stderr_buf` under lock — drainer-still-alive race if a child inherited the stderr fd (adopted as commit `d3e8e10`)
  - 1 SHOULD_FIX: `_maybe_flush_next_turn` reentrancy — **rejected**: the function's docstring explicitly states "caller must hold s.lock"; this is the existing contract, not a bug. Pre-existing pattern, out of v1.18.2 scope.
  - 3 SUGGESTION: UTF-8 mid-character split (no action — `errors="replace"` covers it), clear `s.timeout_timer = None` (skipped, gets overwritten next turn), 7th orphaned-child test (skipped — codex CLI doesn't spawn stderr-inheriting backgrounders in practice; CRITICAL lock-fix already covers the race)

---

## Commits (in `v1.18.2-impl` branch order)

```
cc33de6 codex_exec: stderr drainer thread + explicit pipe close (P1-A + P1-B)
bffdc98 codex_exec: external Timer watchdog + timed_out flag (P1-C)
26437f7 codex_exec: distinct cancel marker on SIGINT interrupt (P1-D)
17129f9 codex_exec: session-reset marker on first-turn failure (P1-E)
f2d4498 test(codex_exec): 6 regression tests for v1.18.2 P1 defenses
d3e8e10 codex_exec: read stderr_buf under lock (Gemini final-patch CRITICAL)
```

Pushed to `origin/v1.18.2-impl` (private). Not on `main`. Not in
`cli-pulse-helper-releases`. No ASC submission.

---

## Ship sequence (when user authorizes)

1. Bump `HELPER_VERSION` 1.17.2 → 1.17.3 in `helper/system_collector.py` + `helper/cli_pulse_helper.py` (`--helper-version` default), commit + push.
2. Run `./scripts/build_helper_pkg.sh` (full sign + notarize); outputs `cli-pulse-helper-1.17.3-arm64.pkg` + `manifest-fragment-arm64.json`.
3. `gh release create v1.17.3 --repo cli-pulse/cli-pulse-helper-releases …` with the .pkg attached.
4. Replace `latest.json` asset on the `latest` release with the new manifest fragment.
5. Confirm `curl -sL .../latest/latest.json` shows v1.17.3.
6. Merge `v1.18.2-impl` → `main` (or keep as carry-along into next ASC train; user's call).

---

## What is NOT in this fix-pack (deferred)

- `_TURN_TIMEOUT_SEC` per-model tuning (o1-style thinking models can want 30s+)
- `transports/multiplex.py` cancel_pending semantics verification (likely a no-op pass-through, but not audited this round)
- `helper/test_system_collector.py::TestCollectAll::test_returns_result_with_no_crash` pre-existing hang (still pre-existing; not in scope)
- ClaudePeakFooter iOS wiring + i18n + MIT attribution (separate Priority 3 backlog item)
- HelperLogin / HelperLifecycleManager launchd label collision (Phase 4D/4E carry-over, autonomous prompt marked "不要碰")
- `sync-versions.sh` design gaps (release tooling, low urgency)
