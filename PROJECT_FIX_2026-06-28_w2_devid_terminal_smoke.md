# PROJECT FIX — DEVID in-app terminal smoke + CI config invariants (W2)

**Date:** 2026-06-28
**Branch / PR:** `feat/w2-devid-terminal-smoke`
**Plan:** `DEV_PLAN_2026-06-28_inapp_terminal_productionize.md` §7 (W2)
**Depends on:** W1-A (#243) + W1-B (#244) — merged.

## Problem
After W1-A/W1-B the DEVID in-app terminal is finally *shippable*, but it has
**still never run end-to-end**. The plan + reviewers agreed render fidelity cannot
be verified headlessly (headless macOS suppresses `requestAnimationFrame` / GPU
compositing → a WKWebView render test would flake/hang), so verification splits in
two: a **manual on-device smoke** (the real proof) and **CI config invariants**
(catch the regression class that hid the terminal in the first place).

## Deliverables

### 1. `scripts/terminal_render_fixture.sh`
A dependency-free ANSI/UTF-8 fixture so "1:1 render" is objective, not eyeballed:
16/256/truecolor, all SGR attributes, single/double/rounded box-drawing + block
shading, CJK wide-char column alignment, absolute cursor addressing, an animated
braille spinner, and an OSC 0 window title. Run it inside the in-app terminal AND
macOS Terminal.app side-by-side — every section must match.

### 2. `docs/DEVID_TERMINAL_SMOKE.md`
The repeatable on-device checklist: clean Mac **without** the App Store copy (the
shared `yyh.CLI-Pulse` bundle id + the MAS Launch Constraint blocks DEVID
co-launch), notarized DEVID build, helper paired + Local Control on; then spawn
claude / agy / codex and verify spawn → render (fixture) → input → resize →
stop/detach/reattach → helper-down gating. **MANDATORY before promoting a DEVID
`latest.json`.**

### 3. `devid-dmg.yml` config invariant (new step)
After notarization, asserts the FINAL shipped `staging/CLI Pulse.app`:
- is **unsandboxed** (no `com.apple.security.app-sandbox`) — the exact regression
  that hid the terminal on every prior build;
- carries the expanded keychain group `KHMK6Q3L3K.group.yyh.CLI-Pulse` +
  app-group `group.yyh.CLI-Pulse`, with no unexpanded `$(` macro;
- contains the xterm bundle at
  `Contents/Resources/CLIPulseCore_CLIPulseCore.bundle/Contents/Resources/`
  (`index.html`, `xterm.js`, `xterm.css`).

`build_signed_app.sh` already runs the full semantic verifier DURING the build;
this is the belt-and-suspenders check on the notarized + stapled artifact that
ships to AppUpdater clients.

## Validation
- Fixture: `bash -n` + executed (valid ANSI + UTF-8 box-drawing/CJK).
- `devid-dmg.yml`: YAML parses; the invariant bash logic was run against a real
  local DEVID build and PASSES (unsandboxed, keychain expanded, no macro, xterm
  bundle present) — and would fail on a sandboxed/missing-bundle regression.
- NOTE: `devid-dmg.yml` only runs on `workflow_dispatch` / `app-v*` tags, so this
  step executes on the next DEVID DMG build, not on this PR's swift-ci/ci-gate.

## Still owner-gated
The **manual on-device smoke itself** requires a real notarized DEVID build on a
clean Mac and cannot run in this environment / in CI. Run
`docs/DEVID_TERMINAL_SMOKE.md` and record results before promoting `latest.json`.
