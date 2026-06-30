# PROJECT FIX — session detector recognizes `agy` (managed Gemini was invisible)

**Date:** 2026-06-30 · **Found by:** first-principles verification workflow (wf_f3667423-995), P2 regression.

## Problem
PR #264 routed managed Gemini through the `agy` wrapper (to run on the user's Gemini plan).
But the system-wide session/Swarm scanner classifies providers by matching the `ps` command
line against `providerPatterns`, which only knew `\bgemini\b` / `\bgoogle-generativeai\b`.
A managed Gemini process is now `.../agy` (no "gemini" substring) → `detectProvider` returns
nil → **every managed-Gemini session is invisible to the system/Swarm scan** (100% of
managed-Gemini users). A pure observability regression introduced by the agy routing.

## Fix (1:1 Swift + Python parity)
Add `("Gemini", \bagy\b, "high")` to:
- `HelperSwift/Sources/HelperKit/SystemCollection/SessionDetector.swift` providerPatterns
- `helper/system_collector.py` PROCESS_PATTERNS

Placed **after** the explicit `\bantigravity\b` pattern. `detectProvider` is first-match-wins,
so a full "antigravity" reference still classifies as Antigravity, while the bare `agy`
binary (CLI Pulse's Gemini-on-plan wrapper) classifies as Gemini — the provider the user
selected. (`agy` is the Antigravity CLI; CLI Pulse spawns it specifically as the Gemini
provider.)

## Tests
- `SessionDetectorTests`: `/opt/homebrew/bin/agy` + `agy --dangerously-skip-permissions` →
  Gemini; Antigravity path still → Antigravity (ordering regression guard).
- Python parity check (replicating first-match over PROCESS_PATTERNS): agy→Gemini,
  antigravity→Antigravity, gemini→Gemini all correct.
- Full HelperKit `swift test`: 458 tests, 0 failures.

## Note
This restores visibility of managed-Gemini sessions. The complementary availability-gray-out
(gemini-installed-but-agy-absent) reason string is tracked separately.
