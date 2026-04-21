# PROJECT_FIX v1.9.7 — P1-2: helper structured logging + ingest retry

**Date**: 2026-04-21
**Scope**: `helper/` only (Python CLI daemon).

---

## Why

Per plan P1-2:
- `helper/cli_pulse_helper.py` had 9 raw `print()` calls — unstructured and
  hard to filter in production
- `ingest_commits` failures were logged but advanced `last_scanned_projects`
  regardless, silently dropping commit batches on network blips

## What shipped

### Structured logging
- Added `import logging`, module logger `cli_pulse.helper`
- New `_configure_logging()` in `main()`:
  - Reads `CLI_PULSE_LOG_LEVEL` env var (default INFO)
  - Idempotent — skips if a root handler is already installed (pytest, etc.)
- Replaced 9 raw `print(...)` with `logger.info/warning/error/debug`
- **Kept** 2 intentional `print(...)` calls:
  - `pair()` success message (user-facing CLI confirmation)
  - `inspect()` JSON output (scripting contract — stdout JSON)

### Retry with exponential backoff
- New `_ingest_commits_with_retry(payloads, batch_size=200, backoffs, sleep_fn)`
  - Semantics: `len(backoffs)` retries + 1 initial attempt = up to N+1 tries
  - Default `INGEST_RETRY_BACKOFFS = (1.0, 3.0, 9.0)` → 4 attempts, ~13s
    worst-case before giving up (well under 120s default daemon cycle)
  - Raises the last `SyncError` when exhausted — caller decides consequences
- Daemon call site (`daemon()` loop):
  - On success: update `last_scanned_projects` and `last_scan_at`
  - On exhaustion: log error, set `ingest_ok=False`, **skip the cursor
    update** so the same project set is re-attempted next cycle
  - This is the key data-integrity guarantee: no silent commit drops

### Tests
- New `helper/test_helper_retry.py` — 5 tests with mocked `supabase_rpc`:
  1. single batch, first-attempt success → 1 RPC, 0 sleeps
  2. sharding (7 commits / batch 3) → 3 chunks of [3, 3, 1]
  3. flaky: succeeds on attempt 3 → sleeps `[0.1, 0.2]`
  4. exhaust: always fail → 4 attempts, 3 sleeps, raises
  5. partial: 1st batch OK + 2nd always fails → 5 RPCs total, raises

`pytest -q` → 50 passed (45 previous + 5 new). `ruff check .` → clean.

## Follow-ups (non-blocking)

1. Consider a shorter / jittered backoff if users report cycle skew
2. Align logger naming across helper modules (`"cli_pulse.helper"` here
   vs `__name__` in `git_collector.py` vs `"cli_pulse.collector"` in
   `system_collector.py`) — cosmetic

## Files changed

```
helper/cli_pulse_helper.py                                        (logger + retry + 9 print → log)
helper/test_helper_retry.py                                       (new, 5 tests)
docs/PROJECT_FIX_v1.9.7_p1_2_helper_logging_retry.md              (this doc)
```

## Review audit trail

- **Codex rescue** — **ship-with-notes**. No blocking bugs. Retry semantics
  exercised across all paths (first-pass success, sharding, eventual
  success, exhaustion, partial batch failure). Backoff schedule and
  cursor-skip behavior are internally coherent with the stated retry
  intent.
