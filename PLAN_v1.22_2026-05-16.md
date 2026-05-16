# CLI Pulse v1.22 Strategic Dev Plan (2026-05-16)

**Status**: Draft for Gemini 2-round review + user sign-off. Do NOT start
implementation until reviewed (per `feedback_gemini_review_patterns`).

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
abstraction —
  - Helper: detect the git worktree / repo root + branch per session
    and tag events with a `swarm_key` (repo root) + `worktree` +
    `branch`. Group sibling sessions.
  - Backend: `remote_swarms` view/RPC that rolls up active sessions by
    `swarm_key` — aggregate tokens/min, cost/min, per-agent status
    (running / awaiting-approval / idle / errored), oldest-blocked age.
  - Mac: a "Swarm" tab — live grid, one card per agent/worktree, sorted
    by "needs attention" (blocked > error > burning > running > idle).
    Combined burn meter at top. Click a card → existing session detail.
  - iOS: Swarm grid + **Live Activity / Dynamic Island** showing
    `{n agents · m blocked · $X/hr}`, with Approve/Deny for the
    oldest-blocked agent inline (lands the deferred I-F1).
  - watch + Android Glance widget: `{n · m blocked}` at-a-glance
    (lands deferred W-F-class + A-F1).
  - Alerting: a swarm-level alert "agent blocked > 5 min" /
    "swarm burn > $X/hr" via the existing alert pipeline + optional
    Slack/Discord webhook (lands deferred B-F2).

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
| S1 | Helper: derive `swarm_key`=repo-root, `worktree`, `branch` per session; tag events. Audit `provider_spawners/*` + worktree detection (`git rev-parse --show-toplevel`, `--git-common-dir` for worktree). | H | M |
| S2 | Backend: `remote_swarm_summary()` RPC + index; aggregates active sessions by swarm_key. Schema change → **user-approval gate**. | B | M |
| S3 | Mac Swarm tab: live grid, attention-sort, combined burn meter, drill-in to SessionDetail. | M | L |
| S4 | iOS Swarm grid + Live Activity / Dynamic Island w/ inline Approve-oldest-blocked (deferred I-F1). Capability + entitlement audit; MAS-strip safe. | I | L |
| S5 | watch complication + Android Glance widget: `{n · m blocked}` (deferred W-F / A-F1). | W,A | M |
| S6 | Swarm-level alerts (blocked-age, burn-rate) + optional Slack/Discord webhook (deferred B-F2, reuse `webhook_jobs`). | B,X | M |

### P1 Cost Intelligence
| # | Item | Plat | Eff |
|---|---|---|---|
| C1 | True-cost normalizer model + provider efficiency leaderboard. | X | M |
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
| RK1 | Worktree detection is brittle across the 30+ CLIs (each spawns differently). | S1 audits `provider_spawners/*`; fall back to repo-root-only grouping when worktree undetectable; never crash a session over swarm tagging. |
| RK2 | Live Activity / Dynamic Island capability changes break MAS strip or sandbox. | Mirror v1.21 D2 discipline: capability+entitlement audit, real-device test, verify MAS strip per `feedback_mas_vs_devid_helper`. |
| RK3 | Swarm aggregation RPC hot-loops on large event volume. | Index + `remote_session_events.created_at` (already shipped v1.21 F7); cap swarm fan-in; precompute via the existing cron pattern if needed. |
| RK4 | Backend schema for S2/T1 violates autonomy contract. | User-approval gate before any migration (`feedback_cli_pulse_autonomy`). |
| RK5 | Scope creep — P0+P1+P2 in one train repeats nothing-ships risk. | Hard split per §4. v1.22.0 = P0 only. |
| RK6 | Privacy regression in Team Rollup (per-member data). | Aggregate $/token only; never prompt/transcript content; reuse helper redaction; legal-grade copy reviewed by user (zh-CN native). |

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

## 7. Memory references

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
