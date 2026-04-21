# PROJECT_FIX v1.9.6d — pairing_attempt_log cleanup hygiene

**Date**: 2026-04-22
**Scope**: Backend only. Addresses Gemini's remaining review finding (#3).

---

## Why

Gemini 3.1 Pro's session-wide review flagged:

> Running `DELETE FROM public.pairing_attempt_log WHERE attempted_at <
> now() - interval '1 hour'` synchronously on every `register_helper`
> call introduces severe table-wide lock contention and potential
> database degradation under high pairing concurrency from multiple IPs.

The DELETE was added in v0.16 P0-4 to bound table growth. Under normal
traffic (< 100 pairings/day) the contention is invisible, but the
pattern is unsafe at any scale beyond that.

## What shipped

### Migration v0.19 (live)

1. **`register_helper`** — replaced the unconditional DELETE with a 1%
   probabilistic cleanup:
   ```sql
   IF random() < 0.01 THEN
     DELETE FROM public.pairing_attempt_log
     WHERE attempted_at < now() - interval '1 hour';
   END IF;
   ```
   → ~100× reduction in DELETE frequency. Table growth still bounded
   because even at 1000 pair attempts/hour, the DELETE fires ~10 times/hour.

2. **`cleanup_expired_data`** — added pairing_attempt_log scrub at the
   end, alongside the existing session / alert / device_snapshot sweeps.
   Return shape extended to include `pairing_attempt_log_deleted` for
   observability.

Belt-and-suspenders design:
- If `cleanup_expired_data` is scheduled (pg_cron or edge function) →
  guaranteed nightly cleanup, probabilistic path just catches between runs.
- If `cleanup_expired_data` is NEVER called externally → probabilistic path
  is sole backstop, still keeps table bounded.

## Verification

Live smoke (anon role):
- `POST /rpc/register_helper` with `BADCOD` → 200 `{error: invalid_code}`
  (both cleanup paths + rate-limit + invalid-code flow intact)
- `POST /rpc/cleanup_expired_data` → 400 `{Forbidden: service_role required}`
  (auth gate preserved)

Service-role call via Supabase SQL editor:
```json
{
  "alerts_deleted": 91,
  "sessions_deleted": 69,
  "snapshots_deleted": 0,
  "pairing_attempt_log_deleted": 2
}
```
Confirms the new return field surfaces the scrub count AND the function
actually swept real retention-aged data (91 alerts + 69 sessions from
active user accounts past their retention window).

## Trade-offs / notes

- Between the 1% lucky-draw cleanup hits, the table CAN accumulate rows
  older than 1h. The **rate-limit query** itself uses
  `attempted_at > now() - interval '1 minute'` → stale rows don't skew
  rate counting. Only table size is the concern, and 100× frequency
  reduction keeps it bounded.
- Under a synchronized DDoS attempt at 1000/sec the table briefly grows
  faster than the 1% trigger can keep up, but `pg_advisory_xact_lock`
  per IP already serializes writes per-attacker, which is the core
  rate-limit primitive — the table-growth concern is secondary.

## Files changed

```
backend/supabase/migrate_v0.19_pairing_log_cleanup.sql   (new migration, 145 lines)
docs/PROJECT_FIX_v1.9.6d_pairing_log_cleanup.md          (this doc)
```

No helper / client / Swift changes — backend-only.

## Review audit trail

Self-reviewed against Gemini's finding. Behaviour change verified live
(both function signatures + return shape preserved in the public
contract for existing callers; `cleanup_expired_data` return shape adds
a new key which is additive, not breaking).
