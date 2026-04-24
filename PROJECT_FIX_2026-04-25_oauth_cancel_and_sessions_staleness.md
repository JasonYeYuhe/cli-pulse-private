# CLI Pulse Fix Archive — 2026-04-25

Two fixes landed together from the same reporter/session:

1. iOS Google/GitHub OAuth cancel redirected the user to the public
   GitHub Pages site (main fix below).
2. `public.sessions` was not receiving fresh data — the macOS helper
   daemon's scanner had stopped detecting node-based AI CLIs after an
   earlier libproc migration. Addendum further down.

---

## Google OAuth cancel redirects user to public GitHub Pages

> Reporter: Jason (user)
> Platforms affected: iOS (App Store build). Android appears unaffected by
> observation (it has its own deep-link handler and a `clipulse://` fallback
> intent-filter); Android was NOT re-verified in this task.
> Git state: uncommitted. No commit, no push, no ASC upload.

---

## Symptom

In the iOS app, tapping **Sign in with Google** opens an
`ASWebAuthenticationSession` pointed at the Supabase OAuth URL. The user
consents at Google, or — the bug case — **declines / cancels at the Google
consent screen**. Instead of returning to the app with a "Sign-in cancelled"
state, the in-app Safari view navigates to the public CLI Pulse marketing page
at `https://jasonyeyuhe.github.io/cli-pulse` and strands the user there. The
session never fires its completion handler, so the app never learns the flow
ended.

Same behavior for GitHub OAuth on cancel.

---

## Root cause

Two things combined:

1. **Supabase Auth `site_url` was set to the public marketing page**, i.e.
   `https://jasonyeyuhe.github.io/cli-pulse`. When a user denies consent at
   Google, Google redirects to Supabase's `/auth/v1/callback` with
   `error=access_denied`. Supabase GoTrue, on the error path, **falls back to
   `site_url`** (it does NOT reliably reuse `redirect_to` on error, even when
   `redirect_to` is in `uri_allow_list`). Supabase therefore redirected the
   user to the GitHub Pages marketing URL.

2. **`ASWebAuthenticationSession` on iOS can only intercept a custom URL
   scheme** (here `clipulse`). An HTTPS redirect to `jasonyeyuhe.github.io`
   cannot be intercepted without a Universal Link setup
   (apple-app-site-association + Associated Domains entitlement), which the
   iOS target does not have. So the session just kept navigating, and the
   marketing HTML rendered inside the web-auth sheet.

Verified via Supabase Management API (`/v1/projects/{ref}/config/auth`):

    site_url        = https://jasonyeyuhe.github.io/cli-pulse   ← BAD
    uri_allow_list  = clipulse://auth/callback

Relevant iOS call sites (worktree paths):

- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AuthManager.swift:243`
  — builds `redirect_to = "clipulse://auth/callback"`
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/APIClient.swift:919`
  — `oauthAuthorizeURL(provider:redirectTo:)` constructs the Supabase
  `/auth/v1/authorize` URL
- `CLI Pulse Bar/CLI Pulse Bar iOS/iOSLoginView.swift:182`
  — `signInWithProvider` → `ASWebAuthenticationSession` with
  `callbackURLScheme: "clipulse"`

---

## Fix

### 1. Supabase config (applied live via Management API)

Changed `site_url` from the public GitHub Pages URL to
`clipulse://auth/callback`:

    PATCH https://api.supabase.com/v1/projects/gkjwsxotmwrgqsvfijzs/config/auth
    { "site_url": "clipulse://auth/callback" }

Post-change state:

    site_url        = clipulse://auth/callback
    uri_allow_list  = clipulse://auth/callback

Why this is safe for current auth flows:

- Signup uses `mailer_autoconfirm: true` — no confirmation email with a
  SiteURL-derived link is sent.
- Email OTP template uses `{{ .Token }}` (the 6-digit code), not `{{ .SiteURL }}`.
- The app does not trigger Supabase password-reset or email-change flows.
- Team invites use a custom RPC (`invite_member`), not Supabase's built-in
  invite mailer.

Now, on Google/GitHub cancel, Supabase redirects the user agent to
`clipulse://auth/callback?error=access_denied&...`. iOS
`ASWebAuthenticationSession` intercepts the custom scheme, closes the session,
and the completion handler runs with the error URL — which is exactly the path
the app already handles.

