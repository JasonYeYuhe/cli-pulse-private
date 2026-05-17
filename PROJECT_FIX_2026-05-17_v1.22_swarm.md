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
  `.lproj`. en + zh-Hans written at S3 time; ja/ko/es were seeded with
  English baseline then **fully translated 2026-05-17 (D7 closed)** —
  see the D7 completion section below. (NOTE: an earlier checkpoint
  line claimed "es done" — that was inaccurate; es was English-baseline
  until the D7 pass. Verified against the actual `.lproj` files.)
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

---

## v1.22.0 status @ checkpoint (2026-05-17)

**Done, on `main`, CI-tracked, build-verified:**

| Item | Plat | State |
|---|---|---|
| Gemini 2-round review + dispositions + user scope sign-off | — | ✅ `1d57fb4` |
| H-F1 BaseSpawner refactor + Aider/OpenCode/Cursor | helper | ✅ `75ef646` (558 pytest) |
| S1 swarm_key tagging + S1b heartbeat (dark) | helper | ✅ `2cd824f` (558 pytest) |
| S2 `remote_swarms` migration | backend | ✅ `b9f3686` + **APPLIED to prod** (advisor-clean) |
| S3 Mac Swarm tab | macOS | ✅ `acef706` (Bar BUILD SUCCEEDED) |
| S4 iOS Swarm grid + Live Activity scaffolding | iOS | ✅ `df95bb4` (iOS BUILD SUCCEEDED) |

End-to-end the marquee feature is live on the **two primary platforms**:
helper edge-aggregates → prod `remote_swarms` RPC → Mac grid + iOS grid
+ Dynamic Island, all behind the dark `swarm_enabled` flag so prod
behavior is unchanged until a coordinated enable.

**Remaining for the v1.22.0 train (each gated as noted):**

- **S5** watch complication + Android Glance `{n · m blocked}` — native,
  no gate; Android via Android-Studio JBR per handoff §5.
- **S6** swarm alerts (blocked-age / burn) via `webhook_jobs` + >60s
  hysteresis — **backend-schema → autonomy gate** (inform user before
  apply, same as S2/RK4).
- **Live Activity APNs push path** — **real-device gate** (handoff):
  needs LA push-token type + edge function + server token store +
  physical Dynamic-Island device. Structurally shipped; push is the
  documented follow-up.
- **Coordinated enable** of `HelperConfig.swarm_enabled` — flip only
  after the helper .pkg ships with S1/S1b and S2 is confirmed live
  (S2 is live now; the helper .pkg ship is part of the train).
- **5-channel ship**: version 1.21.0→1.22.0, build 62→64, Android
  versionCode 30→31; helper .pkg republish; **VM smoke before any
  DEVID latest.json promote** (feedback_v080); **ASC/Play account ops**
  (incl. the new `NSSupportsLiveActivities` capability surfacing at
  submit) — account-gated.
- Carried-over D7 i18n: full ja/ko/es/zh-Hant translation of the
  `swarm.*` strings (currently English baseline in ja/ko/es).

---

## S5 — watch complication + Android Glance (no schema)

**S5a watch** (no new files → no pbxproj): extended the existing
widget-data channel rather than inventing a parallel one.
* `WidgetData` (`WidgetDataProvider.swift`) +`swarmAgents`/`swarmBlocked`
  as **optional** (`Int?`) so an OLD persisted App-Group blob still
  decodes (synthesized `decodeIfPresent`); `empty`/`preview` updated.
* `publishWidgetData()` (DataRefreshManager) computes totals across
  non-stale `remoteSwarms` and writes them; the local mirror struct
  got the matching keys.
* `WatchComplicationView.rectangularView` gained an at-a-glance
  `{n agents · m blocked}` row (blocked tinted orange — the
  needs-attention signal). NO `$` (R2-5). Honest freshness note in
  code: `remoteSwarms` is RC/tab-gated so the complication shows
  last-known — same model as every other published widget metric.
* Verified: Watch scheme `xcodebuild` **BUILD SUCCEEDED**.

