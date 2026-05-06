# Phase 4 Xcode setup — embedding the helper

Phase 4 ships the `cli_pulse_helper` daemon embedded inside the macOS
app bundle so users don't need a Python install or GitHub checkout to
use the local fast-path Sessions feature. The Swift / plist / build-
script pieces are already in the repo; this doc walks through the
**three Xcode UI changes** Jason still has to make manually because
editing `project.pbxproj` from a script is fragile.

The end state we want:

```
CLI Pulse Bar.app/
  Contents/
    MacOS/CLI Pulse Bar
    Helpers/
      cli_pulse_helper                     ← from helper/dist/, signed
    Library/
      LaunchAgents/
        yyh.CLI-Pulse.helper.plist         ← rewritten template at first launch
    Resources/
      HelperAgent.plist                    ← template (placeholders intact)
```

## 1. Add `HelperAgent.plist` to the CLI Pulse Bar target's Resources

The template plist lives at:
`CLI Pulse Bar/CLI Pulse Bar/HelperAgent.plist`

It needs to be in the **Copy Bundle Resources** build phase of the
`CLI Pulse Bar` target so `Bundle.main.url(forResource:)` can find it
at runtime.

**Steps**:
1. In Xcode, open `CLI Pulse Bar.xcodeproj`.
2. Project navigator → drag `HelperAgent.plist` into the `CLI Pulse Bar`
   group (where `Info.plist` and `CLI_Pulse_Bar.entitlements` live).
3. In the "Add to targets" sheet, tick `CLI Pulse Bar` only (NOT the
   widget / watch / iOS targets).
4. Verify: target → Build Phases → "Copy Bundle Resources" should
   list `HelperAgent.plist`.

## 2. Add a "Run Script" build phase that invokes `build_helper_binary.sh`

This phase produces `helper/dist/cli_pulse_helper` (the frozen Python
binary) before the Copy Files phase below picks it up.

**Steps**:
1. Target → Build Phases → `+` → "New Run Script Phase".
2. Drag the new phase to live BEFORE "Copy Bundle Resources" so the
   binary exists when Copy Files runs.
3. Rename the phase to `Build Helper Binary` for clarity.
4. Script body:
   ```bash
   "${SRCROOT}/../scripts/build_helper_binary.sh"
   ```
5. Input File Lists (lets Xcode skip the phase when nothing changed):
   ```
   $(SRCROOT)/../helper/cli_pulse_helper.spec
   ```
   Plus an "Input Files" entry pointing at `$(SRCROOT)/../helper/`
   if Xcode supports glob-listing a directory. If not, leave empty
   (the script's own mtime check handles caching).
6. Output Files:
   ```
   $(SRCROOT)/../helper/dist/cli_pulse_helper
   ```

## 3. Add a "Copy Files" build phase that ships the binary into `Contents/Helpers/`

**Steps**:
1. Target → Build Phases → `+` → "New Copy Files Phase".
2. Rename to `Embed Helper Binary`.
3. Destination: select **Wrapper** then in the path field type
   `Contents/Helpers`. (Xcode doesn't have a built-in shortcut for
   `Contents/Helpers` — the closest is "Wrapper" + custom subpath.)
4. Drag `helper/dist/cli_pulse_helper` from Finder into this phase
   (Xcode will create a folder reference). Alternatively, reference
   it via "Add Other..." in the phase's `+` menu.
5. Tick "Code Sign On Copy" — the helper binary MUST be signed with
   the same Team ID as the app or `SMAppService.agent` rejects it
   with `OSStatus -67050` ("Invalid signature").

## 4. (Optional / later) Notarisation

When `xcodebuild archive` produces a .app, the helper binary inherits
the app's notarisation only if "Code Sign On Copy" was ticked above
AND the Team ID matches. If notarisation rejects the embedded binary,
the most likely reasons are:

  * PyInstaller's bootloader uses dlopen-style loading that triggers
    `--allow-jit`-style entitlements. Add to `CLI_Pulse_Bar.entitlements`:
    ```xml
    <key>com.apple.security.cs.allow-jit</key><true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
    ```
  * The bundled `_cffi_backend.cpython-*.so` and similar dylibs need
    individual signing. PyInstaller normally handles this when given
    `--codesign-identity` but the in-repo .spec leaves that null so
    Xcode signs as part of "Code Sign On Copy". If signing fails,
    add an explicit `codesign --deep --sign "$EXPANDED_CODE_SIGN_IDENTITY"`
    step inside the Run Script phase.

## 5. Verification

After making the three Xcode changes above:

1. Build the app (`xcodebuild -scheme "CLI Pulse Bar" -configuration Debug build`).
2. Inspect the produced .app:
   ```bash
   ls -la /tmp/clipulse_phase4_build/Build/Products/Debug/CLI\ Pulse\ Bar.app/Contents/Helpers/
   ls -la /tmp/clipulse_phase4_build/Build/Products/Debug/CLI\ Pulse\ Bar.app/Contents/Resources/HelperAgent.plist
   ```
   Both files should exist; `cli_pulse_helper` should be ~12 MB
   executable (`-rwxr-xr-x`).
3. Run the .app from Finder. After about 1–2 s, check:
   ```bash
   ls ~/Library/Group\ Containers/group.yyh.CLI-Pulse/clipulse-helper.sock
   ls ~/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist
   tail ~/Library/Logs/CLI\ Pulse/helper.err.log
   ```
   The socket should exist (created by the launchd-spawned helper);
   the LaunchAgent plist should have the placeholders substituted
   (no `__CLI_PULSE_HELPER_BIN__` strings); the log should show the
   familiar "remote agent manager initialised" lines.

## 6. Removing during development

If the LaunchAgent gets stuck in a bad state during dev (e.g.,
pointing at a deleted DerivedData path), nuke it manually:

```bash
launchctl bootout gui/$UID/yyh.CLI-Pulse.helper 2>/dev/null
rm -f ~/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist
```

The next app launch will re-install the agent against the current
DerivedData path. SMAppService also exposes `unregister()`; the app's
Settings → Helper panel calls into that for the user-facing path.
