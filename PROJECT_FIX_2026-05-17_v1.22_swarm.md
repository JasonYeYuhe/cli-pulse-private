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
| [`75ef646`](https://github.com/JasonYeYuhe/cli-pulse-private/commit/75ef646) | H-F1 | 10 | helper-only; no schema; 537 pytest green |
| [`2cd824f`](https://github.com/JasonYeYuhe/cli-pulse-private/commit/2cd824f) | S1 + S1b | 6 | helper-only; no schema; **dark by default**; 558 pytest green |
| _(this commit)_ | S2 (file only) | 2 | migration **authored, NOT applied** — CI-green; prod apply is user-gated |

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

---

## S1 — swarm_key tagging (helper, no schema)

**Key architectural finding** (from the codebase explore, sharpening
Gemini R1-A1/R2-3): the helper has **two** ingestion paths and only one
knows the worktree. Remote-spawned managed sessions
(`remote_agent._handle_start`) run at `$HOME` with `cwd=""` by an
explicit privacy-posture decision — they genuinely cannot yield a
repo/branch and correctly get **no** swarm tag. The **hook path**
(`remote_hook._run_hook_inner`, `cwd = raw["cwd"]`) is the only place
the agent's real worktree is known. So swarm_key derivation lives on
the hook path, not the spawn path. Documented here because it both
confirms and concretizes the review's "cwd is fragile" thesis.

**New** [`helper/swarm.py`](helper/swarm.py):
* `resolve_worktree(cwd)` — one `git rev-parse --git-common-dir
  --abbrev-ref HEAD --is-inside-work-tree` round-trip. Uses the shared
  `.git` **common-dir parent** as the canonical `main_repo` so every
  linked worktree of one repo groups into ONE swarm (R1-A1 monorepo/
  sibling fix); `branch` is the per-agent axis. Detached HEAD →
  `(detached)`. Non-git / missing / timeout / git-absent → `None`
  (RK1: never raises, event just goes untagged).
* `compute_swarm_key(main_repo, branch, account_secret)` — domain-
  separated, NUL-joined `HMAC-SHA256`. Secret is the **account-scoped**
  `config.helper_secret` (identical across the user's devices →
  cross-device grouping works, R2-1). Empty secret → `""` (fail-soft).
* `display_handle(key)` = `swarm-<6 hex>` — the v1.22.0 cross-device
  label: leaks nothing (RK7); the local Mac resolves the real name
  from its own cache.
* `encrypt_label`/`decrypt_label` — stdlib-only (no `cryptography`
  dep — feedback_v116) authenticated account-envelope, **implemented +
  unit-tested but NOT wired into any 1.22.0 upload**. This is exactly
  the plan's documented R2-1 fallback: v1.22.0 ships opaque-handle
  only; v1.22.1 flips on encrypted real-name sync with the crypto
  already reviewed.
* `SwarmStore` — bounded (`64` swarms × `32` sessions), 0600,
  atomic tmp+rename JSON at `~/.cli_pulse/swarm_state.json`; TTL-prunes
  at 600s. `record_activity` (S1 writes per hook) + `rollup` (S1b
  reads). Every method failure-soft — a corrupt/locked state file can
  never break the approval hook (RK1).

**Hook wiring** ([remote_hook.py](helper/remote_hook.py)
`_run_hook_inner`): after `cwd` is known, a single guarded block
records `awaiting-approval` at hook ingress (the agent just hit a
permission gate = the swarm view's primary "needs attention" signal)
and `running` at the two decision-resolved sites (local UDS + remote).
The shipped `remote_helper_create_permission_request` RPC signature is
**deliberately untouched** — swarm data rides only the S1b heartbeat,
de-risking the approval path and decoupling from the S2 schema gate.

**Honest scope note**: the hook fires only on permission-gated tool
calls, so a fully auto-approved agent that never hooks won't appear in
the swarm until it next gates. tokens/min is NOT sourced here (the hook
has no token telemetry — that's the separate `daily_usage_metrics`
pipeline, joined backend-side in S2). This is the truthful v1.22.0
signal set; broader liveness is a known follow-up, not silently
implied.

---

## S1b — swarm_heartbeat (helper, no schema, edge aggregation)

* New module fn `_swarm_heartbeat(config)` in
  [cli_pulse_helper.py](helper/cli_pulse_helper.py): reads
  `SwarmStore().rollup()` and POSTs ONE
  `remote_helper_swarm_heartbeat` RPC with the per-swarm summary —
  **edge aggregation, not the raw event stream** (R1-A4). Empty rollup
  ⇒ no POST (backend TTL ages the last row). Wholly failure-soft: a
  missing RPC (S2 not yet deployed), network error, or unreadable
  state all log + return, never disturbing the daemon (RK1).
* Wired into the daemon's 1s tick loop on a **monotonic ~30s timer**,
  decoupled from `interval` (≥60s) so the backend's planned 90s TTL
  stays a 3× anti-flap margin over the beat (RK8).
* New `HelperConfig.swarm_enabled` (default **False**). Single master
  gate for *both* S1 hook tagging and the S1b heartbeat — the whole
  feature is dark (no local writes, no upload, no log noise) until S2
  is deployed and a coordinated release flips it. Backward-compatible
  (existing configs load opted-out; `load_config` strips unknowns).

**Tests**: `test_swarm.py` (16) + `test_swarm_heartbeat.py` (5),
including real-git-repo linked-worktree grouping, detached HEAD,
account-secret cross-device determinism, label crypto tamper/wrong-key
rejection, store TTL/bounds/corrupt-file soft-fail, gate-off-no-upload,
and RK1 RPC-missing-doesn't-raise. Full helper suite **558 passed, 1
skipped** (was 537) — zero regressions; existing 64 hook tests
unaffected by the wiring.

**Schema/account/public-surface**: none yet. The
`remote_helper_swarm_heartbeat` RPC + its storage is **S2**, which is a
backend-schema change → **user-approval gate per the autonomy contract
(RK4)**. Helper ships dark; S2 is the next step and is presented to the
user before any `apply`.

---

## S2 — backend migration (AUTHORED, NOT APPLIED — autonomy gate)

CI surfaced the ordering precisely: the **RPC contract drift guard**
(`backend/supabase/ci_check_rpc_contract.py`) failed the S1+S1b push
because the helper calls `remote_helper_swarm_heartbeat` with no SQL
definition. This cleanly delineates the autonomy boundary: **authoring
the migration file is a repo change (autonomous); APPLYING it to prod
Supabase is the gated action** (handoff: "schema 改动要先告知用户再
apply (apply 本身可自主)"; PLAN RK4).

**Authored**: [`backend/supabase/migrate_v0.48_remote_swarms.sql`](backend/supabase/migrate_v0.48_remote_swarms.sql)
— convention-perfect against the v0.26/v0.27/v0.47 precedents:
* `remote_swarms` table — latest-wins one row per `(user_id,
  device_id)`, modelled on `provider_quotas` + the `remote_*` device
  FK; RLS select/delete-own, no insert/update policy (RPC-only writes).
* `remote_helper_swarm_heartbeat(p_device_id, p_helper_secret,
  p_swarms jsonb)` — `_remote_authenticate_helper_gated` (same posture
  as `remote_helper_post_event`), `SECURITY DEFINER`, `RETURNS jsonb`
  (no `RETURNS TABLE` → no DROP, grants preserved — gemini-patterns
  #1), defensive 64-elem + 32 KB caps, UPSERT.
* `remote_app_list_swarms()` — `auth.uid()` +
  `_remote_control_enabled_for_caller()` JWT gate; returns each device
  blob annotated with `stale` (past the **90s** live-TTL = 3× the 30s
  S1b beat, RK8) instead of dropping it (R2-2 "last-seen, not
  vanished"); `revoke public,anon` + `grant authenticated`.
* `_cleanup_remote_swarms_internal()` + idempotent pg_cron
  `remote_swarms_cleanup_nightly` at `7 4 * * *` (next free slot after
  v0.28's 03:47, v0.28/v0.47 guard shape), fully revoked.

**Verified locally**: RPC contract guard now `OK`; helper param names
(`p_device_id/p_helper_secret/p_swarms`) match the SQL signature.

**NOT done (the gate)**: `apply_migration` / `execute_sql` against prod
Supabase, and the schema_migrations ledger entry — **awaiting explicit
user approval to apply**. Until applied, the shipped helper stays dark
(`swarm_enabled=False`) so nothing calls the absent prod RPC.
