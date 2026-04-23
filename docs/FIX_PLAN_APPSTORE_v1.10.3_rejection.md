# App Store v1.10.3 Rejection — Fix Plan (rev 2)

**Date**: 2026-04-23
**Rejection scope**: iOS (ID `de771e5b-5637-4ca9-8ff4-62bdeba5c0af`) + macOS (ID `22e32092-c228-4ae7-a928-5f8f895c8e1d`)
**Version reviewed**: 1.10.3 (build 36)
**Guideline cited**: 2.1(a) — App Completeness
**Reviewer feedback**:
- iOS: "an error message appears when user attempts to sign in with the demo account."
- macOS: "when we attempted to log in, your app displayed an error message and we were unable to access the app."

Revision history:
- rev 1 (initial) — proposed metadata-only for both platforms.
- rev 2 — **Codex review flagged that macOS first-launch funnels into an OTP-only onboarding wizard; demo mailbox cannot receive OTP, so macOS needs a binary fix.** Also tightened the root-cause wording per Codex's note on undocumented GoTrue internals.

---

## Root Cause

The ASC demo credentials `demo@clipulse.app / DemoReview2026!` no longer authenticate. Verified:

```
POST https://gkjwsxotmwrgqsvfijzs.supabase.co/auth/v1/token?grant_type=password
→ 400 {"error_code":"invalid_credentials","msg":"Invalid login credentials"}

POST https://gkjwsxotmwrgqsvfijzs.supabase.co/auth/v1/otp
→ 400 {"error_code":"email_address_invalid","msg":"Email address \"demo@clipulse.app\" is invalid"}
```

Admin-API lookup: user `2bbcf049-dd9f-4ec5-8162-52b157bdff4b` exists, provider `email`, not banned; `last_sign_in_at = 2026-04-15T05:51Z` (v1.8 review), `updated_at = 2026-04-17T13:24Z`. Something rewrote the row after the last working sign-in.

`clipulse.app` has no MX record — OTP delivery is impossible for this mailbox, so OTP is **not** a usable fallback.

The v1.8 fix used `UPDATE auth.users SET encrypted_password = crypt(...)` directly. That is not the supported path: Supabase documents admin-password reset via `PUT /auth/v1/admin/users/{id}` (changing the password also terminates existing sessions). We should use the supported API instead of hand-rolling SQL.

### macOS-specific blocker (found via Codex review)

Even with a working password, macOS first-launch cannot reach the password login. `MenuBarView.notConnectedView` ([MenuBarView.swift:73-83](CLI Pulse Bar/CLI Pulse Bar/MenuBarView.swift)) forces a fresh user into `OnboardingWizardView`, and Step 3 Sign In ([OnboardingWizardView.swift:205-276](CLI Pulse Bar/CLI Pulse Bar/OnboardingWizardView.swift)) only exposes **email → Send Code (OTP)**. There is no password field, no SIWA/Google/GitHub button, and no "skip to Settings" escape. The reviewer types `demo@clipulse.app`, hits "Send Code", and gets `email_address_invalid`.

iOS is unaffected by the onboarding blocker: `iOSLoginView.emailEntryView` ([iOSLoginView.swift:249-297](CLI Pulse Bar/CLI Pulse Bar iOS/iOSLoginView.swift)) already renders both fields and branches to `signInWithPassword` when the password field is non-empty.

---

## Fix

### Step 1 — Reset demo password via Admin API (supported path)
```bash
SERVICE_KEY='<service_role jwt>'
curl -X PUT 'https://gkjwsxotmwrgqsvfijzs.supabase.co/auth/v1/admin/users/2bbcf049-dd9f-4ec5-8162-52b157bdff4b' \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"password":"DemoReview2026!","email_confirm":true}'
```
Per Supabase docs, this also terminates existing sessions. Do not touch `identities` / `aal` / recovery tokens manually — the admin endpoint is the complete path.

### Step 2 — Smoke-test (must pass before any resubmission)
```bash
curl -X POST 'https://gkjwsxotmwrgqsvfijzs.supabase.co/auth/v1/token?grant_type=password' \
  -H 'Content-Type: application/json' -H "apikey: $ANON_KEY" \
  -d '{"email":"demo@clipulse.app","password":"DemoReview2026!"}'
# → expect HTTP 200 + access_token in JSON body
```

### Step 3 — iOS: attempt metadata-only reply first, ship matching binary as fallback
First attempt: reply to the iOS ASC thread stating that the demo-account password has been restored on the backend and asking the reviewer to re-test build 36. iOS binary already exposes password sign-in in the primary welcome flow ([iOSLoginView.swift:249-297](CLI Pulse Bar/CLI Pulse Bar iOS/iOSLoginView.swift)), so no binary bump is strictly required. The iOS rejection message explicitly offers the reply path ("reply to this message and let us know; you do not need to resubmit").

**Fallback**: if the reviewer insists on a new binary or macOS ships a new build (Step 4), bundle iOS in the same submission (build 37 with identical code; version stays 1.10.3 or bumps to 1.10.4 alongside macOS). Framing this as fallback, not guaranteed success — worst case we are one reply + one upload away.

