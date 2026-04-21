# PROJECT_FIX v1.9.6c — `ingest_commits` device-auth hotfix

**Date**: 2026-04-22
**Incident class**: pre-existing production bug surfaced by session-wide review
**Reviewers**: Gemini 3.1 Pro (caught it), Codex (verifying the fix)

---

## Why

During a session-wide review of the v1.10 refactor work, Gemini 3.1 Pro
flagged a critical bug that had nothing to do with the refactor itself:

> `ingest_commits(p_commits jsonb)` at `migrate_v0.14_yield_score.sql`
> requires `auth.uid() IS NOT NULL`, but the Python helper daemon
> authenticates to Supabase with the anon key. Consequently, `auth.uid()`
> evaluates to NULL on the server and the helper's commit submission
> permanently fails with "Not authenticated".

I verified live:

```
$ curl -s -X POST .../rpc/ingest_commits \
      -H "Authorization: Bearer <anon key>" \
      -d '{"p_commits":[]}'
{"code":"P0001","message":"Not authenticated"}  → HTTP 400
```

**Blast radius**: every user who enabled `track_git_activity` has been
getting git-sync failures on every helper cycle since v0.14 shipped.
Default is opt-out, so this didn't manifest for most users, but it's a
real break for anyone using the Yield-Score feature.

## What shipped

### Migration `v0.18_ingest_commits_device_auth.sql` (live)

1. **New private helper** `_recompute_yield_scores_for_user_internal(p_user_id UUID)`
   - No auth check, `REVOKE ALL` from PUBLIC/authenticated/anon
   - Body is the pre-existing recompute SQL lifted verbatim
   - Callable only from other SECURITY DEFINER functions in the same database

2. **Public `recompute_yield_scores_for_user(p_user_id UUID)`** unchanged
   public signature — still user-JWT gated (`auth.uid() = p_user_id`), but
   now delegates to the internal helper. Keeps the original contract for
   any web/app caller.

3. **Dropped** `public.ingest_commits(jsonb)` — the broken 1-arg signature.

4. **New** `ingest_commits(p_device_id uuid, p_helper_secret text, p_commits jsonb)`:
   - Device-authenticates via
     `devices.helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex')`
     — identical pattern to `helper_sync` and `get_track_git_activity`
   - Keeps the 500-batch DoS cap
   - Ends with `PERFORM public._recompute_yield_scores_for_user_internal(v_user_id)`
   - `GRANT EXECUTE ... TO anon, authenticated`

### Helper client (`helper/cli_pulse_helper.py`)

- `_ingest_commits_with_retry(config, payloads, ...)` — new first param
  `config: HelperConfig`. Threads `p_device_id`, `p_helper_secret`,
  `p_commits` into the RPC.
- Daemon call site updated to pass `config`.

### Tests (`helper/test_helper_retry.py`)

- Added `_fake_config()` factory producing a `HelperConfig` with
  `device_id="dev-0000"` + `helper_secret="test-secret"`.
- All 5 retry tests updated; first test additionally asserts the RPC
  payload includes `p_device_id` and `p_helper_secret` (catches future
  accidental removal of the device-auth params).

## Verification

- `curl` with bad creds → HTTP 400 "Device not found or unauthorized" ✓
- `curl` with old 1-arg signature → HTTP 404 PGRST202 "Could not find function" ✓
- `pytest -q` in `helper/` → 50 passed
- `ruff check .` → clean

## What remains unfixed (documented, not blocking)

- **Gemini finding #3**: synchronous `DELETE FROM pairing_attempt_log WHERE
  attempted_at < now() - interval '1 hour'` inside `register_helper`. Lock
  contention concern under high concurrent pairing load. Not urgent at
  current user volumes (< 100 pairings/day); defer to a `pg_cron` cleanup
  task in a later migration.

## Files changed

```
backend/supabase/migrate_v0.18_ingest_commits_device_auth.sql   (new, 140 lines)
helper/cli_pulse_helper.py                                       (signature + call site update)
helper/test_helper_retry.py                                      (5 tests rewired for device auth)
docs/PROJECT_FIX_v1.9.6c_ingest_commits_device_auth.md           (this doc)
```

No Swift / iOS / Android changes — the bug was helper-only.

## Discovery credit

Gemini 3.1 Pro's `focused` review of the v1.10 session uncovered this
as a critical finding that every per-slice Codex review had missed (the
per-slice reviews were scoped to the slice-at-hand and didn't do a
session-wide audit of helper↔server auth contracts).

Worth remembering for future refactor sessions: a single
independent session-wide review can surface the auth-contract issues
that per-file reviews structurally can't.
