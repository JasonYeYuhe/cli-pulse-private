# In-app terminal & Mac App Store builds

CLI Pulse ships two in-app terminal surfaces. They behave differently
on the Mac App Store build vs the Developer ID DMG build.

## The two surfaces

| Surface | Where it lives | Distribution gating |
|---|---|---|
| **Mac Bar "New Terminal" menu** (v1.24 Phase 3) | Mac menu-bar app, opens an xterm.js WKWebView in the popover and hosts a local PTY | **DEVID only** — `MASSandboxGate.canHostInAppTerminal` hides the menu on MAS builds |
| **iOS Sessions "Show live terminal" toggle** (v1.25 Phase 4) | iPhone / iPad Sessions detail screen, subscribes to a Mac helper's PTY via Supabase Realtime | **Always available** — works on MAS Mac users too, as long as the helper PKG is installed |

## Why the asymmetry

The **Mac Bar in-app terminal** spawns a local PTY child (Codex / Claude
CLI / a shell). On the App Store build the host app runs under the
macOS App Sandbox, which forbids out-of-sandbox process spawning. The
PTY would die immediately on `posix_spawn`. So that menu item is
DEVID-only: `MASSandboxGate.canHostInAppTerminal` returns `false` on
MAS, and the popover hides the entry.

The **iOS Sessions terminal** doesn't spawn anything on the device. It
opens a WebSocket subscription against Supabase Realtime, the Mac
helper (which runs **outside the MAS app's sandbox**, installed as a
separate `.pkg`) hosts the PTY, and the iOS WKWebView just renders the
broadcast chunks. Same architecture works on MAS Mac and DEVID Mac
because the helper is the PTY host either way.

## What MAS users get

If you installed CLI Pulse Bar from the **Mac App Store**:

- **No** "New Terminal — Claude" menu in the Mac Bar app.
- **Yes** "Show live terminal" toggle in the iOS Sessions screen,
  provided you've installed the helper from the latest [helper
  releases](https://github.com/JasonYeYuhe/cli-pulse-helper-releases)
  page and paired it with the Mac app. The MAS Mac app + helper +
  iOS-side terminal stack still gives you the full read/write
  terminal experience on your iPhone.

If you installed CLI Pulse Bar from the **Developer ID DMG**:

- **Yes** "New Terminal — Claude" menu, plus all the iOS-side surfaces.

## FAQ

**Q: I'm on MAS — can I use the terminal at all?**

Yes, on iOS / iPad / Vision Pro. The Mac-side menu is the only thing
that's hidden. The iOS app paired with your Mac helper does the full
read/write terminal stack over Supabase Realtime.

**Q: Will the Mac Bar terminal ever ship on MAS?**

Not without significant rearchitecture. macOS App Sandbox doesn't
permit out-of-sandbox PTY spawning, and a sandboxed PTY would have to
forward bytes through the same helper IPC the iOS app uses anyway,
duplicating effort. Tracking as a v1.27+ stretch.

**Q: Why isn't this in the App Store description?**

In-app terminal is a power-user affordance. The vast majority of MAS
users use CLI Pulse for usage tracking, not as a terminal host. The
toggle is opt-in on iOS too — it doesn't surface until you tap
"Show live terminal" on a managed session.

---

*Version: documented for v1.26; Mac Bar gating lives in
`CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/MASSandboxGate.swift`;
iOS toggle lives in the Sessions detail screen.*
