# PROJECT_FIX — v1.26.0 polish + CodexBar drift refresh

**Train**: v1.26.0
**Window**: 2026-05-27 JST (single-session ship)
**Plan**: `~/.claude/plans/v1.26-development-plan.md`
**Predecessor**: PROJECT_FIX_2026-05-27_v1.25_ios_in_app_terminal.md (iOS interactive terminal MVP)
**Status**: All 8 PRs merged to `main`. Versions: 1.26.0 / Apple build 67 / Android code 35.

---

## 1. What shipped

8 PRs in this train (#93–#100):

| Phase | PR | Title | Notes |
|---|---|---|---|
| **A0** | [#93](https://github.com/cli-pulse/cli-pulse-private/pull/93) | `TerminalRingBuffer` internal locking | Codex HIGH — race in shipped v1.25 code; promoted ring buffer to fully self-locking via `NSLock` |
| **A3** | [#94](https://github.com/cli-pulse/cli-pulse-private/pull/94) | Alibaba Token Plan API drift | Upstream `3be413f` flipped from `bailian-cs.console.aliyun.com` BSP gateway to `BssOpenAPI-V3 GetSubscriptionSummary`; old endpoint silently empty |
| **B1** | [#95](https://github.com/cli-pulse/cli-pulse-private/pull/95) | iOS 500-line scrollback cap | `window.TERMINAL_CONFIG` JS hook + `WKUserScript` injection; Mac Bar stays at 5000 |
| **C2** | [#96](https://github.com/cli-pulse/cli-pulse-private/pull/96) | `workflow_dispatch` on every CI workflow | Codex LOW Q9 — recover from future GH Actions outages without empty-commit |
| **B3** | [#97](https://github.com/cli-pulse/cli-pulse-private/pull/97) | JS bridge crash defense | try/catch around `atob` + `term.write` in rAF batcher; pin contract via `@testable` HTML reads |
| **C1** | [#98](https://github.com/cli-pulse/cli-pulse-private/pull/98) | `docs/IN_APP_TERMINAL_MAS.md` | Mac Bar vs iOS terminal MAS posture documented |
| **B2** | [#99](https://github.com/cli-pulse/cli-pulse-private/pull/99) | `fetchTailSnapshot` foreground-recovery | Subscribe-first-buffer state machine + Realtime broadcast `tail_snapshot_result`; migration v0.51 owner-gated |
| **chore** | [#100](https://github.com/cli-pulse/cli-pulse-private/pull/100) | version bump 1.25.0→1.26.0 | Apple build 66→67 / Android code 34→35 |

---

## 2. Phase A scope discipline — A1/A4/A5 SKIP rationale

The plan ranked four upstream CodexBar drift items as Phase A. After inventory-against-compiled-code:

| Item | Upstream commit | Our equivalent | Decision |
|---|---|---|---|
| **A1** Codex fork replay overcount | `45b68c3 + 49919c6` | **Zero fork-handling**: no `CodexForkBaseline`, no `inheritedTotals`, no `parent_session_id` parsing in `CostUsageScanner.swift` | **SKIP** — fix is for code we never ported |
| **A3** Alibaba Token Plan API drift | `3be413f` | `AlibabaTokenPlanCollector.swift` calls the dead endpoint | **PORTED in #94** |
| **A4** StepFun expired token refresh | `1890469` | `StepFunCollector.swift` deliberately omits the password/refresh-token path (autonomy/security contract — no stored passwords; live cookie only) | **SKIP** — architectural divergence |
| **A5** Keep legacy creds on config save fail | `6d0df07` | No `CodexBarConfigMigrator` — our config layer is per-provider `ProviderConfig`, no on-disk migration step | **SKIP** — no compiled counterpart |

This is the v1.24 "5/8 didn't have compiled counterparts" lesson applied prospectively. The freed budget went into making B2 (which Gemini bumped 3-5d → 5-7d) one-shot-able in a single session.

---

## 3. v1.25 carry-over status

These were OWNER-GATED in the v1.25 train and remain outstanding **before** v1.26 features become user-visible:

| Item | Owner action | Effect |
|---|---|---|
| Apply migration **v0.50** | Supabase Studio SQL editor | Without this, `input_raw` / `resize` RPCs reject ("Invalid command kind") and iOS interactive terminal is read-only |
| Manual end-to-end smoke | iPhone + paired Mac | Confirm typing flows through helper to PTY (Ctrl-C, arrows, etc.) |
| ASC upload build **66** + submit | App Store Connect | iOS + macOS app review submission |
| Mac DEVID DMG | sign + notarize + push to `cli-pulse-distrib` | DEVID channel ship |
| Android Play AAB (versionCode **34**) | Play Console upload | Android channel ship |

---

## 4. v1.26 owner-gated next steps (new this train)

| Item | Owner action | Effect |
|---|---|---|
| Apply migration **v0.51** | Supabase Studio SQL editor | Without this, `tail_snapshot` RPC rejects and iOS foreground-recovery silently times out at 2 s + drains buffer without prefix (same UX as v1.25 baseline). Code is inert until applied. |
| Manual end-to-end smoke | iPhone + paired Mac | Open iOS terminal → background app 30 s with output flowing → foreground → confirm snapshot prefix appears, then live continuation |
| Bump versions on ASC upload | Build 67 instead of 66 | Use v1.26 source for the next ASC submission |
| Mac DEVID DMG | Build off `main` after merging v1.26 | DEVID channel ship |
| Android Play AAB (versionCode **35**) | Play Console upload | Android channel ship |

The chore PR's `Apple build 66 → 67` bump means v1.26 supersedes v1.25 for the next submission window. Owner may choose to skip uploading build 66 and go straight to 67 with the v1.26 release notes — same train's contents.

---

## 5. Suite totals

- **HelperSwift**: 403 tests, 0 failures (was 392 at v1.25; +11 across this train — 4 tail_snapshot parser + 1 dispatch + 2 PublishTailSnapshot + 2 broadcast routing + 2 ring-buffer concurrency tests)
- **CLIPulseCore (macOS host)**: 1529 tests, 0 failures (was 1523 at v1.25; +6 A3 Alibaba tests; iOS-guarded tests for B1/B3/B2 exercised by iOS scheme CI build only)

---

## 6. What's deliberately deferred to v1.27

| Item | Reason |
|---|---|
| **Android terminal mirror (Phase 5)** | Android has zero remote-control plumbing today. Mirroring iOS Phase 4 requires first porting session list / startSession / sendInput / approvals. Multi-week effort; dedicated v1.27 train. |
| **Tauri desktop terminal (Phase 6)** | Sits in `cli-pulse-desktop` repo. v0.8.0 ConPTY incident memory requires mandatory VM smoke gate + debug-symbol artifact + kill-switch env var before any revival. |
| **Realtime channel privacy (Codex HIGH-2 R0)** | Currently broadcast uses anon-key auth; confidentiality rests on unguessable session UUID. Real fix: signed per-session subscription tokens. Threat model documented; v1.27 train. |

---

## 7. Process notes

- **CI rebases**: B3 (#97) and B2 (#99) both needed force-push rebases after sibling PRs landed first. iCloud-dup sweeps before each commit kept staging clean (per `feedback_icloud_dup_artifacts`).
- **Coordinator test seam**: B2's state machine is unit-testable only because we promoted `pendingSnapshotBuffer` from `private(set)` to plain `var`. The WS subscribe path opens a real socket so we can't drive the state machine end-to-end in XCTest — buffer state seeding is the pragmatic alternative.
- **B2 race fix**: Original plan was `request snapshot → await → subscribe`. Both reviewers (Gemini HIGH + Codex MEDIUM) flagged the race window. Final design: subscribe-first-buffer; fire snapshot RPC AFTER the buffer is primed AND the WS is joined.
- **Broadcast-only transport**: Codex MEDIUM B2 dropped the durable `kind` for snapshot results — 4 KB row cap would require chunking. Best-effort recovery is the right call for this UX.
