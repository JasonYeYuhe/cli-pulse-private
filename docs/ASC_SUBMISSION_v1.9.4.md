# App Store Connect submission — v1.9.4

**Date:** 2026-04-20
**Platforms:** macOS, iOS, watchOS
**Marketing version:** 1.9.4
**Build:** 31 (bumped from 30)

This is a handoff doc. You (Jason) copy-paste each section into App Store
Connect. Everything below has been vetted against `PRIVACY.md` and the
actual code in the repo so the claims are truthful.

---

## 1. What's New (release notes) — paste into both iOS + macOS

**Short version (under 250 chars, mobile-safe):**

```
v1.9.4
• Claude card now leads with message count (matches Claude Code's own UI), with I/O token count and cost below
• Codex card continues to lead with I/O tokens (input + output, matches OpenAI billing convention)
• Force Rescan rebuilds the JSONL cache if totals ever look off
• Clearer privacy disclosures — your provider API keys stay on your Mac
• Quota alerts, tier display, and toggle responsiveness improvements from v1.9.3
```

**Longer version** (if ASC field allows) — append below:

```
Under the hood:
• Security-scoped bookmark handling rewritten so Codex/Claude session logs scan reliably on sandboxed builds
• Claude 5h/Weekly/Sonnet quota bars restored
• Provider toggle now updates instantly instead of waiting for the next refresh
• Local quota alerts with stable IDs, local suppression so resolved alerts don't reappear
• Token display per provider: Claude leads with deduped assistant message count to match Claude Code's UI (raw token counts are dominated by ~98% cache_read noise and don't reconcile with Anthropic's dashboard). Codex uses input + output to match OpenAI billing semantics. Cost display remains fully accurate (per-component pricing, including cache rates).
```

---

## 2. App description — updated

Open the existing description and insert this block as the **second paragraph**
(right after the one-liner hook, before the feature list):

```
Privacy-first by design.
Your provider API keys and session cookies (OpenAI, Anthropic, Google, OpenRouter, and more) never leave your device. They're stored only in your macOS Keychain and used solely to query those providers directly. Token counts, cost estimates, and quota state sync to your CLI Pulse account so iPhone and Apple Watch can show the same history — but the raw API keys and session log contents stay on your Mac. Full disclosure: jasonyeyuhe.github.io/cli-pulse/privacy.html
```

Leave the rest of the description intact — this paragraph alone is the
differentiation.

---

## 3. Promotional text (170-char limit) — optional refresh

Existing promotional text probably still applies. If you want to lean into
privacy:

```
Track usage and cost across Claude, Codex, Gemini, and more — with your API keys staying in macOS Keychain, never uploaded.
```

---

## 4. App Privacy labels — review carefully

Go to **App Store Connect → App Privacy → Manage**. The labels below reflect
what the app ACTUALLY does post-v1.9.4. If any of the current labels don't
match this list, fix them.

### Data types we DO collect (linked to user)

Each of these is linked to the user's identity (their CLI Pulse account).

| Category | Data Type | Purpose | Linked to Identity | Used for Tracking |
|---|---|---|---|---|
| Contact Info | Email Address | App Functionality, Account Management | Yes | **No** |
| Identifiers | User ID | App Functionality, Analytics (*our own, not 3rd party*) | Yes | **No** |
| Usage Data | Product Interaction | Analytics, App Functionality | Yes | **No** |
| Diagnostics | Performance Data | App Functionality | Yes | **No** |

**"Product Interaction" covers:** per-provider token counts (aggregated per
day), cost estimates, model names used, quota state, refresh timestamps,
device name, helper version.

### Data types we DO NOT collect (explicitly unchecked)

- **Financial Info** → No (we do not receive payment card info; StoreKit handles that)
- **Health & Fitness** → No
- **Location** → No (neither precise nor coarse)
- **Sensitive Info** → No
- **Contacts** → No
- **User Content** → No (we do NOT collect photos, audio, customer support text, gameplay content, emails, or messages)
- **Browsing History** → No
- **Search History** → No
- **Identifiers → Device ID** → No (we track devices by the user's hostname, not a stable device identifier)
- **Purchases** → No
- **Other Data Types** → No

### Critical: do NOT check "Credentials"

Apple's "Credentials" data type means "account credentials we collect and
store server-side (e.g. passwords for other services)". Since provider API
keys live **only** in macOS Keychain and are never transmitted to our
backend, **leave this unchecked**. Checking it would be a false positive
that misrepresents our actual data handling.

### Tracking

**Does your app use data for tracking?** No. We do not use any data to
track you across apps and websites owned by other companies. We do not ship
any third-party analytics SDKs. Uncheck all "Used for Tracking" boxes.

---

## 5. Privacy Policy URL

Ensure the Privacy Policy URL field in App Store Connect points to:

```
https://jasonyeyuhe.github.io/cli-pulse/privacy.html
```

This is the GitHub Pages-hosted static version (no GitHub login required,
works in-browser anywhere). The in-app Settings → Privacy section links to
this same URL, and the About → Privacy Policy link already pointed here.

**Important:** `docs/privacy.html` must be updated to match the new
`PRIVACY.md` content before this v1.9.4 release goes live. (Handled as part
of the commit that adds this submission doc.)

---

## 6. Screenshots — your job

Per your plan, you're producing a new "privacy hero" screenshot set. I am
NOT generating those in this pass. Recommended content if you want matching
copy:

**Hero text:** "Your API keys stay on your device"
**Sub:** "Stored only in macOS Keychain. Never uploaded. Never shared."
**Diagram:** Mac icon → lock icon → provider API icon (OpenAI/Anthropic
logos). Skip anything that visually implies our server sits in the middle.

Suggested placement in the screenshot carousel: position 2 or 3 (after the
main Providers/Overview screenshots).

---

## 7. Pre-submission checklist

- [ ] MARKETING_VERSION = 1.9.4 in pbxproj (done by this commit)
- [ ] CURRENT_PROJECT_VERSION = 31 (done by this commit)
- [ ] Archive + upload macOS app
- [ ] Archive + upload iOS app
- [ ] Archive + upload watchOS app (embedded with iOS)
- [ ] Confirm App Privacy labels match section 4
- [ ] Confirm Privacy Policy URL resolves
- [ ] Paste "What's New" (section 1)
- [ ] Paste description block (section 2)
- [ ] Upload new privacy-hero screenshots (your job)
- [ ] Submit for review

---

## 8. If App Review asks questions

They sometimes challenge privacy claims. Prepared answers:

**Q: "You claim API keys never leave the device. Where's your proof?"**
A: Refer to `CLIPulseCore/Sources/CLIPulseCore/ProviderConfig.swift:23-25`
(explicitly excludes `apiKey` and `manualCookieHeader` from Codable's
`CodingKeys`) and `APIClient.swift` (grep for `api_key` / `apiKey` in POST
bodies — no matches). `supabase/` schema contains no credential columns.
Link to PRIVACY.md for the full data-by-data breakdown.

**Q: "Why are you marked as collecting 'Usage Data'?"**
A: We collect aggregated per-day token counts, cost estimates, and model
names so the user's own iPhone and Apple Watch can show the same usage
history the Mac shows. It's linked to the user's account ID, not used for
tracking, and we don't share it with any third party. This is disclosed
verbatim in PRIVACY.md and in the in-app Onboarding wizard (Privacy
screen) and Settings → Privacy.