**S5b Android Glance** (greenfield — app's first Glance widget):
* `libs.versions.toml` + `app/build.gradle.kts`: add
  `androidx.glance:glance-appwidget 1.1.1`.
* `data/model/RemoteSwarm.kt` — `RemoteSwarm`/`RemoteSwarmDevice` (org.json
  hand-parse posture, no Moshi — matches `DeviceRecord`).
* `SupabaseClient`: `remoteListSwarms()` → delegates to a pure
  top-level `parseRemoteSwarms(JSONArray)` (extracted for testability,
  mirrors the `OAuthCallbackParser` posture); nested `swarms`/`providers`
  parsed like `providers()` parses `tiers`.
* `DashboardRepository`: ephemeral `_swarms` StateFlow + `refreshSwarms()`
  (no Room cache — real-time only).
* `widget/SwarmGlanceWidget.kt` — `GlanceAppWidget` + Hilt `@EntryPoint`
  (Glance can't `@Inject`) + `SwarmGlanceReceiver`; minimal stacked-text
  `{n agents · m blocked}`, NO `$`. `res/xml/swarm_glance_widget_info.xml`
  + manifest `<receiver>` + `swarm_widget_description` string.
* Test `RemoteSwarmParseTest.kt` (parallels iOS `RemoteSwarmTests`):
  nested shape, empty array, missing-optional tolerance.
* Verified: `./gradlew :app:testDebugUnitTest :app:assembleDebug`
  (Studio JBR per handoff §5) **BUILD SUCCESSFUL** 2m23s — Glance API
  + manifest/XML/resources link, parse test passes.

**Schema/account/public-surface**: none (read-only consumer of the
already-applied v0.48 RPC).

---

## S6 — swarm-alerts migration (APPLIED to prod 2026-05-17)

`backend/supabase/migrate_v0.49_swarm_alerts.sql` was Gemini-3.1-Pro
re-reviewed and **APPLIED to prod** (project `gkjwsxotmwrgqsvfijzs`,
ledger `20260517071103:v0_49_swarm_alerts`) on explicit user approval
2026-05-17 (remote/handoff session — backend-schema autonomy gate
satisfied by direct user authorization, same flow as S2).

**Design** (convention-perfect vs v0.25/v0.48; full rationale in the
migration header):
* `_evaluate_swarm_alerts_internal()` — cron-driven async evaluator
  (NOT a read path — plan R1-A5). Scans `remote_swarms` where
  `updated_at > now()-90s` (RK8: never alert on a ghost), unrolls the
  `swarms` jsonb, fires when `blocked > 0 AND oldest_blocked_age_s >
  300` (5 min).
* **>60s hysteresis**: insert only if no *unresolved* alert for the
  `suppression_key` AND none created in the last 60s — the anti-flap
  window. No prior server-side hysteresis precedent existed; this is
  the new pattern (existing alerts are pure date/week suppression
  gates).
* Reuses the **entire existing webhook pipeline** (v0.25): the
  `alerts_enqueue_webhook` AFTER-INSERT trigger → `webhook_jobs` →
  existing 30s `process_webhook_jobs` cron → `send-webhook`
  Slack/Discord edge fn. **Zero new webhook infra.**
* New `swarm_alert_eval` pg_cron @ `'* * * * *'` (every minute, no slot
  collision); idempotent v0.48-shape unschedule+schedule; internal fn
  fully revoked; `RETURNS void` (no DROP); no CONCURRENTLY.
* Privacy (RK7): alert text uses only the opaque `handle` —
  never a repo/branch.

**Gemini 3.1 Pro re-review (2026-05-17, before apply) — R1 NO-GO → R2
GO, all findings dispositioned:**
* **R1 BLOCKER (adopted, real bug)**: bare `(elem->>'k')::int/::numeric`
  on a present-but-non-numeric helper value raises `22P02` and aborts
  the *entire* cron txn → swarm alerting silently dead for **every**
  user until the bad payload ages out. `coalesce()` only guards SQL
  NULL, not a bad scalar. Fixed: cast only when `jsonb_typeof(...) =
  'number'` (else 0, fail-closed), numeric-clamp before `::int`
  (`blocked` 0–100000, `age` 0–2592000) so a bug value can't overflow
  `round(age/60)::int` → `22003` (same txn-abort class).
* **R1 MINOR index (adopted)**: the evaluator filters `remote_swarms`
  by `updated_at` with no `user_id`, so v0.48's `(user_id,updated_at)`
  index can't serve it. Added `idx_remote_swarms_updated_at` (plain,
  not CONCURRENTLY — table empty at apply, instant/lock-free).
* **R1 MINOR `'1 minute'` cron syntax (Gemini right; I was wrong)**: I
  initially dismissed this citing the live `[30 seconds]` jobs — flawed
  reasoning (those prove the *seconds*-interval form, which does NOT
  generalize). The first `apply_migration` then failed exactly here:
  `ERROR 22023: invalid schedule: 1 minute` (this pg_cron accepts only
  5-field cron or `'[1-59] seconds'`). Apply rolled back **fully &
  atomically** (verified: ledger/fn/index/cron all absent post-fail).
  Fixed to `'* * * * *'`; re-applied clean. Lesson logged to memory.
* **R2 MINOR `is_resolved` (adopted, behaviour-neutral)**: INSERT now
  writes `is_resolved=false` explicitly. The column is already `NOT
  NULL DEFAULT false` (verified live) so behaviour is unchanged — this
  just makes the hysteresis `is_resolved=false` self-evidently correct
  and immune to a future default change.
* **R2 NIT (NOT adopted, with reason)**: wrapping the
  `cron.unschedule` `exception when others then null` in a pg_cron
  existence check — declined to keep byte-identical parity with the
  established house idempotency pattern (v0.28/v0.47/v0.48 all use it;
  v0.48 `remote_swarms_cleanup_nightly` is the exact precedent).

**Post-apply verification (live, prod):** ledger tail =
`v0_49_swarm_alerts`; fn exists, `proacl = postgres,service_role` only
(REVOKE confirmed — no anon/authenticated/PUBLIC); index present; cron
`swarm_alert_eval [* * * * *] active=true`; manual `_evaluate_swarm_
alerts_internal()` run = `ok-noop` (0 alerts, clean against 0 rows);
`remote_swarms` still 0 rows ⇒ **zero production behaviour change** (the
1-min cron is a no-op until helpers heartbeat & `swarm_enabled` flips).
Advisors: **v0.49 introduced no new finding** — the new SECURITY
DEFINER fn is not flagged (`search_path` locked, EXECUTE revoked); the
6 swarm-tagged lints are all pre-existing v0.48 table/RPC items already
accepted as advisor-clean; the 2 ERRORs (`provider_usage_week/today`
SECURITY DEFINER views) are unrelated pre-existing, out of scope.

**Scope cut (documented, not silent):** the plan's *"swarm burn > X
tokens/min"* alert is **deferred to v1.22.1** — the helper heartbeat
carries no token field (P0 = zero `$`, R2-5; tokens are the P1 Cost
Intelligence headline). v0.49 ships the blocked-age alert only.

**CI**: RPC-contract guard `OK`; alert-type guard `ok` (it scans only
`app_rpc.sql`, not migrations — the new `'Swarm Agent Blocked'` type is
migration-only, so no drift trip). Optional `send-webhook` TYPE_ALIASES
`swarm_blocked` filter-chip = a noted follow-up (delivery already works
by default).

**DONE**: `apply_migration` to prod + ledger entry landed 2026-05-17
(see Gemini dispositions + post-apply verification above).

---

## v1.22.0 status @ S1–S6 + H-F1 COMPLETE (2026-05-17)

All P0 work items + H-F1 are on `main`, archived above, build-verified,
CI-green (sole red = the known pre-existing Android release-AAB
keystore step — handoff says don't fix; parity + unit tests + local
debug build all pass).

| Item | Plat | Commit | Verify |
|---|---|---|---|
| review+signoff | — | `1d57fb4` | Gemini R1/R2 + user lock |
| H-F1 | helper | `75ef646` | 558 pytest |
| S1+S1b | helper | `2cd824f` | 558 pytest (dark) |
| S2 | backend | `b9f3686` + **prod APPLIED** | advisor-clean |
| S3 | macOS | `acef706` | Bar BUILD SUCCEEDED |
| S4 | iOS | `df95bb4` | iOS BUILD SUCCEEDED |
| S5 | watch+Android | `be9ec65`,`b26b196` | Watch + Android builds OK |
| S6 | backend | `54cf1f4` (+ Gemini-hardening commit) | **APPLIED to prod 2026-05-17 (advisor-clean)** |

## D7 i18n — swarm.* full localization (DONE 2026-05-17)

The plan's carried-over D7 follow-up is **complete**. Prior state
(verified against the live `.lproj`/`values-*` files, NOT the
checkpoint prose — the doc's "es done" claim was wrong): only en +
zh-Hans were real; **es, ja, ko Apple were all English baseline**;
Android `swarm_widget_description` was English in ja + ko (es/zh done).

Translated this pass (native-quality, UI-tight, placeholders preserved):
* **Apple** `Localizable.strings` es / ja / ko — all 13 keys
  (`tab.swarm` + 12 `swarm.*`). Term parity with zh-Hans's localized
  "Swarm": es **Enjambre** (matches Android es), ja **スウォーム**, ko
  **스웜**. `swarm.worktree` left as `worktree` in every locale (git
  technical term — same choice zh-Hans already made).
* **Android** `strings.xml` `values-ja` / `values-ko`
  `swarm_widget_description`.
* **Verified**: `plutil -lint` OK for all 5 `.lproj`; per-key `%d`/`%@`
  count parity vs `en` confirmed programmatically (no format-arg
  drift); ja/ko `strings.xml` XML well-formed. Pure resource-value
  edits (no Swift/Kotlin, no format-arg change) ⇒ cannot break the
  build; CI smoke matrix is the backstop.

**Gated remainder (S6 + D7 now DONE — all below require user/device/account):**
1. **Live Activity APNs-push** — real-device gate (LA ships
   structurally; push path = v1.22.x follow-up).
2. **Coordinated enable** — flip `HelperConfig.swarm_enabled` only
   after the helper .pkg carrying S1/S1b ships (S2 + S6 already live).
3. **5-channel ship** — 1.21.0→1.22.0, build 62→64, Android vc 30→31;
   helper .pkg republish; VM smoke before DEVID promote; ASC/Play
   account ops (incl. `NSSupportsLiveActivities` at ASC submit).

The dark `swarm_enabled` flag means production behavior is still
unchanged; nothing here is user-visible until the coordinated enable
in the ship train.

---

## Pre-ship hardening & verification sweep (DONE 2026-05-17)

User-directed autonomous sweep while the gated ship awaits the user.
Plan: `~/.claude/plans/inherited-humming-finch.md` (Gemini 3.1 Pro
GO-WITH-CHANGES — BLOCKER dark-gate test + 3 MAJORs all adopted).
Strictly additive: tests, docs, 2 comment-only edits — no behavior change.

**Full-train verification, all GREEN:**
- helper `ruff` clean; `pytest -q` **566 passed, 1 skipped** (incl. 8 new).
- CLIPulseCore `swift test` All tests passed (RemoteSwarm suite incl.);
  HelperSwift 336/0.
- 5-scheme `xcodebuild` (macOS/iOS/Watch/Widgets/CLIPulseHelper) all
  BUILD SUCCEEDED; Android `clean testDebugUnitTest assembleDebug`
  BUILD SUCCESSFUL (JDK17 + local SDK; a stale gitignored
  `ic_launcher 2.png` build artifact — source clean, CI unaffected).
- **Prod v0.49 evaluator** validated live via rollback-only `DO` blocks
  (FK pair from `devices`): (a) non-numeric `blocked`/`age` no raise;
  (b) 1 alert, opaque handle only; (c0/c1/c2) hysteresis isolated
  (unresolved-clause / 60s-window-while-resolved / re-fire after 65s);
  (d) clamps hold (100000 / 43200 min, no 22003). Zero committed leak
  (`alerts`/`remote_swarms`/`webhook_jobs` all 0 — rolled-back
  webhook_jobs confirms the trigger is MVCC-safe, not `pg_net`-sync).
- **3 Gemini 3.1 Pro deep reviews — all GO**: (1) dark-gate seam (no
  SwarmStore/RPC when `swarm_enabled=False`, no mid-flight race);
  (2) rollup ↔ v0.48 RPC ↔ Swift `Models.swift` / Kotlin
  `RemoteSwarm.kt` decode exact match; (3) iOS Live Activity
  `reconcile()` lifecycle + `pushType:nil` correct, no leak.

**8 additive tests:** `test_swarm.py` +5 (oldest-blocked-age value &
oldest-pick, per-swarm `_MAX_SESSIONS_PER_SWARM` cap, bare-repo→None,
git-not-found→None); `test_remote_hook.py` +3 (the ship-critical
**`swarm_enabled=False` dark-gate** invariant + `_swarm_mark`
awaiting→running lifecycle). Heartbeat `False` gate already covered by
`test_swarm_heartbeat.py::test_disabled_gate_uploads_nothing`.

**Decision A (deferred, not done):** the duplicated attention-sort
comparator in `SwarmTab.swift` / `iOSSwarmTab.swift` is left duplicated
for v1.22.0 (cross-ref comments added); extract to a shared CLIPulseCore
pure func + unit test in v1.22.1 (View-body refactor not worth the
behavior-change risk pre-gated-ship).

**Artifact:** `docs/v1.22_SHIP_CHECKLIST.md` — first formal ship
checklist since v1.16; makes the §6 gated remainder mechanical.
No ship blocker found. Feature still DARK; prod behavior unchanged.

**Closeout (2026-05-17):** committed `e128555`, pushed to `main`; push
smoke matrix all green — Swift CI / Helper CI / Supabase CI / Lint all
`success`. Android CI path-filtered (no `android/` change) → not
triggered this commit, so the known pre-existing release-AAB keystore
failure did not run. Sweep fully closed; only the §6 gated user-only
ship steps remain.
