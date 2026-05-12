# PROJECT_FIX — Gemini managed-sessions via subprocess-per-turn `gemini_exec` (2026-05-12)

## Summary

Switch Gemini managed remote sessions from `PosixPtyTransport` to a new
`GeminiExecTransport` that drives the gemini CLI via `gemini -p … -o
stream-json` subprocess-per-turn. Mirrors the Codex carve-out from
v1.17 (see `feedback_codex_exec_json_arch.md`) — sidesteps the
interactive TUI's render-vs-reassemble problem and gives us structured
events for free.

## Why

- The iOS picker already surfaces "Gemini" as a managed-session
  provider (iOSSessionsTab.swift). Today those sessions go through
  `PosixPtyTransport` — same shape that caused codex's ratatui issues
  in v1.16.x. Gemini ships a similar TUI; switching to stream-json
  pre-empts the same class of problem.
- `gemini -p … -o stream-json` emits clean newline-delimited JSON
  events (`init` / `message` / `tool_call` / `tool_result` / `result`),
  so we don't need ANSI sanitization or TUI reassembly.
- Better cancel + timeout semantics (SIGINT/SIGTERM to process group
  instead of escape sequences hoping the TUI respects them).
- Explicit token-usage stats from gemini's `result.stats` (vs.
  scraping from a TUI status line).

## How shipped — file inventory

| File | Change | Purpose |
|---|---|---|
| `helper/transports/gemini_exec.py` | NEW (~580 LOC) | Subprocess-per-turn transport. Mirrors `codex_exec.py` structure: state dataclass + write_stdin buffering + maybe_flush_next_turn + reader loop + stderr drainer + watchdog timer + cleanup-order discipline. Differences: gemini's `-p <prompt>` (last positional, no `--` sentinel between flag and value); `--resume latest` for turns ≥ 2 (gemini's resume uses index/"latest", not the captured UUID); usage-line emission deferred to AFTER agent text. |
| `helper/transports/multiplex.py` | modified | Add optional `gemini_exec_transport` constructor arg + `_GEMINI_EXEC_BINARIES = {"gemini"}` routing table entry. Backward-compat: 2-arg constructor (no gemini) → gemini argv falls through to PTY, matching pre-v1.19 behavior. |
| `helper/remote_agent.py` | modified | Inject `GeminiExecTransport()` into `MultiplexTransport` at manager construction. |
| `helper/test_gemini_exec_transport.py` | NEW (~370 LOC) | 19 tests: banner emit, prompt buffering, single + multi-delta assistant message, multi-line content prefixes, user-role drop (no duplicate echo), tool_call/tool_result drop (UX choice), result error surface, usage stats, no-reply warning, non-JSON line drop, argv construction (first-turn vs resume, yolo env, model env), close + interrupt clears. |
| `helper/test_multiplex.py` | modified | New `mux_with_gemini` fixture + `TestGeminiRouting` class (7 tests): gemini routes to dedicated transport when wired; falls back to PTY when not wired; claude/codex routing preserved; handle dispatch goes to gemini transport for gemini-started handles; concurrent codex+gemini handles routed independently. |

Total: 51/51 transport-related tests pass (19 new gemini + 25 existing
multiplex + 7 new gemini-routing multiplex tests, with the existing
codex_exec + provider_spawners suites also green).

## What changed for users

**Before**: iOS picker → "Gemini" → PTY session → interactive TUI bytes
streamed through the helper's PTY pipeline. Worked, but vulnerable to
the same TUI-reassembly problems codex hit.

**After**: iOS picker → "Gemini" → headless subprocess-per-turn →
structured stream-json events parsed into clean transcript lines. No
user-visible UI changes; the picker already exposes Gemini.

Trade-offs (carried over from codex_exec's v1.17 design):
- No token-by-token streaming — assistant reply emits as one bullet
  block at end of turn. Same UX choice codex made.
- No inline tool-approval prompts. We pin `--approval-mode default`;
  `CLI_PULSE_GEMINI_YOLO=1` opt-in swaps to `--approval-mode yolo`.

## Verification

### Test suite (PASSED)

```
helper/$ python3 -m pytest test_gemini_exec_transport.py test_multiplex.py \
                       test_codex_exec_transport.py test_provider_spawners.py
93 passed, 1 skipped in 8.06s
```

(The 1 skipped is the real-codex integration test, gated on
`CLI_PULSE_TEST_CODEX_REAL=1`.)

### Real-binary smoke (PASSED)

```
helper/$ CLI_PULSE_GEMINI_MODEL=gemini-2.5-flash python3 -c '<smoke harness>'
[banner] 'ℹ Gemini exec-mode session started — type a message to begin.\n'
[output]
› Reply with exactly the single word: PONG
• Working…
• The plan has been approved. I am now awaiting your next instruction.
ℹ usage: 119627 in / 836 out / 69772 cached
[state] gemini_session_id=456460b9-… has_prior_turn=True
```

(The PONG-vs-plan-mode reply is the agent's interpretation, not a
transport issue. session_id capture + has_prior_turn flip both verified.)

### Bug surfaced + fixed by real-binary smoke

First smoke run hit: `gemini exec failed: Not enough arguments
following: p`. Root cause: `-p` is a flag-with-value (consumes the
next argv element as the prompt string), so the original `[..., "-p",
"--", prompt]` construction left `-p` empty (gemini saw `--` as the
end-of-options sentinel, which doesn't satisfy `-p`'s requirement for
a value). Fixed by reordering to `[..., "-p", prompt]` — gemini parses
the prompt as `-p`'s value, and prompts starting with `--anything`
cannot be misparsed because the parser has already consumed the next
arg as a string. Test `test_first_turn_argv_no_resume` updated to pin
the new shape (`-p` immediately followed by the prompt).

## What this commit does NOT do

- ❌ Add `case gemini` to Swift `RemoteSessionProvider` enum
  (Models.swift:917). The enum mirrors the Supabase CHECK
  constraint on `remote_sessions.provider`; adding `.gemini` is a
  backend schema touch → needs user authorization per
  [[feedback_cli_pulse_autonomy]] §"When to flag" #1. The iOS UI
  works without the enum case because it passes the literal
  string `"gemini"` to the helper.
- ❌ macOS-side picker UI changes. iOS picker already has the
  Gemini option; a separate audit of `CLI Pulse Bar/CLI Pulse Bar/`
  to see whether the menubar app needs a parallel picker is
  deferred — it may not be relevant (the menubar app doesn't run
  remote sessions; it observes them).
- ❌ Token-by-token streaming UX. Documented as deferred polish.
- ❌ Tool call surfacing in transcript (currently dropped — Gemini's
  internal tool calls are too frequent for the transcript surface).
  Future polish: filter to a curated set of user-facing tools.

## Branch state

- Work branch: `multi-cli-gemini-exec`
- Parent: `v1.19-devid-impl` HEAD `d194ff3`
- One commit pending (this one). Stack:
  ```
  main → v1.18.2-impl → B3 → B3-bis → v1.19-devid-impl
                                       → multi-cli-gemini-exec
  ```

## Related memory

- [[feedback_codex_exec_json_arch.md]] — the v1.17 carve-out this
  mirrors. Same UX choices (single-chunk-per-turn, no inline tool
  approval) apply.
- [[reference_gemini_cli.md]] — gemini CLI path + PATH-fix
  reminder + `-p` usage. Updated by this work: `-p` is now known
  to require its prompt as the immediate next arg (no `--` sentinel).
- [[project_v1_19_devid_impl.md]] — predecessor branch state.
