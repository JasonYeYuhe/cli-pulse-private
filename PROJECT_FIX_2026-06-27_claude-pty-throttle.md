# PROJECT FIX — Claude CLI PTY-probe throttle (TTL cache + backoff) (P1/M)

**Date:** 2026-06-27
**Train:** Backend trust hardening — **PR7 (optional, plan §2)**
**Branch:** `hardening/claude-pty-throttle`
**Plan:** `DEV_PLAN_2026-06-27_nextphase_trust_hardening.md` §2 (fold-in)

---

## Summary

Added a shared TTL snapshot cache + post-failure exponential backoff to
`ClaudeCLIPTYStrategy`, so the up-to-20s (×2 on parse retry) `claude /usage` PTY
probe is no longer re-spawned on every 120s tick / helper-sync / manual refresh
for a signed-in-but-CLI-unreadable user.

## Root cause

The resolver order is **OAuth → cli-pty → Web** (`ClaudeSourceResolver`), and its
snapshot cache is only a *last-resort* fallback (it does NOT short-circuit the
strategy loop). So whenever OAuth fails, `ClaudeCLIPTYStrategy.fetch()` runs and
spawns a PTY child — up to 20s, and **twice** when the first parse fails
(`fetch()` retries) — on **every** refresh trigger, with no cache/throttle, and
it is **not** covered by the OAuth `rateLimitBackoff`. For a user whose OAuth/web
paths are persistently unreadable, that is a 20-40s PTY spawn every ~120s plus
every helper-sync notification and every manual refresh — a real battery/CPU
drain.

## What changed (`ClaudeCLIPTYStrategy.swift`)

- **NEW `ClaudePTYProbeThrottle` actor** (shared `static let throttle`):
  - **TTL cache** (default 300s): a good snapshot is reused without spawning.
  - **Exponential backoff** (default 120s → 240s → … capped at 900s): after a
    failed probe (both the attempt and its one retry), subsequent refreshes skip
    the spawn for a growing window.
  - All timestamps injectable (`decide(now:)` / `recordSuccess(_:at:)` /
    `recordFailure(at:)`) → deterministic unit tests.
- **`fetch()`** now consults the throttle first:
  - `useCached` → return the cached snapshot (no spawn).
  - `backoff` → throw `parseFailed("cli-pty probe throttled …")`
    (`shouldFallback == true`, so the resolver moves on to Web instead of burning
    a PTY spawn).
  - `proceed` → run the probe (the existing single parse-retry preserved), then
    `recordSuccess`/`recordFailure`.

The 120s tick (< 300s TTL) can no longer re-spawn within a TTL window, and a
failing probe sits out a growing cooldown instead of re-spawning every tick.

## Tests (CLIPulseCore, unit — `ClaudePTYProbeThrottleTests`, macOS)

5 deterministic cases (injected clock): initial proceed; cache within TTL then
proceed after expiry; backoff grows 120→240; backoff caps at 900; a success
clears the failure backoff and caches.

## Verification checklist

- [x] `swift build` clean.
- [x] New `ClaudePTYProbeThrottleTests` (5) pass.
- [ ] Full `swift test` (no `--filter`) green — see PR CI.

## Notes / design choices

- Kept the **in-strategy** throttle rather than touching the refresh triggers
  (the plan's "drop the high-freq helper-sync re-fire"): a warm TTL cache makes
  the helper-sync/manual re-fire cheap *without* removing the refresh signal
  (which also drives detection) — lower blast radius.
- A manual refresh within the TTL returns the cached cli-pty snapshot rather than
  re-spawning; acceptable for a fallback path (usage moves slowly). Tune `ttl`
  down if fresher manual refreshes are wanted.
- Backoff reuses `parseFailed` (no new `ClaudeStrategyError` case) to avoid
  touching exhaustive switches; the message text makes the cause clear in logs.
