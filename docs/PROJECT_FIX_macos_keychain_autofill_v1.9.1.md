# PROJECT FIX + FEATURES: macOS v1.9.2

Bundles two bug fixes and two small features targeting the Provider Settings editor.

## Bug fixes
# (original title retained below)

## PROJECT FIX: macOS Keychain AutoFill leak & popover dismissal (v1.9.1 → v1.9.2)

**Date:** 2026-04-18
**Platform:** macOS (CLI Pulse Bar menu-bar app)
**Severity:** Medium — user-facing confusion; no data leak, but privacy perception risk (shows `demo@clipulse.app` to a real user)
**Reporter:** Jason (self-discovered post v1.9.1 ASC approval)
**Status:** **IMPLEMENTED** — macOS build passes, CLIPulseCore tests pass, Gemini 3.1 Pro review signed off.

---

## New features bundled in v1.9.2

### Feature 1 — "Test connection" button

Sits under the API key / Cookie section. Builds a throwaway `ProviderConfig` from the in-progress values in the editor, looks up the matching `ProviderCollector` via `CollectorRegistry.collector(for:config:)`, and calls `collect(config:)`. Reports one of three UI states:

- `.success("OK (123ms) remaining: 71")`  — green checkmark with latency + a quick remaining/credits/status hint
- `.failure(error.localizedDescription)`   — red X with the error text
- `.idle` auto-restored on edit of apiKey / cookie header / source mode, so stale "OK" results don't linger after the user changes input

Lives outside the API/OAuth gate so web-only providers (Cookie-based) can also use it. Button is annotated `@MainActor` and uses synchronous `testState = .testing` in the button action to prevent rapid-tap races.

### Feature 2 — API key show/hide eye toggle

Eye icon next to the API key field toggles between `NoAutoFillSecureField` (default — dots) and `NoAutoFillTextField` (plain — for copy-paste verification). Both variants keep the AutoFill suppression. State is local (`@State private var showAPIKey = false`), resets to hidden each time the editor opens.

### Gemini 3.1 Pro review trail (features pass)

- Pass 1 flagged: (a) `runTest()` missing `@MainActor` → state mutation on background thread; (b) race on rapid tap — `Task`-dispatched `.testing` update could enqueue duplicate requests; (c) stale success message after credential edit; (d) OAuth-provider API key visibility.
- Pass 2: (a)–(c) applied and verified. (d) consciously skipped as pre-existing behavior outside this task's scope.
- Pass 3 (after hoisting test button for web-only providers): signed off, no remaining issues.

## Files changed

- **NEW** [CLI Pulse Bar/CLI Pulse Bar/NoAutoFillFields.swift](../CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/NoAutoFillFields.swift) — AppKit-bridged `NoAutoFillSecureField` / `NoAutoFillTextField` with `contentType = nil` and `isAutomaticTextCompletionEnabled = false`.
- [CLI Pulse Bar/CLI Pulse Bar/ProviderConfigEditor.swift](../CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/ProviderConfigEditor.swift) — swaps `TextField` / `SecureField` for the AppKit bridges on macOS, uses `@Environment(\.dismiss)` instead of `onDismiss` closure.
- [CLI Pulse Bar/CLI Pulse Bar/CLIPulseBarApp.swift](../CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/CLIPulseBarApp.swift) — adds `WindowGroup("Provider Settings", id: "provider-config", for: ProviderKind.self)` scene so editor lives outside `MenuBarExtra`.
- [CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift](../CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/SettingsTab.swift) — replaces `.sheet(item:)` with `openWindow(id: "provider-config", value: config.kind)`.
- [CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj](../CLI%20Pulse%20Bar/CLI%20Pulse%20Bar.xcodeproj/project.pbxproj) — registers `NoAutoFillFields.swift` in the macOS target only.

## Review trail

- **Self-review:** build + tests passed. `ProviderConfigEditor.swift` and `NoAutoFillFields.swift` are macOS-scoped (file `#if os(macOS)` and pbxproj target-exclusive), iOS build unaffected.
- **Codex rescue (agent `ac66ed49261b165f1`):** confirmed AppKit bridge is the reliable macOS path; `SwiftUI.textContentType` is iOS-first.
- **Gemini 3.1 Pro, pass 1 (focused review):** flagged `NSApp.keyWindow?.performClose(nil)` as unreliable (could accidentally close the wrong window) and `Coordinator` binding-at-init as an anti-pattern.
- **Gemini 3.1 Pro, pass 2:** both issues resolved. Verdict: "correct, idiomatic, and safe to merge. No remaining bugs, security vulnerabilities, or logic errors."

