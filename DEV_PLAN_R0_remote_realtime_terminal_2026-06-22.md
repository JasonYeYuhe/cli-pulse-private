# DEV PLAN — R0: Secure Remote Realtime Terminal (phone → Mac session control) — 2026-06-22

**Goal (owner's chosen next phase):** let an iPhone drive the Mac's managed CLI
sessions (`claude` / `agy` / `codex`) over a **low-latency realtime stream**, and
do it **securely** — per-subscriber authorization so no one who guesses a session
UUID can eavesdrop on or inject into another user's terminal.

**Where we are:** local macOS session control is fully shipped (terminal 1:1,
auth injection, cwd, snapshot, reaper — helper 1.20.x). The REMOTE path has
session-list + command RPCs (gated, authz'd) but the **terminal output stream**
is unbuilt+insecure on the shipped helper. This phase closes that.

This plan operationalizes `~/.claude/plans/r0-realtime-auth-spec.md` (DESIGN-READY,
already dual-reviewed by Gemini 3.1 Pro + Codex 2026-05-30) + the durable rules in
[[feedback_realtime_authz_design]], against the **verified current code state**
below.

---

## 0. Verified current ground truth (2026-06-22, fresh map — supersedes the 23-day-old spec line numbers)

- **iOS/macOS subscriber** `RemoteSessionEventStream.swift`: joins `realtime:term:<uuid>`
  with **`private:false`** (~L173); WS URL carries the **anon key only**, the user's
  Supabase **access_token is NOT attached** (`APIClient.swift:56-64`
  `realtimeConfiguration()` returns only url+anonKey). Decodes `stdout`/`stderr`
  broadcast chunks; `tail_snapshot_result` handled in
  `RemoteTerminalViewRepresentable.swift:56`. **No `realtime_private` field decoded
  anywhere.**
- **Broadcast PRODUCER — the surprise:** the **shipped Python helper does NOT
  broadcast at all** (`helper/` has zero `/realtime/v1/api/broadcast` / `realtime.send`
  / `term:` refs; `_post_stdout_chunk` only writes the `remote_session_events` DB
  table via `remote_helper_post_event`). The producer exists **only in the UNSHIPPED
  Swift helper** (`HelperSwift/Sources/HelperKit/SupabaseRealtimeBroadcastSink.swift`
  + `TerminalBroadcastPublisher.swift`), which posts to
  `<url>/realtime/v1/api/broadcast` with the **anon key** as both `apikey` and
  `Authorization: Bearer` (no scoped token), redact-at-write via
  `TerminalBroadcastPublisher.submit → Redactor.redact` (L93). Wired in
  `HelperSwift .../main.swift:229-253` behind `isPaired && remoteRealtimeEnabled`.
- **No R0 anywhere:** no `realtime.messages` RLS policy (0 matches), no
  `realtime_private` column/setting, no `migrate_v0.56` file (the branch
  `backend/migrate-v0.56-r0-realtime-authz` exists but the file was never committed),
  no `mint-realtime-token` edge fn (existing fns: send-approval-push, send-webhook,
  send-widget-refresh, validate-receipt).
- **Backend** lives in `backend/supabase/migrate_v0.*.sql` (numbered migrations, not
  app_rpc.sql). `remote_app_request_session_start` (v0.45), `remote_app_list_sessions`
  (v0.39), `_remote_authenticate_helper_gated` (v0.27, SHA-256 + RC gate). Sequence
  has a real GAP at v0.56 (v0.55 → v0.57).
- **Gates:** `remote_control_enabled` (user_settings, server+client, the RC kill
  switch); `remote_realtime_enabled` (Swift-helper only, **defaults `true`** — must be
  forced OFF until R0 lands); no `realtime_private_enabled` yet.

---

## 1. The one architecture decision this phase forces: **Route A (build the producer in the Python helper)**

R0 secures a broadcast path — but on the **shipped** helper that path has **no
producer**. Two ways to give it one:

- **(A) Build the broadcast producer in the Python helper** — port the proven Swift
  `TerminalBroadcastPublisher` + `SupabaseRealtimeBroadcastSink` to Python (we have
  the reference impl), add the R0 scoped-token auth. Ships via the existing
  `build_helper_pkg.sh` pyinstaller `.pkg`. **CHOSEN** — consistent with the
  established Route A (every session-control train patched the Python helper; the
  Swift helper has unshipped baggage: empty-entitlements hang, label collisions,
  config drift).
- **(B) Ship the Swift helper** (already has the producer) — a full launchd/entitlement/
  pkg/notarize cutover of a never-shipped binary. **OUT OF SCOPE** (owner-gated Route B;
  see [[project_session_control]]).

So this phase's helper work = **new Python broadcast producer + R0 token auth**, with
the Swift files as the spec/reference (and kept in sync so Route B stays viable).

---

## 2. Security design (owner-approved Option B — dedicated R0 signing key)

From the spec + [[feedback_realtime_authz_design]] (both reviewers killed the v1
design; these are the corrected rules — do NOT regress them):

1. **Publish via direct HTTP `POST /realtime/v1/api/broadcast`, NEVER a Postgres
   RPC** (per-chunk PostgREST→plpgsql→`realtime.send` melts the pool).
2. **The helper can't mint a JWT in SQL** (`jwt_secret` not readable, no pgjwt). Mint
   via an **edge function**. This project verifies tokens via an **asymmetric ES256
   JWKS**, and Supabase won't export its GoTrue private key → we **register our OWN
   dedicated R0 keypair as a Supabase Third-Party Auth trusted issuer** (public JWKS),
   keep the private key as an edge-fn secret, sign short-lived (~1h) per-session tokens
   `{role:'authenticated', aud:'authenticated', sub:<owner auth.users.id>, exp}`.
   Isolated + independently revocable; additive (safe around ASC review).
3. **RLS on `realtime.messages` governs PRIVATE channels only**; public bypasses it.
   So policies are additive/safe even mid-release, and security only truly lands at
   the **cutover** that closes the public path.
4. **NEVER cast `realtime.topic()`** — compare a constructed string
   `'term:' || rs.id::text = realtime.topic()` (a `::uuid` cast throws 22P02 on a
   malformed topic → DoS).
5. **The auth-gate-done-right pattern:** `v_user := _remote_authenticate_helper_gated(...)`,
   then `if v_user is null then raise 42501`, then scope ownership by `v_user`. A bare
   `perform _remote_authenticate_helper_gated(...)` **discards the NULL → bypass.**
6. **Mode (private vs public) is decided ATOMICALLY at session-create**, not at
   helper-register (race). private/public mismatch = **silent blackhole**, so helper +
   both clients must agree per session.
7. **Helper-side validation** (event ∈ {stdout,stderr,tail_snapshot_result};
   payload.session_id == topic; size cap) — the direct-HTTP path can't enforce an
   event allowlist server-side, but cross-user **injection is closed by write-RLS
   ownership**, so helper-side shape validation on its OWN topic is sufficient.
8. **🔴 Private sessions use a DISTINCT topic prefix `pterm:<uuid>`, NOT `term:`
   (Gemini-3-Pro CRITICAL, 2026-06-22).** RLS on `realtime.messages` only governs
   PRIVATE joins; a public join to `term:<uuid>` ALWAYS bypasses RLS. So you cannot
   make a single topic "private-only" without a global dashboard change — an attacker
   could still join `term:<uuid>` publicly and eavesdrop even while the legit client
   joins privately. **Resolution:** when a session is `realtime_private`, the helper
   broadcasts to **`pterm:<uuid>`** and the client joins `pterm:<uuid>` with
   `private:true`; the RLS policies (read+write) match on `'pterm:'||rs.id::text`. The
   public path keeps using `term:<uuid>` for old clients. **Cutover = the helper simply
   stops emitting to `term:` and emits only to `pterm:`** — there is then NO public
   topic carrying the stream, so no public eavesdrop is possible. This is the concrete
   "close the public path" mechanism the rollout depends on.

---

## 3. Slices

### B1 — Backend foundation `migrate_v0.56` + edge fn `mint-realtime-token`  ⚠️ OWNER-GATED APPLY
Write everything; **do NOT apply the migration or deploy the edge fn or configure the
issuer** — that's the owner's call (backend schema + Supabase auth config + a new
signing key all fall under the autonomy "flag backend/schema" rule). The fresh session
delivers reviewed, tested-where-possible artifacts + an owner runbook.

`migrate_v0.56_realtime_terminal_authz.sql` (additive, inert until a client opts in):
1. `remote_sessions.realtime_private boolean not null default false`.
2. `user_settings.realtime_private_enabled boolean not null default false`.
3. **read** policy on `realtime.messages` (select, to authenticated) — owner-of-topic
   only, no-cast, matching the **private prefix**: `'pterm:'||rs.id::text = realtime.topic()`.
4. **write** policy on `realtime.messages` (insert, to authenticated) — mirror of read
   on `'pterm:'||...` (the minted token's `auth.uid()` = owner → passes only for owned
   topics). **B1 test MUST explicitly prove the broadcast HTTP API actually evaluates
   this insert policy** (Gemini MEDIUM: Supabase broadcast-API write permissions are
   historically finicky — a token with the wrong `aud`/`role`, or the `realtime` schema
   not API-exposed, can silently no-op or 200-without-delivery). Assert a non-owner
   token gets denied AND an owner token's message is actually delivered.
5. `remote_helper_authorize_broadcast(p_device_id, p_helper_secret, p_session_id)`
   SECURITY DEFINER — the gate-done-right (assign→check→scope), grant to anon.
6. **`pg_get_functiondef` FIRST**, then re-emit `remote_app_request_session_start`
   (set `realtime_private = user_settings.realtime_private_enabled` **in the same
   insert**) and `remote_app_list_sessions` (RETURN `realtime_private`) — preserving
   every existing prod semantic (the [[feedback_supabase_function_body_drift]] rule:
   prod bodies drift from repo .sql; dump live first).

Edge fn `supabase/functions/mint-realtime-token/index.ts`: body
`{device_id, helper_secret, session_id}` → `remote_helper_authorize_broadcast`
(service role) → on success sign a ~1h ES256 JWT with the dedicated R0 private key →
`{token, expires_at}`. 401/403 on gate failure.

**Tests:** pgTAP — read allows owner / denies non-owner + anon; authorize RPC rejects
bad secret / wrong device / non-owner; **malformed topic never errors** (22P02 guard).
Edge-fn unit test for the sign + the gate-reject paths.

**Owner runbook (the gated steps):** (a) generate the R0 ES256 keypair; (b) register
its public JWKS as a Supabase **Third-Party Auth trusted issuer** (`sub`=owner
`auth.users.id`, `role`→authenticated); (c) store the private key as the edge-fn
secret; (d) `pg_get_functiondef` the two live RPCs, hand back for the re-emit; (e)
apply `migrate_v0.56`; (f) deploy the edge fn. All additive + inert until a client
opts in.

### B2 — Python helper broadcast producer + R0 token auth (Route A)
New, mirroring the Swift reference (keep the Swift files in sync so Route B stays open):
- `helper/transports/realtime_broadcast.py` (or similar): a `TerminalBroadcastPublisher`
  equivalent — **output-coalesce ~50–80 ms**, bounded queue (drop-oldest, cap), and the
  redact-at-write seam (`redact()` BEFORE the bytes reach the sink — the existing
  `_post_stdout_chunk` raw path already produces redacted bytes; reuse it).
- A `SupabaseRealtimeBroadcastSink` equivalent: `POST <url>/realtime/v1/api/broadcast`
  with `apikey: anon` + `Authorization: Bearer <R0 token>`, body
  `{messages:[{topic:'pterm:<sid>', event, payload:{session_id, data_b64}}]}` (the
  **`pterm:` private prefix** per §2.8; the legacy public `term:` path is the Swift
  helper's anon behavior, not ported).
- **R0 token client:** call `mint-realtime-token` once per session, cache. **🔴
  PROACTIVELY refresh BEFORE expiry (e.g. at ~45 min for a 1 h token), NOT reactively
  on 401 (Gemini HIGH).** A reactive-only refresh drops the in-flight chunks during a
  burst → corrupted terminal. If a 401 still slips through, **requeue the failed
  chunks** (front of queue), don't drop them. Never log the token.
- **`flush()` on session teardown (Gemini, Route-A risk):** the port must flush the
  coalescing queue on session stop/exit so the final chunk (e.g. the last compiler line
  before the prompt returns) isn't lost — a classic coalescing-port bug.
- **Helper-side validation** (event allowlist, `payload.session_id == topic`, size cap).
- **Mode:** broadcast only when the session's `realtime_private` says private AND a new
  Python `remote_realtime_enabled` gate is ON (**add it to `HelperConfig`, default
  `False`** — opposite of the Swift default, since this is the live shipped helper and
  R0 must stay dark until cutover). When the gate is OFF, behave exactly as today (DB
  polling only) — zero regression.
- Wire it into the managed-session stdout drain alongside the existing
  `remote_session_events` write (the DB path stays as the old-client fallback).

**Tests (pytest):** token fetch/cache/refresh-on-401; sink POST shape; coalescing +
drop-oldest cap; validation rejects bad event/oversize/mismatched session_id; gate-OFF
= no broadcast (byte-identical to today). Run the full helper pytest suite (CI runs
ruff+pytest now — the "no helper-pytest CI" note is stale).

### B3 — Clients (iOS/macOS) subscribe-private  (dedicated compatibility PR)
- `RemoteSessionEventStream`: when the session is private, join **`pterm:<uuid>` with
  `private:true`** + **attach the user's Supabase access_token** to the Realtime WS +
  **re-send on token refresh** (Realtime caches policy decisions until a new token
  arrives). When not private, keep today's **`term:<uuid>` + `private:false`** public
  fallback (old/gated-off sessions).
- `APIClient.realtimeConfiguration()`: plumb the user JWT (today withheld).
- Decode `realtime_private` from `remote_app_list_sessions` (+ single-session fetch);
  pick the `pterm:`-private vs `term:`-public join from it; **rejoin if it changes**
  (mismatch = silent blackhole, so this must be exact).
- **Input keystrokes are UNCHANGED — they ride the existing authz'd command RPC
  (`remote_app_send_command` kind `input_raw`), NOT the broadcast channel** (Gemini Q3).
  R0 broadcast is OUTPUT-only (stdout/stderr/tail_snapshot_result). Confirm no input
  path leaks onto the realtime channel.
- **Tests:** join-payload shape (private + token); refresh re-send; public-fallback;
  decode default-false; mismatch-fails-closed. Full `swift test` (no `--filter` for any
  parse/model change — [[feedback_filtered_swift_test_blind_spot]]).

---

## 4. Rollout (honest — mechanism first, security at cutover; client-compat FIRST)

1. **B1 apply (owner)** — additive, inert; read by nobody until a client opts in. Safe
   anytime, even around ASC review.
2. **B3 ships FIRST and bakes (Gemini Q4 — reordered).** Ship the client compat
   (decode `realtime_private`, `pterm:`-private join + JWT, `term:`-public fallback)
   while the flag is still always-false everywhere. Let it reach the App Store + a
   measured install base BEFORE any helper ever broadcasts privately — otherwise an
   updated helper streaming to `pterm:` hits old apps still on `term:` → the silent
   blackhole. B3 is a pure-additive compat PR (no behavior change while the flag is off).
3. **B2 ships next** with the Python `remote_realtime_enabled` gate **default-OFF**.
   Even on, while `realtime_private_enabled=false` the session stays public `term:` —
   so B2 changes nothing for users until the per-user flag flips. **This delivers the
   MECHANISM, not the protection** — the public `term:` eavesdrop+inject hole stays open
   until cutover. Track as security debt.
4. **Forced cutover (later, owner-gated):** once R0-capable clients are measurably
   deployed, flip `realtime_private_enabled` on; sessions then create as
   `realtime_private=true` → helper emits ONLY to `pterm:` (never `term:`) and clients
   join `pterm:`-private. With no public topic carrying the stream, the eavesdrop hole
   is closed. Only then does R0 actually protect anything.

---

## 5. Build order (Gemini-revised — client compat FIRST)
1. **B1 SQL + edge fn + pgTAP** (write, don't apply) → hand owner the runbook + the two
   `pg_get_functiondef` dumps to fold. Policies match `pterm:`.
2. **B3 client subscribe-private** (`pterm:`-private + JWT + `term:`-public fallback;
   gate-OFF so always-public until the flag flips; full swift test) — **ship + let it
   bake first** so no helper ever streams `pterm:` to an app that can't join it.
3. **B2 Python producer + token auth** (gate-OFF; full pytest) — build/test against a
   local **mock broadcast endpoint** so the coalesce/refresh/requeue/flush/validation
   logic is CI-proven without the live backend (real end-to-end needs B1 applied + the
   issuer, which is owner-gated).
4. **Integration verify (owner-gated, the real security proof):** with B1 applied + the
   per-user flag ON on a test session, confirm iPhone joins `pterm:`-private, helper
   streams, and a **second account is DENIED** the topic. Design as explicit
   failure-injection — a non-owner token must get ZERO messages (not a silent pass) —
   AND verify the legacy `term:` topic carries nothing once cutover.

## 6. Test strategy & guardrails
- CI gate = `CLIPulseCore unit tests` + the helper pytest suite + (for SQL) pgTAP run
  locally against a branch DB. SwiftLint is warning-only (not a gate).
- **No backend APPLY, no edge-fn DEPLOY, no Supabase issuer config, no key generation by
  the agent** — all flagged for the owner (autonomy: backend schema + account-level +
  key material). The agent writes + tests + documents; the owner applies.
- Secrets: NEVER log the R0 token or the helper_secret. The R0 private key lives ONLY as
  an edge-fn secret (never in the repo; if a placeholder is needed, split-literal per
  [[feedback_github_secret_scanner]]).
- Sweep iCloud `" 2"/" 3"` dups before any Swift/helper build. Default-OFF gates
  preserved at every step. Keep the Swift broadcast files in sync with the new Python
  producer so Route B stays viable.
- Apply the recurring-bug grep: every `remote_helper_*` RPC must `assign→check→scope`
  the gate, never `perform` it.

## 7. EXPLICITLY OUT OF SCOPE (do not pull in)
- Swift-helper cutover (Route B) — architectural consolidation, owner-gated.
- Android realtime subscriber — separate platform train (clean slate, no subscriber yet).
- Any non-terminal realtime use; remote approvals/push (already shipped & separate).
- The forced public-path cutover itself (this phase delivers the mechanism gated-OFF).

## 8. Review record — RESOLVED by Gemini-3-Pro (2026-06-22, verdict GO-WITH-CHANGES)
Reviewed via the cloudcode-pa `generateContent` API (gemini-3-pro-preview). All findings
folded above:
1. **Route A (Python producer)** — CONFIRMED correct. Don't drag unshipped Swift
   launchd/entitlement baggage into a security patch; keep the risk footprint small.
   Added the `flush()`-on-teardown mitigation for the port (§3 B2).
2. **Dedicated-key issuer** — CONFIRMED over the edge-fn fallback. A serverless fn in the
   per-50ms-chunk hot path = cold-start latency + invocation cost; kills the feature's
   point. Direct-stream with the dedicated key it is.
3. **Coalescing 50–80 ms** — fine for OUTPUT; humans won't perceive the batching.
   Predicated on **input keystrokes staying on the command RPC, not broadcast** — pinned
   in §3 B3.
4. **Split the deploy** — ship **B3 client-compat first + bake**, THEN B2 helper
   (§4/§5 reordered) to avoid the updated-helper→old-app silent blackhole.
- 🔴 **CRITICAL caught:** "close the public path" was undefined and undoable for a single
  topic (public joins bypass RLS) → adopted the **`pterm:` distinct-private-prefix**
  mechanism (§2.8) threaded through B1/B2/B3/rollout.
- **HIGH:** reactive 401-only token refresh drops chunks → proactive pre-expiry refresh +
  requeue (§3 B2).
- **MEDIUM:** explicitly prove the broadcast HTTP API evaluates the write-RLS insert
  policy in B1 tests (§3 B1).

Plan is **GO-WITH-CHANGES → changes folded → ready for a fresh session.**
