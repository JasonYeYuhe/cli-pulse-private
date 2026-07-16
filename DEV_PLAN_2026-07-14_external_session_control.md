# DEV_PLAN 2026-07-14 — Remote Session hardening + External-session control

Owner ask: "把 remote session 这个功能做好,然后尝试控制不是通过 CLI Pulse 打开的 session
(别的地方比如 codex / claude code 开的 session),能够输入/输出 + approve/deny/other。你全权负责。"

Research: workflow `wf_cb338a89-213` (5 agents, 2026-07-14) — mapped managed-session +
R0 remote architecture, and empirically tested Claude hooks / Codex control surfaces /
terminal-injection on THIS Mac (macOS 26.5.2, SIP on, Claude Code 2.1.205, Codex 0.144.1,
tmux 3.6a Homebrew). Everything below is evidence-backed.

---

## 0. The honest capability map (what's actually possible)

| Goal | Claude Code (external) | Codex (external) |
|---|---|---|
| **approve / deny** a tool/permission | ✅ **YES** — `PermissionRequest` **and** `PreToolUse` hooks in `~/.claude/settings.json` fire for EVERY `claude` process (any terminal), hot-reload into running ones, and the hook can BLOCK up to `timeout` (default 600s) waiting for a remote decision. Infra 90% built already (`helper/remote_hook.py`). | ✅ **YES** — Codex embeds a Claude-compatible hooks engine (`feature hooks` = on); `~/.codex/hooks.json` `PermissionRequest` hook decides `allow`/`deny`. One-time trust via `/hooks` in the TUI (hash-pinned). |
| **observe output** (read transcript) | ✅ **YES read-only** — tail `~/.claude/projects/<cwd>/<sid>.jsonl` (full tool_use payloads) + live registry `~/.claude/sessions/<pid>.json` (pid/sid/cwd/kind). | ✅ **YES read-only** — tail `~/.codex/sessions/**/rollout-*.jsonl` + `~/.codex/state_*.sqlite` threads table; `notify` fires JSON on `agent-turn-complete`. |
| **inject input / new prompt** into a LIVE external TUI | ❌ **impossible** without wrapping — no IPC; `--resume -p` forks a parallel process, doesn't touch the TUI. Only path = **tmux wrap** (opt-in shell shim for FUTURE launches) or AppleScript (TCC + fragile). | ⚠️ **only via `codex app-server`** JSON-RPC for sessions CLI Pulse spawns/attaches (Thread/*, Turn/start|steer|interrupt, approvals). A bare external TUI exposes **no IPC** (`codex proto` removed in 0.144). |

**Terminal-injection matrix (tested):** tmux (send-keys/capture-pane/pipe-pane, control-mode) is the ONLY robust, permissionless, bidirectional mechanism — but only for sessions running **inside tmux**. iTerm2/Terminal.app AppleScript works but needs Automation-TCC + is emulator-specific. `TIOCSTI` is dead (EACCES on foreign tty, root-only). dtrace/ptrace/task_for_pid all need SIP-off or entitlements → unshippable.

**Takeaway:** the achievable, high-value core is **approve/deny + observe for external Claude & Codex sessions via the hooks + transcript mechanisms we mostly already have.** Full remote *input* to external sessions needs an opt-in **tmux-wrap** (future launches) — real, but a bigger/again-opt-in lever. Prioritize the hook path.

---

## 1. What already exists (don't rebuild)

