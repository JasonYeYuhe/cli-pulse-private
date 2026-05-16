# CLI Pulse v1.22 Strategic Dev Plan (2026-05-16)

**Status**: Gemini 2-round review **COMPLETE** 2026-05-16 (R1
GO-WITH-CHANGES, R2 GO-WITH-MINOR-CHANGES; all findings adopted —
see §7–§8). **User scope sign-off RECEIVED 2026-05-16 → IMPLEMENTING.**

**Scope lock (user, 2026-05-16):**
- **Q5 → v1.22.0**: H-F1 4th-provider refactor ships in the launch train.
- **Q6 → v1.22.1**: C4 public share link held out of the launch train.
- **Train shape → P0-only**: v1.22.0 = P0 Swarm View (S1–S6) + H-F1.
  P1 Cost Intelligence = v1.22.1, P2 Team Rollup = v1.23.0.
- **P0 ships ZERO `$`**: tokens/min only; all dollar framing is the
  P1 headline (R2-5 confirmed by user).

**Prev train**: v1.21.0 shipped 2026-05-16 across all 5 channels
(Backend Supabase prod, DEVID DMG, iOS App Store, macOS App Store,
Android Play). v1.21.0 was a correctness/consistency sweep. v1.22 is
the first **feature-bet** train since the audit cycle — it picks a
strategic direction, not just polish.

---

## 0. TL;DR — the strategic thesis

CLI Pulse today is *"a real-time usage + quota monitor for one developer's
AI coding tools, on every screen they own."* That's a solid utility but a
commodity framing — 13+ "AI cost tracker" listicles exist and LLM-app
observability (Datadog/Langfuse/Braintrust) is crowded.

**The wedge nobody owns**: observability for developers *operating AI
coding agents* — specifically the **multi-agent / swarm workflow** that
became the defining trend of 2026. CLI Pulse already has the three hard
primitives this needs (multi-provider ingestion, live Sessions, Remote
Approvals from phone). No competitor combines them for the swarm use case
at a prosumer price.

**v1.22 theme: "Mission Control for the agent swarm."** Three pillars:

1. **P0 — Swarm View**: a live grid of every parallel agent / git
   worktree running across a dev's machines, with aggregate burn,
   per-agent status, and one-tap Approve/Deny to *any* agent from the
   phone / watch / Dynamic Island.
2. **P1 — Cost Intelligence**: turn the usage data we already collect
   into normalized cross-tool "true cost" analytics + hard budget
   guardrails + a monthly "AI spend statement."
3. **P2 — Team Rollup**: a light-governance team dashboard (per-member
   spend, tool-overlap detection, exportable ROI-proxy report) that
   moves CLI Pulse up-market into the $40/user Team tier with a real
   reason to pay.

P0 is the differentiator and the marketing story. P1 monetizes
prosumers. P2 monetizes teams. Ship P0 first; it is also the highest
technical risk so it sets the train length.

---

## 1. Market research synthesis (mid-2026)

Sources reviewed 2026-05-16 (web search):

- **30+ AI coding CLIs in the wild.** Claude Code, Codex CLI, Gemini
  CLI lead; 15+ serious others (Aider, OpenCode, Goose, Pi, Cursor CLI…).
  Pricing has fragmented into credits / tokens / quotas / premium
  requests / daily caps — *"comparing tools requires reading the fine
  print, not the headline price."* This is exactly the pain CLI Pulse's
  multi-provider quota engine already addresses; the market is moving
  toward us, not away.
  - dev.to "Every AI Coding CLI in 2026" ; tembo.io "15 AI Agents
    Compared" ; nxcode.io / developersdigest pricing comparisons.
- **Token efficiency >> subscription price.** Claude Code uses ~5.5x
  fewer tokens than Cursor for comparable work; the real cost delta
  dwarfs the $1–4/mo sticker gap. Nobody packages cross-tool efficiency
  comparison for the individual dev.
  - tokencalculator.com "Best AI IDE & CLI Tools April 2026".
