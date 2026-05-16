# PROJECT_FIX 2026-05-17 — v1.22.0 "Mission Control for the agent swarm" (P0)

**Scope**: v1.22.0 launch train = P0 Swarm View (S1–S6) + H-F1, per the
user-signed-off scope lock in [`PLAN_v1.22_2026-05-16.md`](PLAN_v1.22_2026-05-16.md).
P1 Cost Intelligence (v1.22.1) and P2 Team Rollup (v1.23.0) are NOT in
this train.

**Plan reference**: [`PLAN_v1.22_2026-05-16.md`](PLAN_v1.22_2026-05-16.md)
§2–§4 + §7/§8 (Gemini 2-round dispositions) + scope-lock header.
**Handoff reference**: `CLAUDE_HANDOFF_v1.22_swarm_observability_2026-05-16.txt`.
**Review gate**: Gemini R1 GO-WITH-CHANGES + R2 GO-WITH-MINOR-CHANGES,
all 11 findings adopted; user scope sign-off 2026-05-16 (commit
[`1d57fb4`](https://github.com/JasonYeYuhe/cli-pulse-private/commit/1d57fb4)).

**Commits this archive covers** (all on `main`):

| Commit | Work item | Files | Notes |
|---|---|---|---|
| [`1d57fb4`](https://github.com/JasonYeYuhe/cli-pulse-private/commit/1d57fb4) | review+sign-off | 2 | PLAN dispositioned, scope locked |
| _(this commit)_ | H-F1 | 9 | helper-only; no schema; 537 pytest green |

---

## H-F1 — provider-spawner refactor + Aider/OpenCode/Cursor (helper)

**Why in v1.22.0**: user Q5 sign-off (2026-05-16) — the "Mission
Control" story fails if Swarm View can't see the newer CLIs devs run in
worktrees. Also the structural prerequisite: S1's worktree tagging must
be provider-agnostic from the start.

**Finding**: the three concrete spawners (`claude.py`, `codex.py`,
`gemini.py`) each re-implemented the *identical* argv0-override
tokenization + `is_available()` PATH/override probe verbatim
(`claude.py:42-54`, `codex.py:47-56`, `gemini.py:67-76` pre-refactor) —
three copies of security-relevant resolution logic, and the CLI count
is still growing.

**Fix**:
* New [`provider_spawners/base.py`](helper/provider_spawners/base.py) —
  `BaseSpawner` centralizes `_argv0_tokens()`, `argv()`,
  `env_overrides()` (`{}` default), `is_available()`,
  `supports_remote_approval()` (`False` default). Behaviour preserved
  bit-for-bit; the v1.15 spawner tests pin every observable.
* `claude.py` / `codex.py` / `gemini.py` slimmed to ~15-line
  `BaseSpawner` subclasses (Claude overrides `supports_remote_approval
  → True`; Codex overrides `env_overrides → {RUST_BACKTRACE: 1}`;
  Gemini overrides `argv` to append `--yolo`, now via `super().argv()`
  so the override-compounding test still holds). Provider context
  docstrings retained.
* New spawners: [`aider.py`](helper/provider_spawners/aider.py),
  [`opencode.py`](helper/provider_spawners/opencode.py),
  [`cursor.py`](helper/provider_spawners/cursor.py) (binary
  `cursor-agent`, registry name `cursor`). All observability-only —
  `supports_remote_approval` stays `False` (no Claude-style hook
  protocol upstream); v1.22 value is worktree-tagged heartbeat rollup,
  not remote approve.
* `__init__.py`: registry now 6 providers; `__all__` + module docstring
  updated to the "subclass BaseSpawner, ~10-line change" pattern.

**Tests** ([test_provider_spawners.py](helper/test_provider_spawners.py)):
18 → 25. New: registry-is-6, get_spawner for the 3 new, **every
spawner inherits BaseSpawner** (the de-dup invariant pin), per-new-CLI
argv/name/approval, and "new provider gets the shared override path for
free". Full helper suite: **537 passed, 1 skipped** — zero regressions.

**Schema/account/public-surface**: none. Pure helper code; autonomy
contract not engaged.
