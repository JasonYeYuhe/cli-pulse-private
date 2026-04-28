# Remote Approval Hook — Setup (private internal guide)

Wires Claude Code's `PermissionRequest` hook on a paired Mac so that
permission requests can be approved / denied from the user's iPhone or
another Mac via CLI Pulse.

> **Audience.** Internal dev and trusted-tester docs. Do not publish to
> the public website / marketing repo. CLI Pulse v1.11.0+ on iOS and
> macOS, helper paired, Supabase migrations v0.26 through v0.31 applied.

## Prerequisites

1. **Paired helper.** `~/.cli-pulse-helper.json` exists and is valid:
   ```bash
   python3 helper/cli_pulse_helper.py inspect | head -5
   ```
   The output should mention a `device_id` matching your Mac's row in
   `public.devices`. If not, run `pair` first per the main README.
2. **Remote Control toggle ON.** This is **opt-in and default OFF**.
   Open CLI Pulse → Settings → Privacy → toggle "Remote Control" on,
   read the consent dialog, click **Enable**. Mirror the toggle on iOS
   if you also want to approve from the phone.
3. **Server-side gate.** Backed by `user_settings.remote_control_enabled`
   on Supabase. Toggling the UI off severs the helper end of the channel
   (every `remote_helper_*` RPC raises `Device not found or unauthorized`),
   so the hook auto-falls-back to a local Claude prompt the user has to
   handle on the Mac.

## Wire the hook into Claude Code

Open `~/.claude/settings.json` (create if missing) and add a
`PermissionRequest` hook entry that pipes stdin into the helper:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "type": "command",
        "command": "python3 /absolute/path/to/cli pulse/helper/cli_pulse_helper.py remote-approval-hook --provider claude"
      }
    ]
  }
}
```

* `/absolute/path/to/cli pulse/` is wherever the cli-pulse-private repo
  lives on this Mac. Replace verbatim — Claude Code does not expand `~`
  inside `command`.
* If the helper is not on the system PATH, point at the python3 binary
  too (`/usr/bin/python3` or `/opt/homebrew/bin/python3`).
* The hook reads JSON from stdin and writes a single line of JSON to
  stdout. Logging goes to stderr; do **not** add `> /dev/null` or `2>&1`
  redirection to the command — the hook needs a clean stdout pipe.

After saving, restart Claude Code so it picks up the new hook entry.

## Hook flags worth knowing

The subcommand exposes three knobs (defaults are sensible — only change
when debugging):

| Flag                  | Default | Effect                                                |
| --------------------- | ------- | ----------------------------------------------------- |
| `--timeout`           | `10`    | Max seconds to wait for a remote decision.            |
| `--poll-interval`     | `1`     | Seconds between polls of `remote_helper_poll_permission_decision`. |
| `--allow-high-risk`   | OFF     | Off by default → high-risk shell commands (`rm -rf`, `sudo`, `curl`, …) fail-closed locally and never round-trip. ONLY set if you're explicitly testing the remote-approval flow for those. |

## What gets uploaded

Every time the hook fires, Supabase receives:

* a redacted `summary` (e.g. `$ ls -la` or `Read hosts`, ≤ 256 chars)
* a redacted `tool_input` snapshot (sk-ant- / AIza / ghp / Bearer / JWT
  / long-hex tokens stripped to `«REDACTED»`, every string ≤ 1024)
* `risk` (`low` / `medium` / `high`)
* `cwd_basename` (last path component only) and an HMAC of the full path
  (HMAC key is the user-secret on the Mac, not the helper secret)
* `tool_name`, `provider`, `session_id` (when the helper has registered
  the session)

Never uploaded:

* Provider API keys, OAuth tokens, cookies (Keychain-only)
* Full transcripts or session log files
* Full project paths
* The original tool_input strings (only the redacted versions)

## States the user might see

| Scenario                                                    | What Claude shows                    |
| ----------------------------------------------------------- | ------------------------------------ |
| Remote Control OFF (and `pg_cron` retention scheduled)      | The hook silently raises 'unauthorized' inside Supabase, the helper catches and emits `behavior: deny` with a message asking to disable Remote Control if the issue persists; the user then re-runs and the local Claude prompt fires. |
| Remote Control ON, helper paired, network up                | Pending request appears on iPhone / Mac sheet within seconds. Approve → `behavior: allow`. Deny → `behavior: deny` + message. |
| High-risk shell command (`rm -rf`, `sudo`, …)               | Hook short-circuits to local prompt without ever uploading. (Set `--allow-high-risk` to override; not recommended.) |
| Helper crash / network blip / poll timeout                  | Hardcoded fallback `behavior: deny` with explainer message. User reruns. |

## Verifying the loop end-to-end

1. Open CLI Pulse on iPhone with Remote Control on.
2. On the Mac, run a Claude Code command that needs permission, e.g.:
   ```
   claude "show me the contents of /etc/hosts"
   ```
3. iPhone Overview tab should show a "1 pending approval" banner within
   ~2 seconds. Tap → Approve.
4. Claude on the Mac proceeds with the tool call.
5. (Optional) `select * from public.remote_permission_requests order by
   created_at desc limit 1;` from Supabase Dashboard should show a row
   with `status='approved'`, `decision_at=<just now>`, and a redacted
   `summary`/`payload`.

## Disabling

Either:

* Toggle Remote Control off in CLI Pulse (Mac or iOS — they're the same
  server-side flag). Helper hook will start emitting deny+fallback.
* Remove the `PermissionRequest` block from `~/.claude/settings.json`.

Both are safe; the first is reversible without restarting Claude Code.

## Phase 1 limits (intentional)

* No Always-Allow / persistent-rule remote shape — Approve is `once`
  per request.
* No Codex support yet (adapter is a stub; raises on first invocation
  and the hook's defensive wrapper translates it to a local-prompt deny).
* No PTY managed session, no remote prompt-sending, no remote stop /
  interrupt of running tools.
* Polling is refresh-based — no push notifications.

These are tracked in `PROJECT_DEV_PLAN_2026-04-29_remote_agent_sessions.md`
for Phase 2 follow-up.
