# PROJECT FIX — Supply-chain CI hardening (SHA-pin actions + Gradle wrapper validation) (P2)

**Date:** 2026-06-27
**Train:** Backend trust hardening — **PR5 (P2)**
**Branch:** `hardening/supply-chain-ci`
**Plan:** `DEV_PLAN_2026-06-27_nextphase_trust_hardening.md` §2 PR5

---

## Summary

Pinned every GitHub Actions reference to a full 40-char commit SHA, added Gradle
wrapper-jar validation as the first real Android CI step, and added Dependabot to
keep the pins fresh. Closes the window where a retagged action or a tampered
`gradle-wrapper.jar` could exfiltrate signing keys / Supabase / Sentry / Tauri
secrets before any test runs.

## Why

Release/build jobs hold the most sensitive credentials in the project (Apple
Distribution P12 + notary, Android signing store/key passwords, Supabase/Sentry
tokens, distribution PAT). Every action was referenced by a **moving tag**
(`@v4`/`@v5`/`@v2`) — an upstream tag can be repointed to malicious code, which
then runs with full job privileges. The Android wrapper jar likewise executes
with job privileges on the first `./gradlew`.

## What changed

- **SHA-pinned all 35 action references** across the 7 workflows (each keeps a
  trailing `# vN` so humans still read the version):
  | action | SHA | tag |
  |---|---|---|
  | actions/checkout | `34e114876b0b11c390a56381ad16ebd13914f8d5` | v4 |
  | actions/setup-java | `c1e323688fd81a25caa38c78aa6df2d33d3e20d9` | v4 |
  | actions/setup-python | `a26af69be951a213d495a4c3e4e4022e16d87065` | v5 |
  | actions/cache | `0057852bfaa89a56745cba8c7296529d2fc39830` | v4 |
  | actions/upload-artifact | `ea165f8d65b6e75b540449e92b4886f43607fa02` | v4 |
  | denoland/setup-deno | `667a34cdef165d8d2b2e98dde39547c9daac7282` | v2 |
  | gradle/actions/wrapper-validation | `ed408507eac070d1f99cc633dbcf757c94c7933a` | v4 |
- **`android-ci.yml`** — `gradle/actions/wrapper-validation` is now the first
  real step (right after checkout, before `setup-java`/any `./gradlew`). It
  verifies every `gradle-wrapper.jar` against Gradle's published checksums; a
  tampered jar fails the job before secrets are in scope. Our jar is gradle
  9.3.1 (a real release) so it validates clean.
- **NEW `.github/dependabot.yml`** — weekly `github-actions` ecosystem updates
  (grouped into one PR) so the SHA pins don't silently rot past security patches.

## Verification checklist

- [x] `grep -E "uses: .*@v[0-9]"` over `.github/workflows/` → **NONE** (all pinned).
- [x] All 7 workflows + `dependabot.yml` parse as valid YAML.
- [x] SHAs resolved from each action's current `vN` tag via `gh api repos/<a>/commits/<tag>`.
- [ ] CI green (Android CI runs wrapper-validation; the pinned actions resolve).

## Notes / follow-ups

- **Merge note:** this branch pins `supabase-ci.yml` actions on top of `main`.
  PR3 (#230) also edits `supabase-ci.yml` (adds the `rls-cross-user` job). They
  will trivially conflict — whichever merges second must also SHA-pin the new
  job's `actions/checkout`. (Trivial; both use the same checkout SHA above.)
- `gradle/actions/wrapper-validation` validates ALL wrapper jars in the repo
  (only `android/gradle/wrapper/gradle-wrapper.jar` exists). The "tamper → fail"
  behavior is the action's documented guarantee; not exercised destructively in CI.
