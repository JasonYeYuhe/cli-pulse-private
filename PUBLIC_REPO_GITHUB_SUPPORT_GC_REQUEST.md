# GitHub Support — GC request for `JasonYeYuhe/cli-pulse`

**Status:** draft, not yet sent.
**Drafted:** 2026-04-28
**To send via:** <https://support.github.com/contact> (signed in as
`JasonYeYuhe`), or `gh api` if a private support endpoint is preferred.

The body below is intended to go in the support request as-is. It contains
no secret values. Copy the block between the markers verbatim.

---

## Suggested fields

- **Subject:** `Request server-side GC of unreachable objects after public-history rebuild — JasonYeYuhe/cli-pulse`
- **Category:** Repository / Sensitive data exposure
- **Severity:** Medium (no credentials known to be exposed; product source code was)

---

## Message body

```
Hi GitHub Support,

I run the public repository JasonYeYuhe/cli-pulse, which is the
distribution and trust-documentation site for CLI Pulse (commercial app).
GitHub Pages is enabled at https://jasonyeyuhe.github.io/cli-pulse/.

Earlier this week I discovered that closed-source product code had been
accidentally pushed to this *public* repository over a long period,
including the most recent main commit. I have already remediated the
remote state:

- public/main was force-pushed to a fresh distribution-only commit:
    5d150805368cc1de1533a3513085e4f7883bd57b
  (the previous source-bearing tip was b462fedeb1a891b7ab7ecd4095506dcfd931b156)

- 18 release tags that previously pointed at source-bearing commits were
  deleted and recreated on a distribution-only commit:
    4f72f82c1043053dae93dc34a27bb607a4aa0c91

  Retagged tags:
    v1.10.7, v1.10.6, v1.10.4, v1.10.3, v1.10.2, v1.10.1, v1.10.0,
    v1.9.5, v1.9.1, v1.8, v1.5, v1.1.1, v1.1.0,
    android-v1.10.4, android-v1.10.3, android-v1.9.5, android-v1.9.4,
    android-v1.9.2

  These five tags were already pointing at distribution-only commits and
  were left untouched: v1.4.0, v1.4.1, v1.1.2, v1.1.3, v1.0.0-android.

- The corresponding GitHub Releases were re-published (drafts caused by
  tag-deletion were promoted back to published, with their original DMG
  and APK assets intact). v1.10.7 is the current Latest release.

- GitHub-auto-generated source archives (/archive/refs/tags/<tag>.zip and
  /zipball/<tag>) for every retagged release now resolve to
  distribution-only trees. I have spot-checked v1.10.7, v1.10.6, v1.10.4,
  and android-v1.10.4 zipballs; each contains only the 14 public-facing
  files.

The previously-pushed source-bearing commits and blobs are no longer
reachable from any branch or tag, but they still appear to be fetchable
by SHA, and any cached source archives generated before the rewrite may
still be served. Could you please:

1. Run server-side `git gc` / object pruning on JasonYeYuhe/cli-pulse so
   the now-unreachable commits, trees, and blobs are dropped.

2. Invalidate any cached auto-generated source archives (zipball /
   tarball) for the 18 retagged tags listed above, so the regenerated
   archives reflect the current tag SHAs.

3. If your team can identify and notify forks of JasonYeYuhe/cli-pulse
   created before 2026-04-28, that would help; I understand if it is not
   feasible.

The private source repository (JasonYeYuhe/cli-pulse-private) is and
remains private and was not affected by this remediation.

Happy to provide any additional details — affected SHAs, retagged tag
list, or repo settings — that help complete the cleanup.

Thanks very much.

— Jason Ye
  yyyyy.yeyuhe@gmail.com
```

---

## After sending

- Save the support ticket ID here for future reference.
- Re-run `gh api repos/JasonYeYuhe/cli-pulse/pages` and the source-archive
  smoke test (`unzip -l` of the v1.10.7 zipball) once GitHub confirms GC
  has run, to verify no stale objects are still being served.
- Update `PUBLIC_EXPOSURE_ROTATION_CHECKLIST.md` with the resulting
  posture (e.g. mark "GH GC complete" when done).
