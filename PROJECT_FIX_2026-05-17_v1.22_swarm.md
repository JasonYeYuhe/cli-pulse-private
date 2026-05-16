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
| [`b9f3686`](https://github.com/JasonYeYuhe/cli-pulse-private/commit/b9f3686) | S2 (file) | 2 | migration authored; CI-green |
| _(prod action)_ | S2 **APPLIED** | — | user-approved 2026-05-16; `apply_migration` → prod Supabase; ledger `v0_48_remote_swarms`; advisor-clean |
| _(this commit)_ | S3 | 13 | Mac Swarm tab; Bar app BUILD SUCCEEDED; 21 swift tests green; no schema |

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

**APPLIED to prod 2026-05-16** (user-approved via AskUserQuestion).
`apply_migration` name `v0_48_remote_swarms` → Supabase `gkjwsxotmwrgqsvfijzs`
(Tokyo, PG17). Verified: table + 3 functions present, RLS on + 2
policies, cron `remote_swarms_cleanup_nightly @ 7 4 * * *`,
`supabase_migrations.schema_migrations` latest = `v0_48_remote_swarms`
(MCP `apply_migration` auto-records the ledger — no manual insert
needed since there's no CONCURRENTLY).

**Advisor review** (security, post-DDL): the only findings touching the
new objects are WARN lints 0026/0027 (table visible in GraphQL — but
RLS-protected, same as every `remote_*` table) and 0028/0029
(SECURITY DEFINER callable by anon/authenticated — *intentional*: the
helper authenticates via anon-key + device-secret inside
`_remote_authenticate_helper_gated`; the app RPC is JWT-gated +
already `revoke public,anon`+`grant authenticated`). These fire
identically for the entire pre-existing `remote_*` family by deliberate
design (v0.31 `remote_advisor_followups` posture). **No new/unexpected
findings; no remediation — "fixing" 0028 would break the helper.**

Helper remains dark (`swarm_enabled=False`) — the RPC now exists in
prod but nothing calls it until a later coordinated enable. Production
behavior unchanged.

---

## S3 — Mac Swarm tab (helper-read app, no schema)

New `case .swarm` in `AppState.Tab` (auto-propagates to the tab bar
`ForEach`; both `MenuBarView` `switch state.selectedTab` sites updated)
+ icon `square.grid.3x3.fill` + `L10n.tab.swarm`.

* **Models** ([Models.swift](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/Models.swift)):
  `RemoteSwarmDevice` + `RemoteSwarm`, verbatim snake_case (the
  project's `JSONDecoder()` has no keyDecodingStrategy), `Identifiable`
  + memberwise `init` — matches the v0.48 RPC shape exactly.
* **API** ([APIClient.swift](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/APIClient.swift)):
  `remoteListSwarms()` → `remote_app_list_swarms` (mirrors
  `remoteListSessions`; JWT-gated, RC-gated server-side).
* **State** ([AppState.swift](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift)
  + [DataRefreshManager.swift](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift)):
  `remoteSwarms` / `…LastRefresh` / `…Error`; `refreshRemoteSwarms()`
  with the exact `refreshRemoteSessions` discipline (no-op + clear when
  RC off, post-await re-check — Gemini P2 #8); optimistic clear on the
  RC-off path.
* **View** [SwarmTab.swift](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/SwarmTab.swift):
  `LazyVGrid` 2-col, **attention-sort** (stale ↓, then blocked ↓, then
  agents ↓, then handle); per-card blocked badge + oldest-blocked age +
  provider chips + worktree icon; **stale devices render greyed with
  "last seen Xm", not dropped** (R2-2); structured-concurrency 10s
  poll (NOT `Timer.publish` — feedback_swiftui_timer_lifecycle);
  disabled/empty/error states. **ZERO `$` anywhere** — headline is
  agents/blocked (R2-5, user-confirmed); `handle` is the opaque
  `swarm-6hex` (RK7). Card decomposed into typed sub-builders after
  hitting the SwiftUI "expression too complex to type-check" wall.
* **Shared** [SwarmFormatters.swift](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/SwarmFormatters.swift):
  `SwarmFormat.humanizeAge` in CLIPulseCore so S4 iOS/Live-Activity +
  S5 watch reuse it (and it's unit-testable).
* **L10n**: `L10n.swarm` enum + `swarm.*` / `tab.swarm` keys in all 5
  `.lproj`. en + zh-Hans (user's native locale) properly written;
  ja/ko/es seeded with English baseline — same posture the v1.21 D7
  consent strings already use; full translation is the plan's explicit
  D7 carried-over follow-up (NOT P0-blocking).
* **Project**: `SwarmTab.swift` wired into `project.pbxproj` (4
  entries, fresh `A10072/B10072` IDs mirroring `SessionsTab`).
* **Tests** [RemoteSwarmTests.swift](CLI%20Pulse%20Bar/CLIPulseCore/Tests/CLIPulseCoreTests/RemoteSwarmTests.swift):
  decode shape, empty array, stale device, `humanizeAge` edges.

**Verified**: `swift build` CLIPulseCore clean; `xcodebuild -scheme
"CLI Pulse Bar"` **BUILD SUCCEEDED**; targeted `swift test` **21
passed / 0 failures** (swarm + model + tab/L10n-adjacent). Full-suite
run is pre-existing network-flaky (ClaudeSourceResolver 401) and
unrelated; the ship-gate runs the comprehensive matrix.

**Schema/account/public-surface**: none (read-only consumer of the
already-applied v0.48 RPC).

---

## S4 — iOS Swarm grid + Live Activity scaffolding (no schema)

**iOS Swarm grid** [iOSSwarmTab.swift](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar%20iOS/iOSSwarmTab.swift):
NavigationStack + `LazyVGrid`, the exact macOS S3 contract (shared
models/API/`refreshRemoteSwarms`/`SwarmFormat`/`L10n.swarm`,
attention-sort, stale-greyed-not-dropped R2-2, **zero `$`** R2-5,
opaque handle RK7, decomposed sub-builders, structured-concurrency
poll). Adds an inline **Approve-oldest** button that reuses the
shipped `decideRemoteApproval` on the globally-oldest
`remotePendingApprovals` row (honest proxy: the opaque rollup carries
no request_id by design, so we act on the oldest real pending request
= in practice the oldest-blocked agent — documented, not hidden).
Wired into all 3 iOS nav sites: iPhone `TabView`, iPad `detailView`
switch (**this closes the iOS CI `switch must be exhaustive` failure
the S3 commit transiently introduced** — expected S3→S4 sequencing,
fixed proactively per feedback_github_ci_emails), iPad sidebar.

**Live Activity / Dynamic Island** — 100% greenfield (zero prior
ActivityKit anywhere). Scoped conservatively:
* [SwarmActivityAttributes.swift](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/SwarmActivityAttributes.swift)
  in CLIPulseCore (the only module both app + widget-ext import),
  `#if os(iOS) && canImport(ActivityKit)`-guarded so the macOS/watch
  CLIPulseCore builds stay green (verified: `swift build` clean).
* [SwarmLiveActivity.swift](CLI%20Pulse%20Bar/CLI%20Pulse%20Widgets/SwarmLiveActivity.swift)
  widget-extension `ActivityConfiguration` — lock screen + full
  Dynamic Island (compact/minimal/expanded). Shows `{swarms · agents ·
  blocked}` + a native `Text(timerInterval:)` age — the ONLY no-push-
  safe dynamic element (R2-4). **No `$`.** `widgetURL(clipulse://swarm)`
  deep-link.
* [SwarmLiveActivityController.swift](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar%20iOS/SwarmLiveActivityController.swift)
  app-side lifecycle: starts when ≥1 agent blocked, updates
  content-state from the polled `remoteSwarms` each tick, ends when
  unblocked / RC off. **Local-state-driven, `pushType: nil`.** Fully
  best-effort (ActivityKit errors swallowed — never disturbs the grid).
* `NSSupportsLiveActivities=true` added to the iOS app Info.plist (the
  only plist/entitlement change — Explore confirmed **MAS-strip is
  macOS-only; iOS embeds no helper**, so RK2's MAS risk does NOT apply
  to this iOS capability change).
* pbxproj: `iOSSwarmTab`/`SwarmLiveActivityController` → iOS target
  (A20025/26, B20025/26); `SwarmLiveActivity` → Widgets target
  (A40030/B40030); `SwarmActivityAttributes` auto-included (SwiftPM).

**Named follow-up gate (NOT done — by design)**: APNs-push-driven
Live Activity updates (background continuation) need a distinct
Live-Activity push-token type + a new edge function + server token
storage + **a physical Dynamic-Island device to obtain/verify the
token** — exactly the "Live Activity real-device" gate the handoff
flags. v1.22.0 ships the LA structurally (renders correctly from local
state while the app is active); the push path is the documented
v1.22.x follow-up. This is the honest cut, not a silent omission.

**Schema/account/public-surface**: none. The `NSSupportsLiveActivities`
capability is reflected at ASC submit time (a ship-gate concern, not a
code gate).
