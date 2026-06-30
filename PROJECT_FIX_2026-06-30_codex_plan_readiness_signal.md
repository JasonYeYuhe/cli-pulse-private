# PROJECT FIX — Codex plan-readiness signal (no more silent off-plan billing)

**Date:** 2026-06-30 · **Found by:** first-principles verification workflow (wf_f3667423-995), the top P2 (financial).

## Problem
Managed Codex scrubs `OPENAI_API_KEY` (→ runs on the ChatGPT plan) ONLY when the user has a
verified `auth_mode=="chatgpt"` login. For an `auth_mode=="apikey"` user the scrub correctly
does NOT fire — but then the session runs on the **billed pay-per-token OpenAI API with no
warning**. The user picked "Codex" expecting their plan and is silently billed. Verified
on-device (codex-cli 0.133.0): with `OPENAI_API_KEY` in env codex reports "HTTP reachability
uses API-key mode" against `api.openai.com`. The reviews had deferred this readiness signal;
the verification confirmed it as real money, silent.

## Fix — surface per-provider plan-auth status helper→app and warn in the picker
- **`ProviderSpawner.planAuthStatus(resolvedHome:) -> String`** (default `"unknown"`):
  - `CodexSpawner`: verified ChatGPT login ⇒ `"on_plan"`; api-key/other ⇒ `"off_plan"`;
    unresolvable home ⇒ `"unknown"`.
  - `GeminiSpawner`: agy resolvable ⇒ `"on_plan"`; else `"unknown"` (never a billed
    fallback).
  - `ClaudeSpawner`: default `"unknown"` — its on-plan-ness is signaled by the existing
    OAuth-floor gate (`localHelperBelowOAuthFloor`), not duplicated here.
- **Helper** exposes `provider_plan_status` (map, omitting `"unknown"`) in the UDS hello
  reply (`ProviderSpawnerRegistry.planAuthStatuses` → `ManagedSessionManager.providerPlanStatus`
  → `LocalSessionServer` hello).
- **App** parses it (`LocalSessionControlClient`) into `SessionControlHello.providerPlanStatus`
  → `AppState.localProviderPlanStatus`. The **Sessions-tab spawn picker** relabels the Codex
  item to "Codex — OpenAI API (billed, not your plan)" with a warning glyph when
  `provider_plan_status["codex"] == "off_plan"`. **Warn, not block** — an api-key login is the
  user's own codex config; absent/`"unknown"` ⇒ no warning (older helpers degrade silently).

## Tests
- HelperKit (463, 0 failures): codex planAuthStatus nil-home→unknown, no-auth→off_plan;
  gemini never off_plan; default→unknown.
- CLIPulseCore (1834, 0 failures): client parse defaults (`?? [:]`); Hello field.
- App target (`CLI Pulse Bar`): builds clean (SessionsTab picker change).

## Deferred
- **Python `.pkg` helper parity:** `local_session_server.py` does not yet emit
  `provider_plan_status` (its provider spawners would need the same auth-mode classification).
  The app degrades gracefully (absent field → no warning, == pre-fix behavior), so no
  regression — but a managed-Codex session on the legacy .pkg helper won't show the warning.
  Add the Python classification for 1:1 parity in a follow-up. The bundled Swift helper (the
  primary DEVID path) has the signal.