- **Multi-agent orchestration / swarms is THE 2026 trend.** Git
  worktrees "became load-bearing for AI coding in Q1 2026"; by April
  2026 almost every major tool shipped worktree support. Claude Code
  "Agent Teams" / Swarm Mode shipped with Opus 4.6 on 2026-02-05.
  Claude Squad, Composio AO, Nevo (21 agents, 3 model tiers),
  Parallel Code, Catnip, CLI Agent Orchestrator. **But every one of
  these leaves task alignment, conflict resolution, *and observability
  across the parallel agents* on the user's plate.** That last gap is
  ours.
  - github ComposioHQ/agent-orchestrator ; augmentcode "9 Open-Source
    Agent Orchestrators" ; nimbalyst "Best Git Worktree Tools 2026" ;
    dev.to "Claude Squad".
- **Enterprise shift to governance + cost discipline + ROI.** Orgs
  "lack clear visibility into where AI is used, which tools overlap,
  how consumption distributes across teams." ~3.6 dev-hours/week saved
  but attribution is hard; ~11-week onboarding lag. Existing LLM
  observability targets teams *building LLM apps*, not devs *using AI
  coding agents*. Open lane for a light, dev-first team rollup.
  - blog.exceeds.ai ROI case studies ; cio.com "Why enterprises aren't
    seeing AI ROI" ; etr.ai "Enterprise AI Trends 2026".

**Conclusion**: the swarm wave is real, accelerating, and structurally
unobserved at the individual/prosumer tier. CLI Pulse is one of the few
products with the ingestion + remote-control plumbing already shipped to
serve it. Move now, before an orchestrator vendor bolts on a dashboard.

---

## 2. v1.22 pillars

### P0 — Swarm View (the differentiator)

**Problem**: a dev runs `N` Claude/Codex/Gemini agents in `N` git
worktrees (Agent Teams, Claude Squad, Composio AO, hand-rolled). They
lose the plot: which agent is mid-task, which is blocked on a permission
prompt, which is burning tokens on a runaway loop, what the *combined*
spend is right now.

**What we already have**: helper already ingests per-session events
(`remote_sessions`, `remote_session_events`), Sessions tab renders one
session live, Remote Approvals push a single pending request to the
phone. We have multi-provider, multi-device, multi-platform.

