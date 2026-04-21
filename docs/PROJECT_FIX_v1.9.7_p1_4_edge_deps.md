# PROJECT_FIX v1.9.7 — P1-4: edge function dep housekeeping

**Date**: 2026-04-21
**Scope**: `backend/supabase/functions/` only. No DB migration or client change.

---

## Why

Both edge functions imported `serve` from `deno.land/std@0.177.0/http/server.ts`
— Supabase's legacy template path. Supabase current templates use
`Deno.serve` directly. Staying on the old import risks future Deno runtime
compatibility issues and keeps a deprecated external dep in the critical path.

## What shipped

### `validate-receipt/index.ts`
- Removed `import { serve } from "https://deno.land/std@0.177.0/http/server.ts";`
- Replaced `serve(async (req) => { ... })` with `Deno.serve(async (req) => { ... })`
- Kept `@supabase/supabase-js@2` and `@apple/app-store-server-library@3`
  (see deferred items)

### `send-webhook/index.ts`
- Same `serve → Deno.serve` migration
- Kept `@supabase/supabase-js@2`

## Deferred (documented, not shipped)

1. **Pin `@supabase/supabase-js` to an exact minor/patch**
   Plan called for this but I'm not running a deploy sandbox in this
   session to bisect any breaking change. Ship later with real
   TestFlight + sandbox-receipt smoke.
2. **Pin `@apple/app-store-server-library@3` to an exact minor**
   Same reason.
3. **Fix pre-existing TS2345 at `validate-receipt/index.ts:277`**
   `rootCerts` is `ArrayBuffer[]` (Deno Web types) passed to a parameter
   typed `Buffer<ArrayBufferLike>[]` (Apple SDK's Node Buffer types).
   Works at runtime because Deno's Uint8Array.buffer satisfies the
   duck-typed shape Apple's verifier reads. Fix (likely a cast or
   `Buffer.from(…)`) is a separate type-tightening task.

## Verification

- `deno check backend/supabase/functions/send-webhook/index.ts` → clean
- `deno check backend/supabase/functions/validate-receipt/index.ts` →
  only the pre-existing TS2345 at line 277; not introduced by P1-4

Real deploy + sandbox receipt smoke is a pre-release gate, not a CI gate.

## Files changed

```
backend/supabase/functions/validate-receipt/index.ts   (import removed, Deno.serve)
backend/supabase/functions/send-webhook/index.ts       (import removed, Deno.serve)
docs/PROJECT_FIX_v1.9.7_p1_4_edge_deps.md              (this doc)
```

## Review audit trail

- **Codex rescue** — **ship-with-notes**. Confirmed `Deno.serve`
  migration matches current Supabase templates; deferring version
  pinning without a deploy sandbox is defensible; pre-existing
  TS2345 is out of scope.
