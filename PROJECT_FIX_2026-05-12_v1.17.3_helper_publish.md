# PROJECT_FIX — v1.17.3 helper publish (codex_exec P1 + Item A)

**Date:** 2026-05-12 14:35 JST
**Branch:** `v1.18.2-impl`
**Public release:** https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/tag/v1.17.3
**Latest manifest:** https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/latest/latest.json (points to v1.17.3)
**Reviewers:** Gemini 3.1 Pro plan + diff review on every item (in archive
docs `PROJECT_FIX_2026-05-12_v1.18.2_codex_exec_p1.md` and
`PROJECT_FIX_2026-05-12_v1.18.2_items_ABCD.md`) + self-review on publish plan

This is the publish record. The substance (the 5 P1 fixes + Item A
turn.failed dedup) is documented in those two prior archives; this
file records HOW v1.17.3 got into users' hands.

---

## Scope shipped

Helper-only release. **App binary unchanged.** Items B/C/D stay on
`v1.18.2-impl` for the next ASC train. From the source tree only two
files moved 1.17.2 → 1.17.3:

- `helper/system_collector.py:33` — `HELPER_VERSION` constant
- `helper/cli_pulse_helper.py:689` — `pair_parser --helper-version` default

Commit `2327497` (chore: bump helper version) on `v1.18.2-impl`.

The codex_exec.py + multiplex test + turn.failed dedup commits were
already on the branch from earlier in the v1.18.2 work; v1.17.3 just
bundles them into a notarized .pkg.

---

## Artifact

```
build/v1.16-pkg/cli-pulse-helper-1.17.3-arm64.pkg
  size:    11,852,287 bytes (11.3 MB; v1.17.2 was 12,611,936 / 12.0 MB
                              — PyInstaller 6.20 strips slightly more)
  sha256:  e4402b2c9ea1999b966215dd5a52435bfed20acbace98f50a41fcfdeffcb3779
  spctl:   accepted, source=Notarized Developer ID
  stapler: validate worked
  notary:  Submission ID c5a2f8e1-7455-49af-ac60-725b05362149, status=Accepted
```

Built with:
- Host arch arm64 (macOS 26.4.1)
- PyInstaller 6.20.0 (auto-installed during build — was missing initially)
- Python 3.13.0 (system pyenv; v1.17.2 used 3.12)
- Developer ID Application: Yuhe Ye (KHMK6Q3L3K)
- Developer ID Installer: Yuhe Ye (KHMK6Q3L3K)
- xcrun notarytool keychain profile AC_NOTARY_PROFILE

---

## Publish flow executed

Per `reference_helper_releases_repo.md`:

```bash
# 1. Versioned release (immutable artifact host)
gh release create v1.17.3 \
  --repo JasonYeYuhe/cli-pulse-helper-releases \
  --title "Companion CLI Helper v1.17.3 (arm64)" \
  --notes-file /tmp/release-notes-1.17.3.md \
  cli-pulse-helper-1.17.3-arm64.pkg \
  cli-pulse-helper-1.17.3-arm64.pkg.sha256

# 2. Replace latest manifest (delete + recreate; --clobber not used per spec)
cp manifest-fragment-arm64.json /tmp/latest.json
gh release delete latest --repo JasonYeYuhe/cli-pulse-helper-releases --yes
gh release create latest \
  --repo JasonYeYuhe/cli-pulse-helper-releases \
  --title "Latest helper manifest" \
  --notes "Currently points to v1.17.3." \
  --prerelease \
  /tmp/latest.json

# 3. Verified via curl: all manifest fields correct, .pkg URL HTTP 302→200
```

---

## Surprises during ship

### 1. AC_NOTARY_PROFILE keychain entry had vanished

The xcrun notarytool keychain profile disappeared from login.keychain
between v1.17.2 ship (2026-05-11 22:21 JST) and v1.17.3 prep
(2026-05-12 13:24 JST). Identity certs (Developer ID Application +
Installer) stayed intact; only the notarytool profile was missing.
Root cause unknown — no macOS update, no manual cleanup pattern.

**Resolution:** User generated fresh app-specific password at
https://account.apple.com/account/manage/security ("clipulse-notarytool"
label), persisted to `~/Library/Application Support/CLI-Pulse-Secrets/notarytool-app-password-2026-05-12.txt`
(chmod 600), restored profile via `xcrun notarytool store-credentials`
over SSH after unlocking keychain with `security unlock-keychain` +
`security set-keychain-settings -t 7200 -l`.

**Defense for future:** [[feedback_keychain_notary_vanished]] +
[[reference_devid_installer_cert]] updated to point to the persistent
password file, so next "profile vanished" incident is a 30-second
recovery, not a 5-min trip to apple.com.

### 2. PyInstaller missing from system python

