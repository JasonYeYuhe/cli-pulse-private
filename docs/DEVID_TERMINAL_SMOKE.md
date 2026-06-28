# Developer-ID in-app terminal — on-device smoke (W2)

**MANDATORY before promoting a DEVID `latest.json`.** The in-app terminal had
never run end-to-end before W1-A unsandboxed the build; this is the gate that
proves it actually works on a real notarized Developer-ID build. Render fidelity
cannot be verified headlessly (headless macOS suppresses `requestAnimationFrame`
/ GPU compositing), so this is a **manual** checklist. CI enforces the config
invariants (unsandboxed + xterm bundle present + signed-entitlement matrix); this
proves the live render.

## Why a CLEAN Mac (no App Store copy)

The App Store build and the DEVID build share bundle id `yyh.CLI-Pulse`. The
App-Store copy carries a Launch Constraint that blocks a second `yyh.CLI-Pulse`
(the DEVID `.app`) from co-launching. So run this on a Mac that does **not** have
the Mac App Store CLI Pulse installed (a clean VM/user, or uninstall the MAS copy
first). See `feedback_vm_as_real_e2e`.

## Preconditions

- A signed + **notarized + stapled** DEVID `.app` / `.dmg` from
  `scripts/build_devid_dmg.sh` (NOT an ad-hoc build — AMFI/taskgated behavior for
  the unsandboxed LoginItem only reproduces under a real Developer-ID signature).
- The background helper (`cli_pulse_helper` LaunchAgent) installed + paired, and
  **Local Session Control enabled** in Settings (the terminal is gated on it —
  W1-B). The "Terminal" menu items grey out until this holds.
- At least one of `claude`, `agy` (Gemini), `codex` on `PATH`.
- `scripts/terminal_render_fixture.sh` available on the test Mac (copy it over).

## Steps (record PASS/FAIL + screenshot per provider)

### 0. Launch + gate
- [ ] DEVID `.app` launches from `/Applications` (drag-installed from the DMG); no
      Gatekeeper block (notarization stapled).
- [ ] Menu bar shows the app. **Terminal** menu is present (DEVID build →
      `canHostInAppTerminal`). On a MAS build it must be ABSENT.
- [ ] With the helper running + Local Control ON, the "New Terminal — …" items are
      ENABLED. Toggle Local Control OFF → items grey out + the
      "Background helper not ready — open Settings…" row appears (W1-B). Toggle
      back ON.
- [ ] Confirm the running app is UNSANDBOXED:
      `codesign -d --entitlements :- "/Applications/CLI Pulse.app" | grep app-sandbox`
      → no output. And `NSHomeDirectory()` resolves to the real home (the helper
      diagnostics log line in Console shows `home=/Users/<you>` not a container).

### 1. Spawn + render (repeat for claude, agy, codex)
- [ ] **New Terminal — <provider>** → pick a working directory → a terminal
      window opens and the CLI's TUI appears (banner / prompt).
- [ ] In that terminal run: `bash scripts/terminal_render_fixture.sh`
- [ ] Open macOS **Terminal.app** in the same window size, run the same fixture,
      and compare **side-by-side**. Every section identical = 1:1:
  - [ ] §1–3 colors (16 / 256 / truecolor) match hue + position
  - [ ] §4 SGR: bold, dim, italic, underline, reverse, strike, blink all render
  - [ ] §5 box-drawing (single/double/rounded) + block shading — no gaps/mojibake
  - [ ] §6 CJK width: every trailing `|` aligns (wide glyphs = 2 cells)
  - [ ] §7 cursor addressing: three X marks evenly spaced on one line
  - [ ] §8 spinner animates smoothly then settles on `✓ done.`
  - [ ] window title bar shows "CLI Pulse render fixture" (OSC 0 forwarded)

### 2. Input
- [ ] Type into the live CLI (e.g. ask the agent something / run `ls`); keystrokes
      echo with no lag or dropped chars. Fast-type a long line — nothing dropped.
- [ ] `Ctrl-C` interrupts a running command (raw byte 0x03 reaches the PTY).

### 3. Resize
- [ ] Drag the window wider/narrower; the TUI reflows to the new column count
      (no hard newlines / ragged wrap). A full-screen TUI (e.g. claude's UI)
      repaints to fit.

### 4. Stop / detach / reattach
- [ ] Close the terminal window → the helper session keeps running (visible in the
      Sessions tab as running).
- [ ] From Sessions, **Open Terminal** on that row → reattaches; the tail snapshot
      repaints and live output resumes (no duplicated/garbled buffer).
- [ ] Stop the session (Sessions Stop, or exit the CLI) → row goes to stopped; no
      ghost terminal window survives an app relaunch.

### 5. Helper-down behavior
- [ ] Quit the helper (or `launchctl bootout`); within a few seconds the Terminal
      menu items grey out and Sessions "Open Terminal" disappears for local rows.
      Re-launch the helper → they return. No crash.

## Record

| Provider | spawn | render 1:1 | input | resize | stop/reattach |
|----------|-------|------------|-------|--------|---------------|
| claude   |       |            |       |        |               |
| agy      |       |            |       |        |               |
| codex    |       |            |       |        |               |

Date / build / tester / notes:

> Only after every row passes may the DEVID `latest.json` be promoted.
