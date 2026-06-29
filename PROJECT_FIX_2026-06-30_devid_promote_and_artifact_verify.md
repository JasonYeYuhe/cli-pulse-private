# PROJECT FIX — DEVID release: wire promote_to_latest + published-artifact identity gate

**Date:** 2026-06-30 · **Train:** Trust Hardening v2 (PR-3 of 3)
**Plan:** `DEV_PLAN_2026-06-30_trust_hardening_v2.md`.

## Problems
1. `.github/workflows/devid-dmg.yml` declared a `promote_to_latest` workflow input that
   was **never referenced** — selecting `true` was a silent no-op, so the only way to
   promote `latest.json` was the manual `gh release` dance (which hit the
   `gh release create file#name` rename pitfall this session → 404'd `latest.json`).
2. No server-side assertion that the shipped artifact matches the **identity the client
   updater enforces** (PR-1's `UpdateVerifier`) or the manifest clients read.

## Fix (both additive; existing tag-push behavior unchanged)
- **Identity gate** (new step, runs on every devid-dmg build): `codesign --verify --strict
  -R=<requirement>` with the EXACT client requirement (`anchor apple generic and identifier
  "yyh.CLI-Pulse" and certificate leaf[subject.OU] = "KHMK6Q3L3K"` + Developer ID marker
  OIDs), plus bundle-id == `yyh.CLI-Pulse` and `CFBundleShortVersionString`/`CFBundleVersion`
  == the manifest. Catches a mis-signed/mis-versioned release before it can reach the
  channel — the server-side mirror of PR-1.
- **Promote step** (new, gated `workflow_dispatch && promote_to_latest == 'true'`): after
  all gates pass, upload the freshly-built+verified DMG/sha/manifest to its
  `app-v<version>` release, then promote `latest.json` by uploading a file **literally
  named `latest.json`** (`gh release upload latest`, never `create file#name`), then
  re-download `latest.json` via the API and assert its `version`/`sha256` match the built
  artifact. Codifies the manual promotion so it can't repeat the rename pitfall.

## Validation
- YAML lint: OK.
- `devid-dmg.yml` runs only on `workflow_dispatch`/tag push (not PRs), so the new steps
  are exercised on the **next DEVID build/promote** (owner-gated), not in PR CI. The shell
  is straightforward + reviewed; the identity requirement string is identical to PR-1's
  (which is unit- + real-DMG-tested).

## Note
This does NOT auto-promote anything — promotion still requires an explicit manual dispatch
with `promote_to_latest=true` after the on-device smoke. It only makes that promotion
correct + verified instead of a hand-typed `gh` command.
