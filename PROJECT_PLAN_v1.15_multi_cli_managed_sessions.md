# PROJECT_PLAN — v1.15 Multi-CLI Managed Sessions

Date: 2026-05-08
Branch: `v1.15-multi-cli` (to create after v1.14 ships)
Author: Claude (planning) + YE (review)

## TL;DR

Today the iOS / macOS app can spawn a managed **Claude** session on the
paired Mac and stream its output. Extend the same control loop to
**Codex CLI** and **Gemini CLI** so users can pick their provider when
opening a remote session — same pairing, same approval surface (where
the provider supports it), same conversation preview UX.

Scope is conservative: no terminal emulator, no provider-CLI
re-implementation, no UI redesign. We extend the existing managed-session
plumbing with provider abstraction + per-provider TUI formatters.

## Why now

- v1.14 just landed. Conversation preview formatter is hardened against
  real Claude TUI traces (PR #41 commit `d5d4cdd`).
- Both `codex` and `gemini` ship interactive PTY-based REPLs. Same
  control surface as `claude`.
- `remote_sessions.provider` SQL check constraint already allows
  `'claude' | 'codex' | 'shell'` (migrate_v0.26). Need only one migration
  to add `'gemini'`.
- Sessions UI is already provider-agnostic at the data layer. The
  spawn-button is the only Claude-specific surface in the app today.
- User pain point: this is the natural follow-up to "iPhone session
  output stops at line 6" — once the Claude managed-session UX is
  reliable, the obvious question is "can I do this for my Codex
  workflow too?"

## Non-goals (explicit cuts)

- ❌ Terminal emulator / 1:1 TUI fidelity. Out of scope for any
  foreseeable release per [Codex's product proposal](#references).
- ❌ Approval-hook protocol for Codex / Gemini in v1.15. Claude has the
  `claude-pre-tool-use` hook + a `pending_approvals` table. Codex /
  Gemini don't have an equivalent we can integrate against in this
  cycle — they handle approvals inline in their TUI ("Run this command?
  [Y/n]"). v1.15 ships managed sessions for Codex/Gemini WITHOUT a
  remote-approve surface; users either run with `--yolo` /
  `--approval-mode=auto_edit` / `--full-auto` (provider-specific flag),
  or they walk over to the Mac to approve manually. Document this
  clearly in the spawn UI.
- ❌ Provider-specific CLI version detection / minimum-version gating.
  Spawn whatever PATH resolves; surface errors as session events.
- ❌ Other CLIs (Q chat, Cursor, Aider, GitHub Copilot CLI, JetBrains AI).
  Defer until we have user signal that any one of them needs it.

## Scope

**In v1.15:**

1. **Codex managed sessions** end-to-end (helper spawn + iOS spawn UI +
   formatter + tests).
2. **Gemini managed sessions** same shape.
3. **Helper architecture refactor** — `ProviderSpawner` protocol so each
   provider's argv / env / capability detection is one file each.
4. **Per-provider conversation formatters** — `CodexConversationPreviewFormatter`
   and `GeminiConversationPreviewFormatter` alongside the existing
   `ClaudeConversationPreviewFormatter`. Shared base (`AnsiSanitizer`,
   chrome classifier, polish helper).
5. **Provider picker** in the iOS / macOS "Start Session" flow.
6. **Real-fixture tests** per provider — capture actual Supabase
   `remote_session_events` payloads from sample sessions, drop into
   `Tests/Fixtures/RealTUITraces/` as test data.

**Backend changes (gated on user approval per autonomy contract):**

- Migration: extend `remote_sessions.provider` check to include `gemini`
  (the existing constraint already includes `claude` and `codex`; just
  add the third).
- Optional: same constraint on `remote_pending_approvals.provider`
  (currently only `'claude' | 'codex'`).

## Phase plan

### Phase 1 — Helper provider abstraction (~3-4 days)

**Goal:** the Python `RemoteAgentManager` no longer has Claude
hardcoded. Adding a new provider is one file + one config row.

Files:
- `helper/remote_agent.py`:
  - Replace `CLAUDE_ARGV = ["claude"]` and `_argv_for(provider)` with a
    `ProviderSpawner` protocol.
  - Each provider implements `argv() -> list[str]`, `env_overrides() -> dict[str, str]`,
    and (optionally) `is_available() -> bool` for pre-flight detection.
- `helper/provider_spawners/claude.py` (move existing logic).
- `helper/provider_spawners/codex.py` (NEW).
- `helper/provider_spawners/gemini.py` (NEW).

Protocol sketch:

```python
class ProviderSpawner(Protocol):
    name: str  # 'claude' | 'codex' | 'gemini'

    def argv(self, params: SessionStartParams) -> list[str]:
        """Argv for the interactive REPL spawn. Inherits PATH."""

    def env_overrides(self, params: SessionStartParams) -> dict[str, str]:
        """Provider-specific env (e.g. CLAUDE_HOME, model overrides)."""

    def is_available(self) -> bool:
        """Return True if the binary is on PATH and runnable."""

    def supports_remote_approval(self) -> bool:
        """Claude: True. Codex/Gemini: False (until they expose hooks)."""
```

Concrete spawners:

| Provider | argv | Notes |
|---|---|---|
| `claude` | `["claude"]` | unchanged |
| `codex` | `["codex"]` | argv accepts `[PROMPT]` to seed initial input |
| `gemini` | `["gemini"]` | optional `--yolo` flag from session params if user opted in |

Risk: Gemini's `--yolo` flag bypasses all approval prompts. Don't
default it on — make it an explicit per-spawn opt-in via the iOS UI.

Tests:
- `tests/helper/test_provider_spawners.py` — argv shape, env shape,
  is_available with stub PATH.
- Existing `RemoteAgentManager` tests parameterised across providers.

Backend:
- No SQL change yet (existing constraint allows codex; gemini comes
  in Phase 2).

### Phase 2 — Backend: enable Gemini provider (~0.5 day)

User-approval gated.

Migration `migrate_v0.45_gemini_provider.sql`:

```sql
alter table public.remote_sessions
  drop constraint remote_sessions_provider_check;
alter table public.remote_sessions
  add constraint remote_sessions_provider_check
  check (provider in ('claude', 'codex', 'gemini', 'shell'));
-- (mirror on remote_pending_approvals if we want approval surface
-- ready, even though Phase 1 says we don't ship it yet)
```

Apply via Supabase MCP.

### Phase 3 — Per-provider conversation formatters (~3-4 days)

**Goal:** the iOS / macOS Sessions panel shows readable conversation
output for each provider's TUI without leaking spinner / status / token
counter chrome.

Architecture:
- New `ConversationPreviewFormatter` (Swift protocol):
  ```swift
  public protocol ConversationPreviewFormatter {
      static var emptyFallback: String { get }
      static func format(eventPayloads: [String]) -> String
  }
  ```
- Existing `ClaudeConversationPreviewFormatter` conforms.
- New `CodexConversationPreviewFormatter` — handles Codex's `> ` user
  marker, `[user/assistant]` blocks, status panel.
- New `GeminiConversationPreviewFormatter` — handles Gemini's TUI shape.
- Shared utilities (already in repo): `AnsiSanitizer`,
  `TerminalOutputPreviewFormatter` (generic fallback for unknown
  providers).

Dispatch — call site in `iOSSessionsTab.swift` + `SessionsTab.swift`:

```swift
let formatter: any ConversationPreviewFormatter.Type = {
    switch session.provider.lowercased() {
    case "claude": return ClaudeConversationPreviewFormatter.self
    case "codex":  return CodexConversationPreviewFormatter.self
    case "gemini": return GeminiConversationPreviewFormatter.self
    default:       return TerminalOutputPreviewFormatter.self  // generic
    }
}()
let transcript = formatter.format(eventPayloads: stdoutPayloads)
```

Real-fixture tests — capture from production:
- Spawn one session per provider on dev Mac
- Pull events via Supabase MCP into JSON files under
  `CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/Fixtures/RealTUITraces/`
  - `claude_3_turn_path_wrap.json`
  - `codex_initial_prompt.json`
  - `codex_tool_approval_inline.json`
  - `gemini_initial_prompt.json`
  - `gemini_yolo_session.json`
- Each formatter test loads its fixture and asserts conversation lines
  surface, chrome drops.

Per-provider tuning (estimated effort):
- Codex (`codex` 0.128.0): TUI uses `▌` / `>` markers, has status
  bottom-bar with `[ESC] cancel · [Tab] cycle`. Likely 30-50 lines of
  formatter logic + test fixtures.
- Gemini (`gemini` 0.38.x): different TUI again. 30-50 lines.

### Phase 4 — App UI: provider picker (~2-3 days)

**Goal:** "Start Session" surface lets the user pick Claude / Codex /
Gemini before spawning.

Files:
- `CLI Pulse Bar iOS/iOSSessionsTab.swift`:
  - Replace the bare "Start a Claude session" button with a sheet that
    presents installed providers, each as a tappable tile (provider
    color + icon + "Start session").
  - Disable Codex / Gemini tiles when the helper reports the binary is
    not available (read from `helper_capabilities` or a new
    `provider_availability` field on `devices`).
- `CLI Pulse Bar/SessionsTab.swift`: same picker on macOS.
- `APIClient.remoteRequestSessionStart` — add a `provider` parameter
  (currently hardcoded to `"claude"`).
- iOS spawn sheet must mention "no remote approval for Codex/Gemini in
  v1.15 — run with `--yolo` (Gemini) or be at the Mac to approve" so the
  user is not surprised.

### Phase 5 — Helper capability advertisement (~1-2 days)

So the iOS picker can grey out unavailable providers without trying to
spawn first.

- Helper's `helper_sync` / `helper_heartbeat` posts a
  `provider_availability` map: `{"claude": true, "codex": true, "gemini": false}`
- `devices` table gains a `provider_availability jsonb` column (gate on
  user approval).
- iOS / macOS spawn picker reads this and disables tiles where
  `false`.

### Phase 6 — Tests + ship (~2 days)

- Real-fixture tests per provider (covered in Phase 3).
- E2E: spawn a Codex session from iOS Simulator on dev Mac, send `hello`
  prompt, verify output renders.
- xcodebuild macOS / iOS / Watch / Widgets schemes — all green.
- `swift test --parallel` — full suite green.
- CI guards (date-windows, RPC contract drift) — green.
- Release notes draft for v1.15.

## Rollout

- Phase 1 (helper refactor) ships internally first — backwards compatible
  (only `claude` actually exposed by app).
- Phase 2 migration applied via Supabase MCP after user approval.
- Phase 3 formatters wired in but Codex/Gemini tiles HIDDEN behind a
  feature flag (`enableMultiCLISessions` in user defaults) until Phase
  6 verification passes.
- Once Phase 6 green: feature flag flipped on for the v1.15 binary
  upload.

## Risk register

| Risk | Mitigation |
|---|---|
| Codex / Gemini TUI changes break formatter | Real-fixture tests + Show Raw fallback already shipped. Formatter only filters chrome aggressively; loss is degraded display, not session breakage. |
| `gemini --yolo` lets the model run anything without approval | Explicit confirmation in iOS spawn sheet. Default OFF. |
| Helper spawn fails because binary not on PATH | Pre-flight check in `is_available()`; surface as `info` event with remediation hint. |
| `remote_pending_approvals` schema doesn't cover non-Claude providers | Phase 5 ships without the approval surface for Codex/Gemini. Document explicitly in UI. |
| Codex CLI's interactive mode has different signal handling than Claude | Standard `0x03` Ctrl-C path through PTY (already shipped per `feedback_conpty_interrupt_pattern.md`) — should work cross-CLI. Verify in Phase 6 E2E. |
| Helper running on user's Mac doesn't have all 3 CLIs installed | Phase 5 capability map prevents iOS picker from offering missing providers. Helper logs a one-line "codex: not on PATH (skip)" at startup. |

## Out-of-scope (deferred to v1.16+)

1. **Codex / Gemini approval-hook integration.** Wait for upstream
   protocol or build our own inline-detector ("Run this command? [Y/n]"
   pattern in stdout → push to `remote_pending_approvals`). Significant
   scope; not blocking v1.15.
2. **Generic shell session.** `provider = 'shell'` is already in the
   SQL constraint but no spawner. Only add if a real user need surfaces.
3. **Cross-provider session resume.** Codex has `codex resume`; doesn't
   make sense in our managed-session model (each session is one PTY
   process owned by helper).
4. **`OpenCode` / `Q chat` / `Aider`.** No demand signal yet.

## Effort estimate

| Phase | Days |
|---|---|
| 1. Helper provider abstraction | 3-4 |
| 2. Backend gemini migration | 0.5 |
| 3. Per-provider formatters | 3-4 |
| 4. App UI provider picker | 2-3 |
| 5. Helper capability map | 1-2 |
| 6. Tests + ship | 2 |
| **Total** | **~12-15 days** |

Single-developer, including review iteration. Calendar time depends on
how many sessions hit Gemini reviews.

## Decisions to surface

(Default per the plan above; user can override.)

1. Approval surface — defer for Codex/Gemini in v1.15 (default).
2. Gemini `--yolo` opt-in — surfaced in iOS spawn sheet (default off).
3. Provider availability map — new column on `devices` (gate user
   approval).
4. Real-fixture test directory: `Tests/CLIPulseCoreTests/Fixtures/RealTUITraces/` —
   commit fixture files.
5. Feature flag during rollout: `enableMultiCLISessions` in app-group
   UserDefaults.

## References

- PR #41 (v1.14 lifetime IAP + dashboard parity + session formatter
  hardening): https://github.com/cli-pulse/cli-pulse-private/pull/41
- `feedback_remote_session_scroll_bug.md` — live-tail scroll trigger
  fix
- Codex's product proposal (received 2026-05-08) — three-layer output
  model. Plan honors all "agree" points; defers terminal viewer
  permanently per its own recommendation.
- `feedback_gemini_review_patterns.md` — apply review-pattern checklist
  before each migration.