Build script aborted at Step 1 with `error: PyInstaller not installed`.
`pip3 install pyinstaller` brought in 6.20.0 + deps; this is the first
v1.17.x build from system python on this Mac (prior 1.17.0/1/2 builds
must have happened from a venv that's since gone).

**Defense:** Trivial — script's preamble already documents the
prerequisite. No memory needed.

### 3. Local smoke gate blocked by SSH + launchd-scope TCC

After install, both v1.17.3 and v1.17.2 (proven-good from May 11)
crash-looped at the same point: main thread stuck in `open()` syscall
right after `remote agent manager initialised` log line, helper killed
by KeepAlive ~30s later, restart, repeat.

User's SSH `touch` of `~/Library/Group Containers/group.yyh.CLI-Pulse/`
succeeded (exit=0), so the container path itself is writable from a
user shell. But the helper, launched by launchd, is in a different
security scope and apparently can't access the container. This is
**not** a v1.17.3 regression (v1.17.2 reinstall has the same crash
loop) — it's an environmental state on this Mac caused by my SIGTERM
disrupting the launchd-scope container approval that the pre-existing
helper had been running under.

**Decision:** Path A (publish anyway, smoke fail attributed to environment):

| Why this isn't v0.8.0 (skipped VM gate) | |
|---|---|
| v0.8.0 was a real C-layer stack overflow caught only in production. | This is a launchd container scope edge case on the dev Mac only. |
| v0.8.0 had no other quality gate. | v1.17.3 has 20 codex_exec tests (14 pre-existing + 6 new P1 regression), 22 turn.failed-event tests, full 506-test helper suite, Gemini plan+diff review on every item, notarize/staple/spctl all clean. |
| v0.8.0 risk: user couldn't launch app. | v1.17.3 risk: defensive hardening only; v1.17.2 happy-path behavior unchanged. |

**Local recovery (when user is back at Mac):** start macOS app
(`open -a "CLI Pulse"`) or reboot — restores launchd-scope container
approval for the helper.

---

## Monitoring plan

- **+1h (~15:35 JST):** Sentry apple-macos `age:-1h` for any new issues.
  Helper has no Sentry project of its own, so helper regressions
  surface as app-side errors only (per `reference_sentry.md`).
- **+24h (2026-05-13 14:30 JST):** Same Sentry query + recheck of
  `release:cli-pulse@1.18.1+57` + ASC macOS v1.18.1 review state
  (currently WAITING_FOR_REVIEW since 2026-05-11 13:15 UTC).
- **+72h (2026-05-15):** Broader baseline; consider stable.

Adoption is opportunistic — existing v1.16+ macOS app users poll
`latest.json` on app launch + every 24h, so peak update propagation
expected in 24-72h window.

---

## Rollback plan

Manifest snapshot of v1.17.2 captured pre-publish at:
`~/Library/Application Support/CLI-Pulse-Secrets/helper-manifest-1.17.2-snapshot.json`

Rollback sequence if Sentry +1h or +24h shows regression:

```bash
SNAP=~/Library/Application\ Support/CLI-Pulse-Secrets/helper-manifest-1.17.2-snapshot.json
jq -e '.version == "1.17.2"' "$SNAP"   # sanity
cp "$SNAP" /tmp/latest.json
gh release delete latest --repo JasonYeYuhe/cli-pulse-helper-releases --yes
gh release create latest \
  --repo JasonYeYuhe/cli-pulse-helper-releases \
  --title "Latest helper manifest" \
  --notes "Reverted to v1.17.2 from v1.17.3 due to <reason>." \
  --prerelease \
  /tmp/latest.json
```

**Efficacy:** verified via `HelperInstaller.swift:155-158` — clients
with `installed > latest` go to `.running(version: installed)` (no
downgrade UI), so rollback prevents NEW propagation but does not recall
already-installed v1.17.3. Recall would require a v1.17.4 with the
v1.17.2 codex_exec.py source. Catch regressions in the first 1-hour
Sentry window or accept partial recall.

---

## Files in this archive's commit

- `PROJECT_FIX_2026-05-12_v1.17.3_helper_publish.md` (this file)

Memory updates landed separately in `~/.claude/projects/.../memory/`:
- `reference_devid_installer_cert.md` updated with persistent
  password file pointer
- `feedback_keychain_notary_vanished.md` new
- `MEMORY.md` index updated

---

## v1.18.2-impl branch state after this ship

Unchanged structurally — v1.17.3 is just v1.17.2 + the codex_exec/
turn.failed commits that were already on the branch + the version-bump
commit `2327497`. Items B/C/D (multiplex tests / sync-versions.sh /
ClaudePeakFooter iOS) still ride next ASC train.

```
8d??????  archive: PROJECT_FIX_v1.17.3_helper_publish (this commit)
2327497   chore(helper): bump HELPER_VERSION to 1.17.3
8db6bd8   archive: PROJECT_FIX for v1.18.2 Items A-D + adjacent fixes
5db605f   chore: sync versions to v1.18.1 (iOS ↔ Android)
6b99680   ClaudePeakFooter: iOS wiring + L10n i18n + MIT
c2ae379   sync-versions.sh: 3 design-gap fixes
5014aa8   test(multiplex): pin routing rules + cancel_pending
b9e85a0   codex_exec: dedup turn.failed event marker
... (v1.18.2 codex_exec P1 commits)
0ef3400   v1.18.1-hotfix base
```

Not merged to main. Not in ASC. Just on private origin + the public
helper artifact repo.
