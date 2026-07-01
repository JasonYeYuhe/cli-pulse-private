# PROJECT FIX — Python helper Codex on-plan parity (CODEX_HOME pin + OPENAI_API_KEY scrub + provider_plan_status)

**Date:** 2026-07-01 · **Found by:** first-principles verification of the v1.35 managed-Codex ship (the Swift↔Python spawner parity invariant).

## Problem
The v1.35 managed-Codex "on-plan" hardening (#264 / #268) landed in the **Swift**
helper only. The **Python** helper (`helper/provider_spawners/codex.py` + the UDS
`hello` reply) lacked all three pieces:

1. **`CODEX_HOME` pin** — Swift pins `CODEX_HOME=<home>/.codex` so codex reads the
   on-plan `auth.json` even when launchd hands the daemon a drifted `HOME`.
2. **`OPENAI_API_KEY` scrub** — Swift DELETES an inherited `OPENAI_API_KEY` (only
   when a verified ChatGPT login exists) so a managed Codex session can't silently
   fall back to the **billed** pay-per-token API.
3. **`provider_plan_status`** in `hello` — so the spawn picker can warn
   "OpenAI API (billed)" before launching an off-plan session.

This is **reachable, not theoretical**: `local_session_server.py` `start_session`
accepts `codex`, routing to `RemoteAgentManager.spawn_session`; and the `.pkg`
Python helper (published 1.20.0, `RunAtLoad=true`) **shadows the shared socket**
for the upgrade cohort (see `feedback_helper_socket_shadowing`). Those users'
managed Codex ran without the scrub or the picker warning.

Separately, the Python spawn path **never applied `env_overrides()` at all** — the
method existed and was unit-tested in isolation, but nothing merged its result into
the spawn env (so even the pre-existing `RUST_BACKTRACE=1` was dead in production).

## Fix (Swift↔Python parity, no behavior change on Swift side)
- **`provider_spawners/base.py`**: new `resolved_user_home()` (getpwuid, not `$HOME`;
  `None` for root / bad pw_dir — mirrors Swift `HelperEnvironment.resolvedUserHome`);
  new `BaseSpawner.env_removals()` → `set()` and `plan_auth_status()` → `"unknown"`.
- **`provider_spawners/codex.py`**: `env_overrides` pins `CODEX_HOME` when a home
  resolves; `env_removals` returns `{"OPENAI_API_KEY"}` only when a home resolves AND
  `has_verified_chatgpt_auth()` (reads `~/.codex/auth.json`, requires
  `auth_mode=="chatgpt"` + a non-empty access/refresh token — same shape
  `system_collector._fetch_codex_usage` reads); `plan_auth_status` →
  on_plan / off_plan / unknown. Guard mirrors Swift exactly: **unresolvable home ⇒
  no pin AND no scrub.**
- **`provider_spawners/gemini.py`**: `plan_auth_status` → `on_plan` when `agy`
  resolvable, else `unknown` (never `off_plan`).
- **`provider_spawners/__init__.py`**: Protocol gains `env_removals` +
  `plan_auth_status`; new `provider_plan_statuses()` (available providers, omits
  `unknown` — mirrors Swift `ProviderSpawnerRegistry.planAuthStatuses`).
- **`remote_agent.py` `spawn_session`**: NOW applies `spawner.env_overrides()`
  (fixing the pre-existing dead-code gap) and forwards
  `env_remove=spawner.env_removals()` to the transport. Fail-soft (a throwing
  override/removal never breaks a spawn).
- **transports** (`base`/`posix_pty`/`codex_exec`/`multiplex`/`conpty`): new
  keyword-only `env_remove: frozenset[str]` on `start()`; keys are `pop`'d AFTER the
  `os.environ` merge — the only place a var living in the parent env can be removed
  (an overlay dict can only add). `codex_exec` is the transport that actually spawns a
  managed Codex session, so that's where the scrub fires. Mirrors Swift
  `PtyTransport(envRemove:)`.
- **`local_session_server.py`**: `hello` now emits `provider_plan_status`
  (fail-soft, omits `unknown`). The macOS app already parses this
  (`LocalSessionControlClient.swift:440`, surfaced in `SessionsTab.swift:250`), so
  the fix is end-to-end for Python-helper-shadowed hosts.

## Verification
- `pytest -q` (from `helper/`): **663 passed, 1 skipped** (was 663/1 before; +14 new
  tests: Codex CODEX_HOME/scrub/plan-status, `has_verified_chatgpt_auth` matrix,
  Gemini plan-status, `provider_plan_statuses` omit-unknown, spawn-path forwarding,
  multiplex env_remove→both transports, hello `provider_plan_status`).
- `ruff check .`: clean. `py_compile` of all 11 changed source files: OK.
- Real `~/.codex/auth.json` on this Mac verified to carry `auth_mode:"chatgpt"` + a
  live `access_token`, so the mirrored check actually fires (scrub engages).

## Owner-gated follow-up (NOT done here)
Reaching **installed** `.pkg` users needs a **helper `.pkg` republish** (bump
`HELPER_VERSION`, build + sign with `DEV_ID_INSTALLER`, notarize, publish to
`cli-pulse-helper-releases`). New DEVID installs already bundle the Swift helper
(which has these features). See `feedback_helper_socket_shadowing`,
`feedback_v116_helper_pkg_shipped`.
