# Fix Archive: macOS App Store Rejection v1.8

**Date**: 2026-04-16  
**Build**: 1.8 (27) — resubmitted from rejected build 26  
**Submission ID**: 86491f50-6c61-44ee-beb2-6bcbe5619270

---

## Issues Fixed

### 1. Guideline 2.1 — Demo Account Login
**Problem**: macOS login UI only had OTP (email code), no password field. Reviewer couldn't use demo@clipulse.app / <DEMO_PW_REDACTED>  
**Fix**: Added password sign-in toggle to `SettingsTab.loginSection` + reset demo password in Supabase  
**Files**: `CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift`  
**Supabase**: `UPDATE auth.users SET encrypted_password = crypt('<DEMO_PW_REDACTED>', gen_salt('bf')) WHERE email = 'demo@clipulse.app'`

### 2. Guideline 2.1(b) — IAP Not Locatable
**Problem**: IAP only accessible via separate window behind "Upgrade to Pro" button — not discoverable  
**Fix**: Added inline IAP product cards (Pro Monthly/Yearly, Team Monthly/Yearly) with prices and purchase buttons directly in Settings subscription section. Added loading/empty/retry states.  
**Files**: `CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift` (added `inlineIAPCards`, `inlineProductRow`)

### 3. Guideline 2.1(a) — Teams Error
**Problem**: `myTeams()` used REST join query returning nested response that didn't match flat `TeamDTO`. Also loaded for free-tier users causing API errors.  
**Root cause**: REST query `team_members?select=...teams(...)` returned nested JSON but decoded as flat `[TeamDTO]`  
**Fix**:  
- Created Supabase RPC `my_teams()` returning properly shaped flat data  
- Updated `APIClient.myTeams()` to use new RPC  
- Added `rpcRaw()` helper for jsonb-returning functions  
- Guarded `.task { loadTeams() }` behind `isProOrAbove` check  
- Changed error messages to user-friendly text  
**Files**: `APIClient.swift`, `TeamView.swift`  
**Migration**: `add_my_teams_rpc`

### 4. Guideline 5.1.1(v) — Account Deletion Missing
**Problem**: No UI for account deletion despite backend support existing  
**Fix**:  
- Added "Delete Account" button to danger zone in Settings  
- Two-step confirmation: alert with consequences → type "DELETE" to confirm  
- Updated Supabase `delete_user_account()` to cascade via profiles deletion + remove `auth.users` record  
**Files**: `CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift`  
**Migration**: `fix_delete_user_account_cascade`

---

## Supabase Migrations Applied
1. `add_my_teams_rpc` — `my_teams()` SECURITY DEFINER function
2. `fix_delete_user_account_cascade` — simplified `delete_user_account()` with auth.users cleanup

## Verification
- Debug build: **SUCCEEDED**
- Archive build 27: **SUCCEEDED**
- Upload to ASC: **SUCCEEDED**
- Resubmitted: **Waiting for Review** (Apr 16, 2026)