**What v1.22 adds**: aggregate the per-session stream into a **swarm**
abstraction — *(architecture revised per Gemini Rounds 1 & 2; see §7–§8)*
  - Helper: `swarm_key` = `HMAC(repo-root + branch, account_secret)` as
    the **primary, load-bearing** path. An orchestrator parent-session
    id is used *opportunistically only where one is observably exposed*
    — treated as best-effort/aspirational, never relied on (Claude
    Squad/Agent Teams do not currently expose a stable cross-process id
    the helper can intercept) (R2-3). The secret is **account-scoped,
    not device-local**, so the same repo+branch under one account
    produces the same key on every machine (cross-device grouping
    works) (R2-1). Repo path/worktree/branch never travel as plaintext:
    the helper uploads the opaque key plus the label **encrypted to the
    account key**; the phone/watch decrypt client-side (R1-A3, R2-1).
    *v1.22.0 fallback if account-envelope crypto is too heavy for the
    train:* scope P0 to **single-machine swarms** with a per-account
    salted label and defer true multi-device swarm + encrypted-label
    sync to v1.22.1 — decided at S1 implementation, surfaced in the PR.
    Repo-root alone is rejected (monorepo collapse). Never crash a
    session over swarm tagging (R1-A1).
  - Helper: emit a discrete `swarm_heartbeat` event ~every 30s carrying
    the *locally rolled-up* swarm state (per-agent status, tokens/min,
    oldest-blocked age). Aggregation happens at the edge, not in
    Postgres (R1-A4).
  - Backend: `remote_swarm_summary()` reads the **latest heartbeat row
    per `swarm_key`** (O(active-swarms), not O(events)) — no on-the-fly
    scan of `remote_session_events` — and **filters
    `WHERE created_at > now() - interval '90 seconds'`** so a
    crashed/slept helper does not leave a ghost "8 agents running"
    forever; a swarm past TTL renders as *stale / last-seen Xm ago*,
    not dropped silently (R2-2). 90s = 3× the 30s heartbeat (>2×
    padding per `feedback_gemini_review_patterns` #3 anti-flap). If
    implemented `RETURNS TABLE`, `DROP FUNCTION` precedes
    `CREATE OR REPLACE`.
  - Mac: a "Swarm" tab — live grid, one card per agent/worktree, sorted
    by "needs attention" (blocked > error > burning > running > idle).
    The combined meter is **tokens/min only** — no `$` figure in P0.
    A naive static-price `$/hr` is *removed from P0 entirely* (R2-4,
    R2-5 supersede the R1-A6 "keep naive $/hr" refinement): a wrong
    dollar number the week a provider repractices would poison the
    very "fine print" trust wedge P1 is built on. All `$` framing —
    with a backend-served, maintained price table — is the P1 headline.
    Click a card → existing session detail.
  - iOS: Swarm grid + **Live Activity / Dynamic Island** showing
    `{n agents · m blocked · age-timer}` only, with Approve/Deny for
    the oldest-blocked agent inline (lands the deferred I-F1). APNs
    pushes fire **only on discrete macro state transitions**
    (blocked-count change), never per burn tick. No `$/hr` on the Live
    Activity: ActivityKit/SwiftUI cannot recompute cost between pushes,
    so an extrapolated figure would drift wildly — the lock-screen
    surface shows only counts + a native `Text(timerInterval:)` age
    (R1-A2, R2-4). `$` stays in the foregrounded app (P1).
  - watch + Android Glance widget: `{n · m blocked}` at-a-glance
    (lands deferred W-F-class + A-F1).
  - Alerting: a swarm-level alert "agent blocked > 5 min" /
    "swarm burn > X tokens/min" evaluated in the async `webhook_jobs`
    worker (not the read path) with **hysteresis** — an alert clears
    only after the condition is false for >60s, and never fires on a
    swarm already past the 90s heartbeat TTL — to prevent flapping at
    the sync boundary (R1-A5, R2-2). Optional Slack/Discord webhook
    (lands deferred B-F2).

**Why it sells**: this is the screenshot that goes on the landing page
and in the launch tweet. "Run 8 agents, watch them all from your watch,
approve the stuck one from the gym." Nobody else has this at $0–pro
pricing.

### P1 — Cost Intelligence (prosumer monetization)

Built entirely on data already in `daily_usage_metrics` + `provider_quotas`:

  - **True-cost normalizer**: per-task-class normalized $/result, so the
    UI can say "this refactor cost $0.42 on Claude Code vs an estimated
    $2.30 equivalent on Cursor." Efficiency leaderboard across the user's
    own providers.
  - **Budget guardrails**: hard monthly/weekly budget per provider with
    escalating alerts (50/80/95/100%) *before* a daily cap or paid
    overage hits — the "fine print" defense. Reuses the alert engine.
  - **Monthly AI Spend Statement**: a one-screen, shareable
    credit-card-statement-style PDF/email (lands deferred B-F4 digest +
    builds on the existing PDF export). Pro feature.
  - **Public share link** (opt-in): "here's my AI coding stats this
    month" → growth loop (lands deferred B-F3).

### P2 — Team Rollup (team-tier monetization)

Team tier already exists in billing; today it has no team-specific value.

  - Team dashboard: per-member AI spend (respecting the existing
    redaction posture — aggregate $ + token counts only, never prompt
    content), tool-overlap detector ("3 seats paying for Cursor *and*
    Copilot — consolidate"), swarm count per member.
  - ROI-proxy export: `agent-hours × configurable $/hr` → a monthly
    eng-leader PDF. Explicitly a *proxy*, labelled as such (the research
    is clear that real ROI attribution is unsolved; we sell visibility,
    not a fake number).
  - **Backend schema work** lives here → user-approval gate per
    `feedback_cli_pulse_autonomy` before any migration.

---

## 3. Work items (to be expanded after Gemini review)

Effort: S < 1d · M 1–3d · L 3d+. Platform tags: H=helper, B=backend,
M=mac, I=iOS, W=watch, A=android, X=cross.

### P0 Swarm View
| # | Item | Plat | Eff |
|---|---|---|---|
| S1 | Helper: `swarm_key` = `HMAC(repo-root+branch, account_secret)` — **primary load-bearing path**; orchestrator parent-id only opportunistically where observably exposed (best-effort, not relied on — R2-3). Account-scoped (not device) secret so cross-machine grouping works; label uploaded encrypted-to-account-key, never plaintext (R2-1). Audit `provider_spawners/*` + worktree detection (`git rev-parse --show-toplevel`, `--git-common-dir`, `$GIT_DIR`/devcontainer/bare/submodule/detached-HEAD); repo-root-only rejected. Never crash a session on tagging failure. | H | M |
| S1b | Helper: `swarm_heartbeat` event (~30s) with locally rolled-up swarm state (edge aggregation); carries a monotonic seq so a lost beat is detectable. | H | S |
| S2 | Backend: `remote_swarm_summary()` reads **latest heartbeat row per swarm_key** filtered `created_at > now()-interval '90s'` (ghost-swarm TTL — R2-2); past-TTL ⇒ `stale` flag, not dropped; index on `(swarm_key, created_at desc)`; `DROP FUNCTION` first if `RETURNS TABLE`. Schema change → **user-approval gate**. | B | M |
| S3 | Mac Swarm tab: live grid, attention-sort, **tokens/min-only** combined meter (no `$` in P0 — R2-5; true-cost = P1), stale-swarm state, drill-in to SessionDetail; client-side label decrypt. | M | L |
| S4 | iOS Swarm grid + Live Activity / Dynamic Island (`{n · m blocked · age}` only, **no `$/hr`** — R2-4) w/ inline Approve-oldest-blocked (deferred I-F1). APNs **only on macro state transitions**; native `Text(timerInterval:)` age, no on-device cost extrapolation. Capability + entitlement audit; MAS-strip safe. | I | L |
| S5 | watch complication + Android Glance widget: `{n · m blocked}` (deferred W-F / A-F1). | W,A | M |
| S6 | Swarm-level alerts (blocked-age, burn-rate) evaluated in async `webhook_jobs` worker with **>60s hysteresis** + optional Slack/Discord webhook (deferred B-F2, reuse `webhook_jobs`). | B,X | M |

### P1 Cost Intelligence
| # | Item | Plat | Eff |
|---|---|---|---|
| C1 | Cross-tool spend = raw tokens × **backend-served, maintained provider price table** (NOT a static client table — R2-5; NOT a "tokens-per-resolved-session" proxy — Q3/R1). Owns ALL `$` framing app-wide (P0 deliberately ships none). Provider $ comparison, not an efficiency "leaderboard". | X | M |
| C2 | Budget guardrails: per-provider budget + 50/80/95/100% escalating alerts. | X | M |
| C3 | Monthly AI Spend Statement (PDF + email, Pro-gated; extends existing PDF + deferred B-F4). | M,B | M |
| C4 | Opt-in public share link (deferred B-F3; short-token read-only view). **Public-surface → flag per autonomy.** | B | M |

### P2 Team Rollup
| # | Item | Plat | Eff |
|---|---|---|---|
| T1 | Team dashboard: per-member spend + tool-overlap detector (aggregate-only, redaction-safe). | B,M | L |
| T2 | ROI-proxy monthly export (labelled proxy). | B,M | M |

### Carried-over polish (do NOT let these block P0; batch opportunistically)
- D7 long-tail Apple i18n sweep (~15 strings, Mac+iOS, 2 PRs).
- D7 native-speaker review of `advanced.remote_consent_body` es/ja/ko.
- M2 Sentry network-error breadcrumb tagging across Supabase paths.
- F9 live-migration-replay CI redesign (anchor schema.sql at vN, or
  invert source-of-truth so migrations generate schema).
- zh-Hant real translation → then add the lproj (deferred from D8).
- H-F1 4th-CLI provider path refactor — strategically important as the
  CLI count keeps growing; do it early in v1.22 so Swarm View covers
  Aider/OpenCode/Cursor-CLI from day one.

---

## 4. Train shape & sequencing

```
v1.22.0  — P0 Swarm View end-to-end (S1→S6) + H-F1 provider refactor.
           This is the launch train; it is the marketing story.
v1.22.1  — P1 Cost Intelligence (C1→C4). Fast follow, prosumer upsell.
v1.23.0  — P2 Team Rollup (T1,T2) + backend governance. Up-market.
```

Rationale: S1 (helper swarm tagging) and S2 (backend RPC) gate
everything; build + Gemini-review those first. S3/S4 are the visible
payoff and the highest UI risk — prototype the Mac grid before the iOS
Live Activity. Don't bundle P1/P2 into the launch train; the swarm story
must ship clean and standalone.

---

## 5. Risk register

| # | Risk | Mitigation |
|---|---|---|
| RK1 | Worktree/swarm-key detection brittle across 30+ CLIs (orchestrators expose a parent id; hand-rolled use raw worktrees; monorepo, bare/submodule/symlinked worktree, non-git agent, detached HEAD, `$GIT_DIR` override, devcontainer all break naive repo-root). | S1: orchestrator parent-id first, else `HMAC(repo-root+branch)`; **repo-root-only rejected** (monorepo collapse); explicit fallback ladder enumerated in S1; never crash a session over swarm tagging. |
| RK2 | Live Activity / Dynamic Island capability changes break MAS strip or sandbox. | Mirror v1.21 D2 discipline: capability+entitlement audit, real-device test, verify MAS strip per `feedback_mas_vs_devid_helper`. |
| RK3 | Swarm aggregation hot-loops on large event volume. | **Edge aggregation** (R1-A4): helper emits `swarm_heartbeat`; backend read is O(active-swarms) latest-row, not O(events). Index `(swarm_key, created_at desc)`; v1.21 F7 created_at index still applies. |
| RK4 | Backend schema for S2/T1 violates autonomy contract. | User-approval gate before any migration (`feedback_cli_pulse_autonomy`). |
| RK5 | Scope creep — P0+P1+P2 in one train repeats nothing-ships risk. | Hard split per §4. v1.22.0 = P0 only. |
| RK6 | Privacy regression in Team Rollup (per-member data). | Aggregate $/token only; no per-repo attribution (rejected per Q4); never prompt/transcript content; reuse helper redaction; legal-grade copy reviewed by user (zh-CN native). |
| RK7 | **P0 itself leaks PII**: repo/worktree paths + branch names carry client names, internal codenames, embargoed-CVE identifiers. | `HMAC(repo+branch, account_secret)` key + label **encrypted to the account key** before upload; backend never sees plaintext; phone/watch decrypt client-side (R1-A3, R2-1). Account-scoped (not device) secret preserves cross-machine grouping. Privacy is a P0 concern, not just P2. |
| RK8 | Lost/crashed-helper heartbeat leaves a ghost swarm ("8 agents running" forever); a device-only secret would silently fork cross-machine swarms. | S2 TTL filter `created_at > now()-90s` ⇒ stale state, not phantom-live (R2-2); account-scoped HMAC secret keeps one key per repo+branch across machines (R2-1); heartbeat carries a seq for lost-beat detection. |

## 6. Open questions for Gemini review

1. Is repo-root the right `swarm_key`, or should it be the orchestrator
   session (Claude Agent Teams has its own parent id)? Detect both?
2. Live Activity update cadence vs APNs budget — push every state change
   or throttle? (ties to v1.21 F8 JWT cache + F11 silent-push infra).
3. True-cost normalization: per-task-class is hard to define
   objectively. Is a simpler "tokens-per-resolved-session" proxy
   defensible enough to ship without being misleading?
4. Team Rollup: is aggregate-only spend enough to be useful to an eng
   lead, or does it need per-repo attribution (which raises privacy
   scope)?
5. Does H-F1 (4th-provider refactor) belong in v1.22.0 (blocks swarm
   coverage of new CLIs) or v1.22.1 (keeps launch train smaller)?
6. Should the public share link (C4) be in the launch train as a growth
   loop, or held until P1 so the launch isn't diluted?

## 7. Gemini Round 1 — Disposition

Gemini 3.1 Pro reviewed the full draft + the 6 open questions on
2026-05-16 (`reference_gemini_cli`, model `gemini-3.1-pro-preview`).
Verdict: **GO-WITH-CHANGES**. Raw output archived at
`.gemini-review-v1.22-round1.txt`. All findings adopted; plan bodies
(§2 P0, §3 S1/S1b/S2/S3/S4/S6/C1, §5 RK1/RK3/RK6/RK7) revised in place.

| Gemini finding | Severity | Disposition |
|---|---|---|
| R1-A1 repo-root swarm_key collapses monorepos; daemon cwd inference fragile for containerized agents | CRITICAL | **Adopted** — S1 + §2 now: orchestrator parent-id first, else `HMAC(repo-root+branch)`; repo-root-only rejected; resolves Q1 |
| R1-A2 Live Activity APNs budget exhausted by 8 agents flipping state / burn ticks | CRITICAL | **Adopted** — S4 + §2: APNs only on macro state transitions; baseline burn in payload, on-device extrapolation; local age timer; resolves Q2 |
| R1-A3 P0 leaks sensitive repo/branch names to backend (not just a P2 issue) | MAJOR | **Adopted** — new RK7; helper HMAC-hashes path/branch device-side before upload, UI resolves locally; privacy promoted to a P0 concern |
| R1-A4 on-the-fly `remote_swarm_summary()` hot-loops on event volume; `RETURNS TABLE` migration friction | MAJOR | **Adopted** — new S1b `swarm_heartbeat` edge aggregation; S2 reads latest-heartbeat-per-key (O(swarms)); `DROP FUNCTION` if `RETURNS TABLE`; RK3 rewritten |
| R1-A5 blocked/burn alerts flap at the sync boundary | MAJOR | **Adopted** — S6 + §2: eval in async `webhook_jobs` worker with >60s hysteresis (matches `feedback_gemini_review_patterns` #3) |
| R1-A6 P0 `$X/hr` secretly couples to the P1 cost-normalizer → scope creep | MINOR | **Adopted-with-refinement** — P0 primary meter = tokens/min (factual); a *naive* `$/hr` (raw tokens × static list-price) stays in P0 to preserve the launch screenshot; the *normalized cross-tool true-cost* model stays P1 (RK5 intact) |
| Q1 swarm_key choice | CRITICAL | **Resolved** — see R1-A1 |
| Q2 Live Activity cadence | CRITICAL | **Resolved** — see R1-A2 |
| Q3 true-cost proxy is misleading | MAJOR | **Adopted** — C1 reworded: raw tokens × standard provider pricing, NOT a "tokens-per-resolved-session" proxy; no efficiency "leaderboard" |
| Q4 Team Rollup per-repo attribution | MAJOR | **Adopted** — aggregate-only; per-repo attribution rejected; folded into RK6 |
| Q5 H-F1 in v1.22.0 vs v1.22.1 | SCOPE | Gemini recommended **v1.22.0**; **user confirmed v1.22.0 (2026-05-16)** — H-F1 in the launch train |
| Q6 public share link C4 in launch train | SCOPE | Gemini recommended **hold to v1.22.1**; **user confirmed v1.22.1 (2026-05-16)** — C4 out of the launch train |

**Round 1 total verdict**: GO-WITH-CHANGES. Architecture (swarm-key,
edge aggregation, APNs, privacy) revised above; two scope questions
(Q5, Q6) + P0-as-standalone-train carried to user sign-off.

## 8. Gemini Round 2 — Disposition

Gemini reviewed the Round-1-revised plan on 2026-05-16, tasked to (a)
verify dispositions were really in the bodies and (b) surface
second-order issues the fixes introduced. Verdict:
**GO-WITH-MINOR-CHANGES**; it confirmed Round 1 changes were genuinely
adopted and the S2 approval-gate / RK5 scope split intact. Raw output
archived at `.gemini-review-v1.22-round2.txt`. All findings adopted;
bodies (§2 P0, §3 S1/S1b/S2/S3/S4/C1, §5 RK7/RK8) revised in place.

| Round 2 finding | Severity | Disposition |
|---|---|---|
| R2-1 device-local HMAC secret forks cross-machine swarms; phone has empty local cache → can't resolve hash→repo name | CRITICAL | **Adopted** — secret is now **account-scoped**; label uploaded **encrypted to account key**, phone/watch decrypt client-side; documented v1.22.0 fallback = single-machine swarms + defer multi-device to v1.22.1; §2/S1/RK7/RK8 rewritten |
| R2-2 lost/slept heartbeat ⇒ ghost "8 agents running" forever | CRITICAL | **Adopted** — S2 + §2: TTL filter `created_at > now()-interval '90s'`; past-TTL ⇒ `stale/last-seen`, not dropped; 90s = 3× heartbeat anti-flap; new RK8; alerts suppressed on past-TTL swarms |
| R2-3 orchestrator parent-id is aspirational, not a real fallback — HMAC path is the only functional one | MAJOR | **Adopted** — S1 + §2 reworded: `HMAC(repo+branch)` is the **primary load-bearing** path; orchestrator-id only opportunistic/best-effort where observably exposed; refines the Q1 answer |
| R2-4 Live Activity can't recompute `$/hr` between pushes → wild drift | MAJOR | **Adopted** — Live Activity now `{n · m blocked · native age-timer}` only, no `$`; cost stays in the foregrounded app; §2 iOS + S4 rewritten |
| R2-5 naive static-price `$/hr` in P0 is a maintenance/accuracy liability that poisons the P1 trust wedge | MINOR→**escalated** | **Adopted — supersedes the R1-A6 "keep naive $/hr" refinement.** P0 ships **tokens/min only, zero `$`**; ALL `$` framing (backend-served maintained price table) becomes the P1 headline; §2 Mac + S3 + C1 rewritten. RK5 strengthened (cleaner P0/P1 split) |
| Q5 H-F1 in v1.22.0 | SCOPE | Round 2 re-confirmed v1.22.0; **user confirmed v1.22.0 (2026-05-16)** |
| Q6 public share link C4 | SCOPE | Round 2 re-confirmed hold; **user confirmed v1.22.1 (2026-05-16)** |
| Disposition-vs-body audit | — | Round 2 explicitly confirmed Round 1 changes were really in the text (the #1 v1.21 Round 2 failure mode) — no table/body gaps found |

**Round 2 total verdict**: GO-WITH-MINOR-CHANGES. All five R2 findings
applied above; the only open items are the two scope decisions (Q5, Q6)
and P0-as-standalone-train, which the handoff designates as **user**
calls. Plan is otherwise implementation-ready pending that sign-off.

## 9. Memory references

- `feedback_cli_pulse_autonomy` — backend schema / public-repo / Sentry
  = user-approval-gate; act-don't-ask otherwise.
- `feedback_gemini_review_patterns` — 2-round Gemini review before
  implementation; watch Postgres RETURNS TABLE drops, threshold
  flapping, fallback visibility.
- `feedback_fix_archiving` — every fix → PROJECT_FIX_*.md.
- `feedback_v080_crash_on_launch_incident` — VM smoke before any
  DEVID `latest.json` promote.
- `feedback_mas_vs_devid_helper` — MAS strip for embedded helper;
  capability changes must keep MAS sandbox valid.
- `feedback_asc_release_workflow` — 5 ASC gotchas; What's New no
  backticks; submit_v1_XX_0.py multi-locale pattern (v1.21 established).
- `reference_supabase_creds` / `reference_supabase_access_token` —
  backend deploy + schema_migrations ledger conventions.
- `reference_helper_releases_repo` — helper .pkg publish flow if S1
  ships a helper change.
- `project_v1_19_devid_impl` / v1.21 long-tail PROJECT_FIX — most
  recent ship context + the 5-channel ship runbook.