### 2. iOS code hardening (uncommitted)

Extracted the callback URL parsing out of `iOSLoginView.swift` into a pure,
testable helper in `CLIPulseCore`, and taught it to treat
`error=access_denied` (in query OR fragment) as a first-class **cancelled**
outcome instead of a generic failure. Previously the code built a string like
`"OAuth sign-in failed: access_denied"` — correct but user-hostile.

New public API:

    // CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/OAuthCallbackParser.swift
    public enum OAuthCallbackResult: Equatable {
        case success(code: String, state: String)
        case cancelled
        case failed(description: String)
    }
    public enum OAuthCallbackParser {
        public static func parse(url: URL) -> OAuthCallbackResult
    }

`iOSLoginView.swift` now switches on the result and shows a localized
`L10n.auth.signInCancelled` toast on cancel.

### 3. Localization (5 locales)

Added `auth.sign_in_cancelled` to `L10n.auth` and all 5 `.strings` files:

| Locale    | String                              |
|-----------|-------------------------------------|
| en        | Sign-in cancelled                   |
| zh-Hans   | 已取消登录                          |
| ja        | サインインをキャンセルしました      |
| ko        | 로그인이 취소되었습니다             |
| es        | Inicio de sesión cancelado          |

---

## Files changed

### Modified

| File | Change |
|------|--------|
| `CLI Pulse Bar/CLI Pulse Bar iOS/iOSLoginView.swift` | Replace inline URL-parsing with `OAuthCallbackParser.parse(url:)`; surface `L10n.auth.signInCancelled` on `.cancelled` |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/L10n.swift` | Add `L10n.auth.signInCancelled` |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources/*.lproj/Localizable.strings` (5 files) | Add `auth.sign_in_cancelled` translation |

### Added