## Fixes applied in response to review

1. Replaced `NSApp.keyWindow?.performClose(nil)` with `@Environment(\.dismiss) private var dismiss` inside `ProviderConfigEditor`. Removed the `onDismiss` closure injection from `WindowGroup`.
2. Refactored `Coordinator` classes to hold a mutable `parent` reference and refresh it via `context.coordinator.parent = self` in `updateNSView`, so the live `@Binding` is always the current one even if the parent view is recreated.
3. Replaced `.frame(height: 22)` with `.frame(minHeight: 22).padding(.vertical, 1)` to avoid clipping the native focus ring.

---

## 1. Observed symptoms

The user opened **Settings → Providers → Codex** (provider config editor). Two issues fired:

1. **AutoFill suggestion shows `demo@clipulse.app`** — a credential that was saved to iCloud Keychain during App Store reviewer testing (see `docs/PROJECT_FIX_macos_appstore_rejection_v1.8.md`). The AutoFill dialog asks for the user's *computer account password* for `叶宇和` (real macOS user) in order to unlock an autofilled password for `demo@clipulse.app`. This field is actually the Codex **API key** input — it should never trigger password AutoFill.
2. **Clicking "Cancel" on the AutoFill dialog collapses the entire CLI Pulse window** back into the menu bar (popover dismissed, `ProviderConfigEditor` sheet vanished).

Screenshot: provided by user 2026-04-18.

---

## 2. Root-cause analysis

### Bug 1 — AutoFill shows `demo@clipulse.app`

File: [ProviderConfigEditor.swift:68–85](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/ProviderConfigEditor.swift)

```swift
TextField("e.g. work, personal", text: $accountLabel)   // "Account label"
SecureField("sk-...", text: $apiKey)                    // "API key"
```

macOS AppKit's AutoFill heuristic treats **an `NSTextField` immediately followed by an `NSSecureTextField`** as a login form (username + password). Because the two fields live in the same sheet with no `contentType` hint, AppKit matches them to any Keychain item stored for a site/app the user has visited recently. `demo@clipulse.app` was saved when:

- The user tested the demo login flow during ASC reviewer preparation (see `FIX_PLAN_APPSTORE_MACOS_v1.8_rejection.md`).
- iCloud Keychain kept that credential and propagated it across devices under the Safari-shared domain `clipulse.app`.

So even though the sheet is editing an **API key** (not a password), Keychain offers the most-recent `clipulse.app` credential. This is cosmetic — `demo@clipulse.app` never gets written anywhere if the user cancels — but it looks like a leak.

Codex second opinion (agent `ac66ed49261b165f1`) concurs: reliable fix is to disable AutoFill explicitly on the secure field via AppKit `NSSecureTextField.contentType = nil` and `isAutomaticTextCompletionEnabled = false`, bridged through `NSViewRepresentable`. On macOS, SwiftUI `.textContentType()` alone is insufficient (the API is iOS-first).

### Bug 2 — Cancel collapses the whole window

File: [CLIPulseBarApp.swift:19-33](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/CLIPulseBarApp.swift)

```swift
MenuBarExtra { MenuBarView() } label: { … }
    .menuBarExtraStyle(.window)
```

Combined with `Info.plist` `LSUIElement = true`, the app has **no dock window** — the "main window" is actually the `MenuBarExtra` detachable panel. `MenuBarExtra(style: .window)` auto-dismisses whenever it **loses key-window status**.

The sequence when the user clicks Cancel on the Keychain dialog:

