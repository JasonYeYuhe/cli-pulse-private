# PROJECT FIX — gitleaks secret-scan CI gate

**Date:** 2026-06-30 · **Train:** Trust Hardening v2 (PR-2 of 3)
**Plan:** `DEV_PLAN_2026-06-30_trust_hardening_v2.md`.

## Problem
The demo-reviewer credential entered the (public) repo and was never caught by CI —
there was no secret-scanning gate, so any committed secret could ship silently.

## Fix
- `.github/workflows/secret-scan.yml` — gitleaks (pinned v8.18.4 binary, downloaded +
  installed, no third-party action):
  - **pull_request / push:** scan ONLY the new commits (`--log-opts=base..head`), so the
    PRE-EXISTING historical leak (handled out-of-band by credential rotation O1 + repo
    visibility O2) does NOT turn every PR red; a NEW secret in the diff fails the check.
  - **schedule (weekly) / dispatch:** full-history scan, INFORMATIONAL (`--exit-code 0`),
    writing a findings count to the job summary for owner review.
- `.gitleaks.toml` — `useDefault` ruleset + an allowlist of genuine non-secrets only
  (public-by-design `scripts/devid-profiles/*.provisionprofile`, `.lproj/*` UI strings,
  the `<*_REDACTED>` doc placeholders, the `ci-stub-anon-key`). **No real secret literal
  is allowlisted** (that would re-commit it); the historical credential is handled by
  rotation + repo-visibility, not by an allowlist entry.

## Rationale for range-scanning over full-history on PRs
A full-history scan on every PR would fail on the known historical leak until a
destructive `git filter-repo` purge — which O2 explicitly defers in favor of flipping the
repo private + rotating the credential. Range-scanning gives an immediately-green,
useful gate (blocks NEW leaks now) while the historical cleanup proceeds independently.

## Verification
- YAML lint: OK.
- `.gitleaks.toml` parses; local `gitleaks detect` over the working tree reports no new
  findings against this config.
- CI: the gate runs on this PR (scanning its own commits = the two new files, no secrets)
  and must come back green.
