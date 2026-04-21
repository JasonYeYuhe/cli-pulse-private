# PROJECT_FIX v1.9.6a — P0 Backend Security Hotfix

**Date**: 2026-04-21
**Scope**: Supabase RPC hardening. No client UI changes; two client libraries updated in parallel.
**Plan ref**: `/Users/jason/.claude/plans/melodic-booping-truffle.md` (P0-1, P0-2, P0-4)
**Live migrations applied**: `v0_17_yield_score_security`, `v0_16_register_helper_hardening`, `v0_16_register_helper_hardening_v2`

---

## Executive Summary

Three critical Supabase RPC vulnerabilities closed:

| Fix | Vulnerability | Severity |
|---|---|---|
| P0-1 | `recompute_yield_scores_for_user(uuid)` accepted arbitrary UUID — any authenticated user could delete + recompute another user's yield scores | Critical (cross-user write) |
| P0-2 | `ingest_commits(jsonb)` had no batch cap — DoS via oversized payload triggering a full per-user recompute | High (DoS) |
| P0-4 | `register_helper(code, ...)` only incremented `failed_attempts` on the expiry branch; invalid/nonexistent-code guesses were unconstrained. No per-IP backstop | High (brute force) |

All three verified live against Supabase Tokyo (`gkjwsxotmwrgqsvfijzs`).

---

## P0-1 — `recompute_yield_scores_for_user` authorization check

### Before
```sql
CREATE OR REPLACE FUNCTION public.recompute_yield_scores_for_user(p_user_id UUID)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM public.yield_score_daily WHERE user_id = p_user_id;
  -- ... recompute ...
END;
$$;
```
Any authenticated user could pass a foreign UUID.

### After
```sql
IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
  RAISE EXCEPTION 'permission denied';
END IF;
```
`SECURITY DEFINER` preserves JWT context, so `auth.uid()` is the original caller. `ingest_commits` passes `auth.uid()` itself → legitimate internal calls remain no-op; foreign UUIDs are rejected.

### Files
- `backend/supabase/migrate_v0.14_yield_score.sql` (source of truth)
- Live: migration `v0_17_yield_score_security`

### Verification
```sql
SELECT count(*) FROM pg_proc
 WHERE proname = 'recompute_yield_scores_for_user'
   AND prosrc LIKE '%permission denied%';
-- → 1
```

---

## P0-2 — `ingest_commits` batch cap + client sharding

### Before
```sql
CREATE OR REPLACE FUNCTION public.ingest_commits(p_commits jsonb) ...
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  FOR v_commit IN SELECT * FROM jsonb_array_elements(p_commits) LOOP ...
```
No size limit. Each commit runs a CTE against sessions and finishes with a per-user `recompute_yield_scores_for_user`.

### After
```sql
IF jsonb_typeof(p_commits) <> 'array' THEN
  RAISE EXCEPTION 'p_commits must be a JSON array';
END IF;
IF jsonb_array_length(p_commits) > 500 THEN
  RAISE EXCEPTION 'batch_too_large';
END IF;
```

Client-side (`helper/cli_pulse_helper.py`) shards at 200/batch to leave headroom:
```python
BATCH = 200
payloads = [c.to_dict() for c in commits]
for i in range(0, len(payloads), BATCH):
    supabase_rpc("ingest_commits", {"p_commits": payloads[i:i + BATCH]})
```

### Review notes (Codex)
- Partial-failure safe: `ON CONFLICT DO NOTHING` makes retries idempotent; final `recompute_yield_scores_for_user` guarantees consistency.
- Empty arrays pass but hit zero-iteration loop — harmless.
- Recompute amplification: 1000 commits = 5 recomputes. Acceptable at P0; can tune BATCH upward if needed.

### Files
- `backend/supabase/migrate_v0.14_yield_score.sql`
- `helper/cli_pulse_helper.py` (`sync` function)
- Live: migration `v0_17_yield_score_security`

---

## P0-4 — `register_helper` brute-force hardening (two attempts)

### Before
```sql
if v_user_id is null then
  raise exception 'Invalid pairing code';   -- ← no failed_attempts bump
end if;
```
Both the invalid-code branch and the expiry branch used `RAISE EXCEPTION`. In Postgres, RAISE rolls back the enclosing statement — so even the `failed_attempts = failed_attempts + 1` on the expiry branch never persisted. The per-code counter was dead code.

### First attempt (v1 — flawed)
Added per-IP rate limit via `current_setting('request.headers', true)::jsonb->>'cf-connecting-ip'`, a `pairing_attempt_log` table, and a per-IP 10/min window. But kept `RAISE EXCEPTION` on failure paths → same rollback bug (Codex caught this).