1. Sheet (`ProviderConfigEditor`) is attached to the MenuBarExtra panel.
2. Keychain AutoFill system dialog steals key-window status → panel is no longer key, but SwiftUI doesn't collapse it yet because the dialog is still modal on top of it.
3. User clicks Cancel → system dialog dismisses → focus returns to... nothing (we're `LSUIElement`, no window ordering fallback).
4. `MenuBarExtra` receives `resignKey` and auto-dismisses its panel — taking the sheet with it.

This is a documented SwiftUI quirk; the fix is to not present long-lived configuration UI from inside the menu-bar popover. Hoist it into a real `Window` scene.

---

## 3. Fix plan

### Step 1 — Suppress AutoFill on secure/text fields in `ProviderConfigEditor`

Add an AppKit-bridged secure field that explicitly disables AutoFill and content-type inference. Apply to both the `apiKey` `SecureField` and the `manualCookieHeader` `TextField`.

**New file:** `CLI Pulse Bar/CLI Pulse Bar/NoAutoFillSecureField.swift`

```swift
#if os(macOS)
import SwiftUI
import AppKit

struct NoAutoFillSecureField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.contentType = nil                        // no credential hint
        field.isAutomaticTextCompletionEnabled = false
        field.font = .systemFont(ofSize: 10)
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSSecureTextField { text.wrappedValue = f.stringValue }
        }
    }
}
#endif
```

Then in [ProviderConfigEditor.swift:79](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/ProviderConfigEditor.swift#L79):

```swift
#if os(macOS)
NoAutoFillSecureField(placeholder: "sk-...", text: $apiKey)
    .frame(height: 22)
#else
SecureField("sk-...", text: $apiKey)
    .textFieldStyle(.roundedBorder)
    .font(.system(size: 10))
#endif
```

Also mark the **Account label** `TextField` as *not* a username with `.textContentType(.none)` (iOS SwiftUI) / AppKit bridge on macOS, or rename the placeholder so Keychain doesn't match on "account" at all (cheaper partial fix). Recommended: keep the rename + bridge secure field; both combined should stop the dialog.

### Step 2 — Move `ProviderConfigEditor` out of the MenuBarExtra popover

Root cause of Bug 2 is structural, not a text-field bug. The fix: present the editor as its own `Window` scene, opened via `@Environment(\.openWindow)`.

**Change:** [CLIPulseBarApp.swift](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/CLIPulseBarApp.swift)

```swift
@main
struct CLIPulseBarApp: App {
    @StateObject private var state = AppState.shared
    var body: some Scene {
        MenuBarExtra { MenuBarView().environmentObject(state) } label: { … }
            .menuBarExtraStyle(.window)

        // NEW — separate window scene for provider config
        Window("Provider Settings", id: "provider-config") {
            ProviderConfigEditorHost()
                .environmentObject(state)
                .frame(minWidth: 360, minHeight: 420)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
```

**Change:** [SettingsTab.swift:1005-1006](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/SettingsTab.swift#L1005)

Replace the `.sheet(item:)` with `openWindow(id: "provider-config", value: kind)` (requires iOS 17/macOS 14 `WindowGroup(for:)` or simpler: stash the selected kind in `AppState.editingProviderKind` and read it inside the Window scene).

The editor window becomes its own key window. The Keychain dialog steals focus from *that* window; when Cancel is clicked, focus returns to the editor window — not the MenuBarExtra panel — so the popover stays up if open, or the editor window simply remains visible.

### Step 3 — Purge the stale `demo@clipulse.app` Keychain entry (manual, one-time)

For the user's personal machine only — not a code fix:

1. Open **Passwords** app (macOS 14+) or **Keychain Access**.
2. Search for `clipulse.app`.
3. Delete the `demo@clipulse.app` entry. iCloud Keychain will propagate the deletion.

**Do not** ship a code path that deletes Keychain entries on behalf of users — that would be user-hostile. Just document it for ourselves.

### Step 4 — Regression tests

- Unit: none practical for AutoFill behavior (system UI).
- Manual checklist in `RELEASE_WORKFLOW.md`:
  - Open Settings → Providers → Codex → verify **no** AutoFill popup.
  - Dismiss any system dialog that does appear → verify MenuBarExtra stays open.
  - Open Provider Settings window, minimize it, reopen from MenuBarExtra → state preserved.

---

## 4. Release scope

**Target release:** v1.9.2 (patch)

**Non-goals:**
- Do not refactor the entire settings UI into windows — only `ProviderConfigEditor` needs to move.
- Do not remove demo login support; ASC reviewers still need it.

**Rollout:**
- iOS: unaffected (no MenuBarExtra, no Keychain AutoFill heuristic same way). Still apply the `.textContentType(.none)` hygiene on the API-key field for consistency.
- macOS: ship both fixes together. One build, ASC submission, same-day promote.

**Estimated effort:** 2–3 hours implementation + 1 hour manual test + ASC submission.

---

## 5. Archive trail

Per user feedback (`feedback_fix_archiving.md`), upon completion:

1. Move this plan to `PROJECT_FIX_macos_keychain_autofill_v1.9.1.md` in `docs/`.
2. Grep for `demo@clipulse` to confirm no residual test credentials are shipped in binary paths (tests and legacy backend are fine).
3. Record the commit SHA and v1.9.2 build number in the archived doc.

---

## 6. Open questions for the user

- **OK to ship a 1.9.2 patch now**, or bundle with the next feature release? The bug is cosmetic-ish — no data at risk — so bundling is defensible.
- **Rename "Account label" placeholder** from `e.g. work, personal` to something that doesn't look like an identity field? e.g. `e.g. team-A, dev-box` — would further reduce AutoFill heuristic matches on iOS too.
