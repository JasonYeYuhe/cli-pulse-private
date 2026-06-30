# PROJECT FIX — updater mountReadOnly detaches the wrong disk (mount leak)

**Date:** 2026-06-30 · **Found by:** first-principles verification workflow (wf_f3667423-995), P3 (no security impact).

## Problem
`UpdateVerifier.mountReadOnly` picked the detach device as the **globally-shortest**
`dev-entry` across all `hdiutil attach -plist` system-entities. In a multi-volume DMG that
shortest entry can be a DIFFERENT disk than the one carrying the mount. Verified on this Mac
against a real DMG attach: entities `/dev/disk12s1, /dev/disk12, /dev/disk13s1
(mount-point=…), /dev/disk13` → old code chose `/dev/disk12` while the volume is backed by
`/dev/disk13` → it would detach the wrong disk and **leak the real mount**. No security
impact (the verified app still installs), but a resource/mount leak.

## Fix
Extract a pure, unit-tested `selectMount(from:)` that finds the entity actually carrying the
mount-point and detaches its **whole-disk node** (`/dev/disk13s1` → `^/dev/disk[0-9]+` →
`/dev/disk13`), falling back to the mount-point itself (`hdiutil detach` accepts it) when the
mount entity has no dev-entry. `mountReadOnly` parses the plist then delegates selection.

## Tests (`swift test -Xswiftc -DDEVID_BUILD --filter UpdateVerifierTests`: 21 tests, 0 failures)
- multi-volume → picks `/dev/disk13` (the mount-carrier), not the shorter `/dev/disk12`;
- single-volume → whole disk; no-mount → nil; mount-without-dev-entry → mount-point fallback.
- `test_realDMG_passes_whenProvided` still passes against the real notarized 1.34.0 DMG.

## Smoke note
Add a real shipped-release-DMG `hdiutil attach -plist` probe to the DEVID smoke checklist to
confirm the production format (likely single-volume UDIF, in which case the old code was
benign — but the fix is correct for both).
