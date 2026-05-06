# Multi-CLI managed sessions — design sketch (v1.14+ scope)

**Status: design only.** No code in this branch implements
multi-CLI; this doc captures the architecture so a future PR
doesn't expand the current Phase 4D scope and can be reviewed
independently.

## Problem

Phase 4D ships managed sessions for `claude` only (the
`PtyTransport.start("claude", ...)` path is the entire surface).
Long term we want users to spawn arbitrary CLI sessions through
CLI Pulse — Codex CLI, Gemini CLI, raw shells, custom dev
scripts — and have the same Sessions tab UX (PTY view, send_input,
structured approvals where the CLI cooperates).

This is **out of scope for v1.13/v1.14.** The Phase 4D PR (#20)
intentionally does not implement it. This doc is the scoping
artefact so the next iteration's design starts from a known
baseline rather than diverging in review.

## Constraints we keep

  * **Wire-stable UDS protocol.** `start_session` already takes
    `provider: str`. Adding new providers can't break existing
    callers (macOS app, iPhone app).
  * **PTY semantics.** PtyTransport already supports any argv
    list. The "Claude-only" coupling lives in
    `ManagedSessionManager.startSession` where `provider ==
    "claude"` is the only branch.
  * **Approval ingress is provider-specific.** Claude has the
    PermissionRequest hook contract; Codex has its own hooks;
    shells don't have any. Multi-CLI cannot promise structured
    approval for every provider.

## Sketch — three tiers of provider support

### Tier 1: PTY-controllable, no structured approval

  * **Providers**: raw shell (`zsh`, `bash`), `python -i`, `node`,
    `psql`, `kubectl exec -it`.
  * **What works**: spawn, list, stop, send_input, output_delta
    streaming, the macOS app's "live PTY tail" preview.
  * **What doesn't**: hook_create_approval / structured Approve-
    Reject — these CLIs don't have a hook contract. The Sessions
    tab's approval UI stays hidden for tier-1 rows.
  * **Implementation cost**: low. `ManagedSessionManager` accepts
    an `argv` for arbitrary providers; macOS app's start sheet
    gets a "custom command" option.

### Tier 2: Provider-native hooks, ported individually

  * **Providers**: `claude` (Phase 4D, done), `codex`, `gemini`.
  * **What works**: everything tier 1 supports PLUS structured
    approvals via the provider's own hook contract.
  * **What doesn't**: the helper has to ship a per-provider
    `<provider>-approval-hook` subcommand AND adapter (mirrors
    `helper/provider_adapters/{claude,codex,...}.py`). Each new
    provider is a separate port — payload shape, decision
    schema, env-var contract differ.
  * **Implementation cost**: medium per provider. `HelperKit/
    HookAdapter.swift` already abstracts Claude's flow; a Codex
    adapter is ~150 LoC + tests.

### Tier 3: Background daemons / long-lived servers

  * **Providers**: dev server (`vite dev`), `tail -f`, `watchman`,
    arbitrary shell scripts.
  * **What works**: PTY tail in app preview; user can stop them
    from the Sessions tab.
  * **What doesn't**: no approval flow at all (these don't ask
    for permission). The Sessions tab treats them like tier 1
    rows with a "long-running task" badge.

## Wire changes (none required for tier 1; modest for tiers 2-3)

`start_session` already accepts `params.provider`. Tier 1 needs
two new optional params:

  * `argv: [string]` — full argv override when the provider is
    `"shell"` or `"custom"`. The current Claude-specific
    `["claude"]` argv is built server-side; tier-1 mode lets the
    caller supply the whole vector.
  * `cwd: string` — already in the protocol; tier-1 honours it
    verbatim.

Tier 2 needs no protocol changes — each new provider is a new
hook subcommand on the helper binary
(`<binary> <provider>-approval-hook --provider <name>`) that
mirrors the existing Claude path.

## Sequencing for v1.14+

1. **First slice — tier 1 shell**: `provider: "shell"` accepts an
   `argv` override. macOS UI adds a "Custom command..." option in
   the start sheet. Validates that argv[0] is on `$PATH`. Output
   tail works; no approval UI for these rows.
2. **Second slice — Codex CLI tier 2**: port Codex's hook contract
   following the Phase 4D HookAdapter template. Add a
   `provider_adapters/codex.py`-equivalent in Swift.
3. **Third slice — Gemini CLI tier 2**: same template again. By
   this point the adapter abstraction will have stabilised; doc
   the contract in `HelperKit/HookAdapter.swift` so future
   contributors can land tier-2 adapters in <1 day each.
4. **Fourth slice — tier 3 long-running tasks**: minor UI work
   (badge), no protocol change.

## Out of scope explicitly

  * Inter-session communication / piping (`session A | session B`).
  * Windows support (helper is POSIX PTY only).
  * iOS-spawned managed sessions (only macOS spawns; iPhone is
    read-only / approve-only via Supabase).
  * VSCode-style integrated terminal (different UX problem).

## Decision required from Jason before any of this lands

  * Greenlight tier-1 shell first, OR jump straight to tier-2
    Codex/Gemini ports?
  * Default argv allowlist or freeform? (allowlist = safer +
    less general; freeform = power user.)
  * Whether tier-2 adapter ports are upstreamed back to the
    Python helper for parity, or only Swift gets them. Phase
    4D's "two backends MUST NOT coexist" stance means **only
    Swift** by default.

This doc lives in `scripts/` because it's adjacent to the
Phase 4D infrastructure. v1.14 PR should cite this doc as its
scope baseline.