### Step 4 — macOS: add password field to `OnboardingWizardView.signInStep`, ship a new build
Minimal patch to `CLI Pulse Bar/CLI Pulse Bar/OnboardingWizardView.swift`:

- Add `@State private var password = ""` alongside existing `email` / `otpCode`.
- In the `else` branch of `signInStep` at [OnboardingWizardView.swift:242-256](CLI Pulse Bar/CLI Pulse Bar/OnboardingWizardView.swift) (pre-OTP-sent state), render a `SecureField("Password (optional)", text: $password)` under the email `TextField`.
- Change the primary button label + action to match the iOS pattern in [iOSLoginView.swift:272-287](CLI Pulse Bar/CLI Pulse Bar iOS/iOSLoginView.swift):
  - if `password.isEmpty` → `await state.sendOTP(email: email)` (existing OTP path preserved, pure addition)
  - else → `await state.signInWithPassword(email: email, password: password)`
  - button label switches between "Send Code" and "Sign In".
- Reset `password = ""` in the `onChange(of: state.otpSent)` or in the "Back to email" handler (matches iOSLoginView's reset logic).
- No other wizard steps change. Reuse `L10n.auth.passwordOptional` / `L10n.auth.passwordPlaceholder` / `L10n.settings.signIn` (already in the localization bundle, used by iOS).
- On post-OTP-sent success the existing `authState.isAuthenticated` change still drives `step = 4` via the existing wizard progression, so no navigation plumbing.

**Version bump (correct commands)**: `sync-versions.sh` only accepts `--dry-run` / no-args and is a cross-platform automation for scheduled releases — wrong tool (it auto-commits, pushes, and touches Android). Use `xcrun agvtool`:

```bash
cd "/Users/jason/Documents/cli pulse/CLI Pulse Bar"
# Bump build 36 → 37 across the full project. Verified via Codex:
# `agvtool -all 37` updates CURRENT_PROJECT_VERSION on all 5 native
# targets (macOS "CLI Pulse Bar", iOS, Watch, Widgets, Helper) across
# Debug + Release — 10 pbxproj entries. Keep MARKETING_VERSION at 1.10.3;
# App Store accepts a new build under the same marketing version.
xcrun agvtool -noscm new-version -all 37
```

Because `agvtool -all` bumps iOS's build number anyway, the simplest shipping strategy is to **build + upload both platforms together** (absorbs the Step-3 fallback into the main path, and removes the wait-for-reply roulette):

```bash
./scripts/build-appstore.sh all --upload
```

This uploads both iOS build 37 and macOS build 37 to ASC. Submit both with the reviewer notes from Step 5. iOS now ships a fresh binary, which is strictly safer than the reply-and-wait route and costs only one extra TestFlight processing cycle.

### Step 5 — ASC reviewer notes (one tested path per platform, no advertising broken paths)

**iOS**:
```
Demo account:
  demo@clipulse.app / DemoReview2026!

Sign-in path: on the welcome screen, fill BOTH the email and
password fields, then tap "Sign In". (Password sign-in only.)
```

**macOS** (build 37):
```
Demo account:
  demo@clipulse.app / DemoReview2026!

Sign-in path: during the first-launch onboarding wizard,
at the "Sign In" step, fill BOTH the email and password
fields, then tap "Sign In". (Password sign-in only.)
```

### Step 6 — Archive + checklist
- After acceptance, rename this doc to `docs/PROJECT_FIX_APPSTORE_v1.10.3_rejection.md` (per the `feedback_fix_archiving` project rule).
- Add a release-gate item to `RELEASE_WORKFLOW.md`: run Step 1 + Step 2 (admin reset + password-grant smoke test) as a pre-submission check on every App Store build, so this regression cannot recur silently.

---

## Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| Admin-API reset fails to stick again | Low | Step 2 smoke test is a hard gate; re-run before each submission per new checklist. |
| macOS onboarding change regresses OTP path for existing users | Low | Change is purely additive — when password field is empty the code falls through to the existing `sendOTP` call. |
| iOS metadata-only rejected by Apple | Low | ASC message explicitly offers "reply and we'll re-test". If rejected, fall through to shipping iOS build 37 alongside macOS. |
| Hidden error from v1.10.3 Sentry init (Codex asked) | Very low | Confirmed: `SentryLogger.start` ([SentryLogger.swift:21-56](CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/SentryLogger.swift)) configures the SDK only; visible login errors come from `state.lastError` populated in `AuthManager` catch blocks ([AuthManager.swift:169-180](CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AuthManager.swift)). Root cause is the Supabase password, not Sentry. |

## Files Touched

- `CLI Pulse Bar/CLI Pulse Bar/OnboardingWizardView.swift` — add password `SecureField` + conditional sign-in action in Step 3.
- macOS Xcode project version/build bump via `scripts/sync-versions.sh` (1.10.3 → 1.10.4, build 36 → 37).
- `docs/FIX_PLAN_APPSTORE_v1.10.3_rejection.md` (this file).
- `RELEASE_WORKFLOW.md` — add demo-password pre-submission check.
- No backend / SQL migration files; reset is a one-shot admin-API call, not a repo change.