- **Approvals plane (managed):** `helper/remote_hook.py` (risk classify, redact, upload `remote_helper_create_permission_request`, poll `remote_helper_poll_permission_decision`, 10s fail-closed deny, UDS fast path) + provider adapters (`ClaudeAdapter` done, `CodexAdapter` = **stub NotImplementedError**, `ShellAdapter`). App side: `remote_app_list_pending_approvals`/`remote_app_decide_permission`, APNs `send-approval-push`, `RemoteApprovalsEntryState` wired to Mac footer + iOS Settings/Overview.
- **Managed spawn:** `ManagedSessionManager` injects the hook **inline via `claude --settings <json>`** — so it only covers sessions CLI Pulse spawns. Terminal-launched Claude is deliberately untouched (no global `~/.claude/settings.json` mutation today).
- **`ClaudeHookDetector`** (Swift, read-only): already detects whether `~/.claude/settings.json` has our canonical `PermissionRequest` hook wired, and surfaces a "not wired" banner + copy-paste install command. **This is the seam for the global-install flow.**
- **Helper install flow:** `permissions_diagnose.install_claude_hook` (idempotent JSON merge) already exists on the Python side.
- **R0 remote terminal:** realtime broadcast (`pterm:`/`term:`), command RPC (prompt/input_raw/resize/stop/interrupt), works for managed sessions.

## 2. Known gaps in the EXISTING remote feature (the "做好" half)