| File | Purpose |
|------|---------|
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/OAuthCallbackParser.swift` | Pure helper — parse Supabase callback URL into success/cancelled/failed |
| `CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/OAuthCallbackParserTests.swift` | 6 unit tests covering happy path (query + fragment), cancel (query + fragment), generic failure, unknown fallback |

### Infrastructure (NOT in git)

- Supabase project `gkjwsxotmwrgqsvfijzs`: `site_url` updated via Management
  API. This is a runtime config change, not code; it took effect immediately.

---

## Verification

### Automated

- `swift test --package-path "CLI Pulse Bar/CLIPulseCore"`
  → **455 tests, 0 failures, 1 skipped** (the 6 new `OAuthCallbackParserTests`
  included).
- `xcodebuild -scheme "CLI Pulse iOS" -configuration Debug build` (no
  code-sign) → **BUILD SUCCEEDED**.

### Manual (to run on a physical iPhone before next App Store submission)

1. Tap **Sign in with Google**. On the Google account picker, pick an account.
2. On the Google consent screen, tap **Cancel** (or **Deny**).
   - **Expected**: `ASWebAuthenticationSession` dismisses, iOS returns to the
     CLI Pulse login screen, a red-text error reads "Sign-in cancelled" (or
     localized equivalent).
   - **Previous behavior**: web-auth sheet navigated to
     `jasonyeyuhe.github.io/cli-pulse` marketing page and stayed there until
     the user tapped the sheet's Cancel button.
3. Repeat with GitHub OAuth — should behave identically.
4. Repeat the happy path with Google: consent → session closes → app receives
   `code` + `state` → session restored. Should work unchanged.
5. Run email OTP flow on a test account — confirm the 6-digit code email still
   arrives and verifyOTP still works (sanity check for the `site_url` change).

---

## Addendum: Sessions data staleness (`public.sessions` not updating)

After shipping the OAuth fix the reporter noticed a second symptom: the
**Sessions** tab on iOS was showing nothing fresh. Investigation:

Observed state (Supabase direct query, 2026-04-25):

    public.sessions    count=76     latest=2026-04-02    device=CLI Pulse Helper v0.1.0
    public.sessions    count=0      (no rows ever)       device=MacBook Pro v1.0.0
    public.devices     MacBook Pro  last_seen=2026-04-24 (heartbeat alive)
    public.provider_quotas           updated=2026-04-24 (main-app path still writing)

So the macOS helper daemon was alive and `helper_heartbeat` + quota sync
were working, but `helper_sync`'s `p_sessions` array was consistently
empty. Sessions only appeared on the old Python-based helper v0.1.0 which
stopped running on 2026-04-02.

### Root cause

`LocalScanner.listProcesses()` was migrated from `/bin/ps -ax -o command`
to libproc's `proc_pidpath` in an earlier fix (MAS sandbox issue).
`proc_pidpath` returns **only the executable path**, not argv — and most
modern AI CLIs launch as `node /path/to/tool.js`:

    argv[0]  = /usr/local/bin/node
    argv[1+] = /Users/…/claude-code/cli.js …

So the scanner saw only `node`, which matches no provider pattern. Every
scan returned 0 sessions, `helper_sync` upserted nothing, and the Ended-
sweep after 10 minutes even marked the last real running sessions as
Ended. Classic half-migration regression.

Verified against this machine's live process list via a throwaway Swift
script using `sysctl(KERN_PROCARGS2)`: Codex CLI, Claude Code, and a
node-broker for the OpenAI Codex plugin were all running under `node`
with the provider name only in argv, not in the executable path.

### Fix

`CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/LocalScanner.swift`:

- Added `LocalScanner.processArgs(pid:)`, a nonisolated helper that
  walks `sysctl(CTL_KERN, KERN_PROCARGS2, pid)` and returns
  `argv[0..argc-1]`. Handles the Darwin layout exactly (int32 argc →
  exec_path\0 → NUL padding → argv strings → envp). Decodes via
  `String(bytes:encoding: .utf8)` on a copied byte slice, so we never
  read past a slice boundary.
- `listProcesses()` now concatenates `proc_pidpath` + argv into the
  `ProcessRow.command` field, so the existing `detectProvider(_:)`
  regex table works on a ps-equivalent command string. Falls back to
  the path alone on sysctl failure (expected for other-user pids in
  sandbox).

No entitlement changes needed — `KERN_PROCARGS2` is allowed on
same-user processes in the default macOS sandbox, same policy level as
`proc_listallpids` / `proc_pidpath` which are already in use.

### Added tests

`LocalScannerTests.swift`:

- `testNodeLaunchedCodexMatches` — regression: the canonical "node
  running a codex script" command string now matches `Codex` at high
  confidence.
- `testNodeLaunchedClaudeCodeMatches` — same for `claude-code/cli.js`
  under a node prefix.
- `testProcessArgsForSelf` — runs `processArgs(pid: getpid())` against
  the test process itself to verify the sysctl walk decodes valid
  UTF-8 back out.

Full suite: **463 tests, 0 failures, 1 skipped** (was 455). macOS and
iOS Xcode builds still succeed.

### Manual verification

On a Mac where the helper daemon is installed and paired, after this
fix lands:

1. Run any node-based AI CLI (`claude`, `codex`, `gemini`). Leave it
   idle in a terminal.
2. Wait one helper sync interval (default 120s), or restart the helper
   to force an immediate sync.
3. Query `public.sessions` for your user_id — new rows should appear
   with `device_id = <MacBook Pro uuid>` and `synced_at` within the
   last few minutes.
4. On iOS, pull-to-refresh the Sessions tab — the live sessions should
   render.

### Not included in this fix

- Making the main macOS app (not just the helper daemon) also write
  `public.sessions` so that users without a paired helper still see
  fresh data. Considered, not done — keeps the write surface narrow.
  Tracked as a follow-up.
- Supabase-side cleanup of the 76 stale 2026-04-02 rows from the old
  Python helper. They'll naturally age out via the retention cron.

## Follow-ups (out of scope for this fix)

- iOS Universal Links: the Android target uses
  `https://clipulse.app/auth/callback` as its primary OAuth redirect via
  verified App Links. iOS could match this by adding
  `apple-app-site-association` on the `clipulse.app` domain + the
  `Associated Domains` entitlement to the `CLI Pulse iOS` target. This would
  let us drop the custom-scheme fallback on iOS too. Tracked as a non-urgent
  hardening follow-up.
- Android parity: today Android's `uri_allow_list` doesn't contain the HTTPS
  `clipulse.app` redirect it uses; it likely works only because the
  `clipulse://auth/callback` custom-scheme fallback is registered in its
  manifest. Worth re-auditing — but Android was NOT the reported bug and was
  NOT re-tested in this task.