### Final (v2 — applied)
**Design change**: all expected failure paths `RETURN jsonb_build_object('error', <code>, ...)` instead of raising. This preserves writes made earlier in the same call (log insert, counter bump).

```sql
-- New table: bounded by opportunistic prune (< 1 hr of rows)
CREATE TABLE public.pairing_attempt_log (
  id BIGSERIAL PRIMARY KEY,
  ip_addr TEXT,
  attempted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX pairing_attempt_log_ip_time_idx ON ... (ip_addr, attempted_at DESC);
CREATE INDEX pairing_attempt_log_time_idx ON ... (attempted_at);

-- In register_helper:
IF v_ip IS NOT NULL THEN
  PERFORM pg_advisory_xact_lock(hashtext(v_ip)::bigint);   -- closes TOCTOU
END IF;

DELETE FROM pairing_attempt_log WHERE attempted_at < now() - interval '1 hour';
INSERT INTO pairing_attempt_log (ip_addr) VALUES (v_ip);  -- before the count

IF v_ip IS NOT NULL THEN
  SELECT count(*) INTO v_ip_attempt_count FROM pairing_attempt_log
  WHERE ip_addr = v_ip AND attempted_at > now() - interval '1 minute';
  IF v_ip_attempt_count > 10 THEN
    RETURN jsonb_build_object('error', 'rate_limited', 'message', '...');
  END IF;
END IF;

-- Invalid code: counter bump persists because we RETURN
UPDATE pairing_codes SET failed_attempts = failed_attempts + 1 WHERE code = p_pairing_code;
RETURN jsonb_build_object('error', 'invalid_code', 'message', '...');
```

### Contract change
Response shape:
- **success**: `{device_id, user_id, helper_secret}` (unchanged)
- **failure**: `{error: <code>, message: <text>}` with codes `rate_limited`, `invalid_code`, `too_many_failed_attempts`, `expired`

Clients updated to check `error` field before the success-field guard:
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/HelperAPIClient.swift` — new `HelperAPIError.pairingRejected(code, message)`
- `helper/cli_pulse_helper.py` (`pair` function) — raises `SyncError(message)` on `response.error`

### Live verification
```
$ for i in 1..12; do curl ... -d '{"p_pairing_code":"BOGUSi","p_device_name":"test"}'; done
attempts 1–10 → {"error": "invalid_code", ...}
attempts 11, 12 → {"error": "rate_limited", ...}
```
Post-test query confirmed 12 rows persisted in `pairing_attempt_log` with captured IP.

### Review (Codex, v2 pass)
Verdict **ship-with-notes**. Non-blocking caveats:
- HTTP 200 with JSON error body weakens status-code-based alerting (we have none in production yet; Sentry is queued for P2-8).
- `hashtext(v_ip)` collisions could serialize unrelated IPs under extreme load — contention, not a bypass.
- Direct DB callers with no `cf-connecting-ip` header fall back to per-code counter only — by design, documented.
- 10/min may be tight for office NAT / CGNAT; monitor support volume, bump to 20 if needed.

### Files
- `backend/supabase/migrate_v0.16_register_helper_hardening.sql` (new file, v2 content)
- `backend/supabase/helper_rpc.sql` (canonical source, in sync)
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/HelperAPIClient.swift`
- `helper/cli_pulse_helper.py` (`pair` function)
- Live: migrations `v0_16_register_helper_hardening` and `v0_16_register_helper_hardening_v2`

---

## Residual duplicates / cleanup verification

Searched for ghost references to the pre-fix behavior:

```
grep "p_user_id <> auth.uid" backend/supabase/     → 1 hit (the fix itself)
grep "batch_too_large" backend/supabase/           → 1 hit (the fix itself)
grep "failed_attempts" backend/supabase/           → expected hits only
grep "register_helper" helper/ CLI\ Pulse\ Bar/   → pair()+HelperAPIClient only
```

No stale call sites, no duplicate definitions. `migrate_v0.11.sql` still contains an older `register_helper` version but is a historical migration record, not used at runtime.

## Post-deploy monitoring

- No dashboards yet (Sentry integration is P2-8 in the plan). Watch Supabase logs for `rate_limited` rejections — elevated volume from shared-network IPs would motivate bumping the 10/min threshold.
- Pairing success should remain unchanged for legitimate users (first attempt after a fresh code generation is well within limits).

## Not included in this hotfix (separate PR, v1.9.6b)

- **P0-3**: `SECURITY DEFINER` `search_path` hardening (`migrate_v0.17`-level). Blast radius covers all RPCs → isolated release.