From the R0 map (file:line in workflow report):
1. `RemoteSessionControlClient` is **dormant** — built + unit-tested, never instantiated (Mac↔Mac routing seam unused).
2. Swift (DEVID) helper has **no `pterm:` private producer** → private sessions on a Swift-helper Mac get zero live stream + zero tail-snapshot (degrade to 3s poll).
3. Approvals are **poll+APNs only** — worst case: 3s app poll races `remote_hook.py`'s 10s fail-closed deny. No realtime approval channel.
4. Input latency: 1 HTTPS RPC/keystroke + ~1Hz helper poll → ~0.5–1.5s floor; no coalescing/local echo.
5. `RemoteControlHealth.realtime` check is **dead** (both call sites omit it → never surfaced).
6. `RemoteTerminalKeyBar` Ctrl toggle is a **visual-only stub**; `remoteTerminalViewDidBecomeReady` is a no-op.
7. S7 public→private cutover **not executed** (public `term:` eavesdrop-by-UUID still the default for sessions the user starts from the phone). M4.4d (#364) does NOT change that default — but a **shared wrapped session is always minted private**, since publishing an externally-launched session on an RLS-bypassing topic isn't defensible. So the first `realtime_private = true` rows in prod come from this path, which also means it's the first path that actually exercises gap 2 (no `pterm:` producer ⇒ event-tail polling).
8. iOS scrollback 500 vs Mac 5000; no multi-terminal UI.

## 3. Proposed milestones (each = its own branch/PR, dual-reviewed, CI-gated)

### M1 — External Claude sessions: global approval hook + detection (highest value, lowest risk)
Extend the SHIPPED managed-approval infra to cover terminal-launched Claude.
- **Helper:** add `remote-approvals install-claude-hook --global` that idempotently merges a **`PreToolUse`** hook (canonical match-all `matcher:""`) into `~/.claude/settings.json` pointing at `<helper> remote-approval-hook --provider claude`. Why PreToolUse **and** PermissionRequest: on machines with a broad `Bash(*)`/`Edit(*)` allowlist (the owner's), `PermissionRequest` rarely fires; `PreToolUse` fires for EVERY tool call and can `ask`/`deny` — the always-present lever. Hook decides: if remote user approves → `allow`; deny → `deny`; timeout/unpaired → `ask` (fall back to the local TUI dialog, NOT a hard deny, so external sessions aren't bricked).
- **`remote_hook.py`:** support a `PreToolUse` code path (emit `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow|deny|ask"}}`); reuse the existing upload/poll/redact loop. Add a config knob so external (non-managed) sessions default to `ask`-on-timeout (fail-OPEN to local prompt) vs managed's `deny` (fail-closed).
- **App:** `ClaudeHookDetector` already detects wired/not — add a one-click **Install** (Mac: run the helper via UDS `install_claude_hook`; the helper writes the file — the app stays sandboxed). Detect + list **external** Claude sessions from `~/.claude/sessions/<pid>.json` (helper reads them, publishes as `detected` rows; the Sessions tab already has a `detectedLocalSessionsSection`).
- **⚠️ Persistent config change** (writes the user's `~/.claude/settings.json`): gated behind an explicit opt-in toggle + consent dialog, idempotent merge, never clobber, one-click uninstall. This is an OWNER decision to enable — surface it, don't do it silently.

### M2 — External Codex sessions: implement `CodexAdapter` + `~/.codex/hooks.json` install
- Fill the `CodexAdapter` stub: `parse_hook_input` for Codex's `PermissionRequest` stdin schema (`session_id, tool_name, tool_input, cwd, permission_mode, turn_id, transcript_path`), `emit_hook_output` `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow|deny"}}}`.
- Helper `remote-approvals install-codex-hook` → idempotent merge into `~/.codex/hooks.json`. **Note the one-time trust step** (`/hooks` in Codex TUI hash-pins the command) — surface this in the UI as a required manual step (can't be automated).
- App: extend `ClaudeHookDetector` → generic `HookDetector` per provider; Codex session detection via rollout JSONL + `state_*.sqlite`.

### M3 — Remote feature hardening (the "做好" half)
Pick the top gaps from §2: (a) realtime approval channel (push the pending-approval row over the existing `pterm:`-style broadcast so the app doesn't race the 3s poll vs 10s deny) — biggest UX win; (b) wire `RemoteControlHealth.realtime` into diagnostics; (c) keystroke coalescing for input; (d) iOS scrollback 500→ parity. Each independently shippable.

### M4 — (bigger, separate decision) tmux-wrap for full external I/O — **DONE**
Opt-in shell integration: bundle a signed tmux, ship a `clipulse_wrap` rc function so FUTURE `claude`/`codex` launches run inside a CLI-Pulse-owned tmux socket (status bar off, TERM passthrough) → CLI Pulse attaches in control mode for full read + `send-keys` input. **Persistent rc change → hard opt-in.** Only wraps future launches; TERM/render caveats to test.

Shipped as M4.1–M4.4d:
- **M4.1–M4.3** spike, `TmuxTransport`, opt-in shell integration.
- **M4.4a–c** (#360–#363) manager attach + bundled signed tmux + app UI. Attached sessions were hard LOCAL-ONLY here.
- **M4.4d** (#364) per-session cloud opt-in: the phone can see + drive a wrapped external session once the user explicitly says so. Backend `migrate_v0.69` adds `p_realtime_private` to `remote_helper_register_session`; session ids became deterministic **UUIDv5** (the register RPC takes a `uuid`, and `wrapped-<tmuxName>` isn't one).

**Known limits of M4.4d** (deliberate, not oversights):
- A shared wrapped session is minted `realtime_private = true` and the Swift helper has **no `pterm:` producer** (§2 gap 2) → the phone reads it through the durable event tail at **~3 s poll**, not a live stream. Closing gap 2 upgrades this for free.
- Cloud `stop` is refused for attached sessions: `terminate()` no-ops on a non-owning attach, so it could only report a false `stopped`. This is NOT a protection — sharing grants input, and input includes `C-c`.
- **Python twin has no cloud-share parity.** Swift is the shipped path; the app gates the toggle on advertised verbs, so a Python-owned socket degrades to "no toggle" rather than erroring.

## 4. Risks / decisions to flag
- Writing `~/.claude/settings.json` and `~/.codex/hooks.json` = **standing config changes on the user's machine.** All gated behind explicit opt-in + consent + one-click uninstall. Never silent. (The owner asked for this capability, so enabling it is in-scope — but the toggle is the owner's to flip.)
- Codex hooks need a **manual one-time trust** in the TUI — can't be fully automated; UI must instruct.
- Fail-OPEN vs fail-CLOSED: external sessions should fail-OPEN (timeout → local prompt) so a network blip never bricks someone's terminal Claude. Managed keeps fail-closed.
- `PreToolUse` on a broad-allowlist machine will fire a LOT (every tool call) → the hook must be fast (UDS fast-path, short remote timeout, then `ask`) or it adds latency to every tool. Default remote timeout short (e.g. 8s) then fall through to local.

## 5. Start here
M1 first — it reuses the shipped approvals pipeline, delivers the owner's core ask (approve/deny external Claude sessions from phone/Mac), and the persistent-config surface is contained + reversible.
