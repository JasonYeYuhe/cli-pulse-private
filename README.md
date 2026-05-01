# CLI Pulse

This workspace contains the current `CLI Pulse Bar` app plus a small amount of
legacy material kept for reference.

## Platforms

CLI Pulse ships as one product across desktop, mobile, and wearable
platforms, with a shared Supabase backend so usage history follows you
between devices:

| Platform                        | Source                                                                      | Distribution        |
| ------------------------------- | --------------------------------------------------------------------------- | ------------------- |
| macOS · iOS · iPadOS · watchOS  | this repo (`CLI Pulse Bar/`)                                                | App Store           |
| Android                         | this repo (`android/`)                                                      | Google Play         |
| **Windows · Linux**             | **[JasonYeYuhe/cli-pulse-desktop](https://github.com/JasonYeYuhe/cli-pulse-desktop)** (separate repo, Rust + Tauri 2) | GitHub Releases     |

The Windows / Linux build lives in its own repository because it shares no
client code with the Apple/Android apps (Rust + Tauri vs Swift/Kotlin) and has
a different CI matrix and release channel. Both desktop clients (macOS Swift
and Windows/Linux Rust) implement the same on-device JSONL scanner with
bit-exact parity, and every client authenticates against the same Supabase
project.

## 🔒 Privacy

- **Provider API keys & session cookies** (OpenAI, Anthropic, Google,
  OpenRouter, ...) are stored only in macOS Keychain and **never uploaded**.
  They go directly from your device to the provider's own API.
- **Session log contents** under `~/.codex/sessions/` and `~/.claude/projects/`
  are scanned **on-device** via security-scoped bookmarks you grant in
  Settings. File contents never leave your Mac.
- **Aggregated usage metrics** (token counts, cost estimates, model names,
  dates) are synced to your CLI Pulse account so iPhone and Apple Watch show
  the same history. Linked to your user ID; no third-party analytics SDKs.
- **Yield Score git tracking** is opt-in. When on, only the commit hash, an
  HMAC of the project path, the commit timestamp, and a merge-commit flag
  upload. Messages, diffs, file paths, and author identity never upload.

Full data-by-data breakdown: [PRIVACY.md](PRIVACY.md).

## Current Product Structure

- `CLI Pulse Bar/`
  - Current Xcode workspace and app targets for macOS, iOS, Watch, Widgets, and
    the shared `CLIPulseCore` package.
- `helper/`
  - Current helper CLI used for pairing, daemon sync, and local provider
    collection.
- `backend/supabase/`
  - Active SQL schema, migrations, and RPC definitions used by the app and
    helper when talking to Supabase.
- `docs/`
  - Published static site assets, including `privacy.html`, `terms.html`, and
    `index.html`, which are linked from the shipping app.

## Current Development Commands

### App

Open the current app workspace:

```bash
open "CLI Pulse Bar/CLI Pulse Bar.xcodeproj"
```

### Helper

Run helper tests:

```bash
python3 -m pytest -q helper/test_system_collector.py
```

Inspect local collection output:

```bash
python3 helper/cli_pulse_helper.py inspect
```

Run one sync:

```bash
python3 helper/cli_pulse_helper.py sync
```

### Shared Swift Package

Run the shared package tests:

```bash
swift test --package-path "CLI Pulse Bar/CLIPulseCore"
```

### Android

Run Android unit tests (requires Java runtime):

```bash
cd android && ./gradlew testDebugUnitTest
```

## Legacy or Reference Areas

- `archive/`
  - Archived drafts, old projects, and working notes that are no longer part of
    the active product path.
  - `archive/backend-fastapi-legacy/` contains the older FastAPI runtime and its
    tests.

## Notes

- If you are looking for the current shipping code, start in `CLI Pulse Bar/`.
- If you are looking for pairing or provider collection logic, start in
  `helper/`.
- If you are looking for the live backend contract, start in
  `backend/supabase/`.
- If you are preparing a release, read `RELEASE_WORKFLOW.md`.
- If you are starting a new task branch, read `BRANCHING.md`.
- If you are handing a new task to another AI, use `TASK_START_PROMPT.md`.
- If you are asking an AI to commit, merge, or decide whether public updates are needed, read `MERGE_AND_PUBLISH_RULES.md`.
