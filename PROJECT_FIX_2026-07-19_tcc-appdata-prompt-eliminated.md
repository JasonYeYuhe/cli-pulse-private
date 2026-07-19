# PROJECT_FIX 2026-07-19 — the "access data from other apps" prompt, eliminated at the source

## Symptom (P0, user-facing, recurring)

macOS repeatedly showed **“CLI Pulse” would like to access data from other apps.** The dialog
returned on every helper start and after every app update. Clicking **Don't Allow** never made it
stop; clicking **Allow** would not have either.

## Root cause — established from the live TCC database, not inferred

`kTCCServiceSystemPolicyAppData` is **path-prefix triggered**: the kernel consults `tccd` only when
an `open(2)`/`bind(2)` lands under `~/Library/Containers/*`, `~/Library/Group Containers/*`, or
another app's Application Support. The bundled Swift helper is **unsandboxed and launchd-started**,
and kept its rendezvous (UDS socket + auth token), its pairing read, and a snapshot write inside
`~/Library/Group Containers/group.yyh.CLI-Pulse/`. Every start therefore generated a consult.

Three explanations were proposed during the investigation. **Two were mine and both were wrong**;
the TCC database settled it:

| hypothesis | verdict |
|---|---|
| "re-signing on update invalidates the grant" | **false** — every CLI Pulse row has `csreq NULL`; no code requirement is pinned |
| "the app-groups entitlement will exempt us" | **false** — the `.pkg` helper *carries* that entitlement and still has a `reason=2` (user-consent) AppData row, i.e. it prompted |
| **the bundled helper has ZERO rows** | **true** — its answer is never persisted, so it re-asks forever |

That third finding is the actual bug and it also killed the cheap fix (adding an entitlement) using
data already on the machine — which is why no `tccutil reset` experiment was needed.

Measured, launchd-spawned, same uid (macOS 26.5):

| location | first touch | second | can prompt? |
|---|---|---|---|
| app-group container | 1–10 s, >20 s tail | ~0.02 s | **yes, forever** |
| `~/.clipulse` | **29 ms** | 28 ms | **structurally impossible** |

## Fix

Move the bundled DEVID helper's runtime state to `~/.clipulse` — a plain home dotdir under no
protected prefix. **No consult is generated at all**: the helper is not "allowed", it is *never
evaluated*. That distinction is the whole point — there is no grant to lose, nothing to re-approve
on update, and no dialog to dismiss.

Moving the socket alone would have fixed **nothing**. Three further touches had to go:

1. **the pairing read** — `cloudConfigSnapshot()`'s default Layer‑1 reader is
   `AppGroupConfigReader.readPairing` → `UserDefaults(suiteName:)` → inside the container. Now
   passed a nil reader, which is a *functional no-op for this binary*: Layer 1 needs the
   `helperSecret` from the app-group Keychain, and the helper ships **empty entitlements**, so it
   could never succeed. It falls through to Layer 2 (`~/.cli-pulse-helper.json`, outside the
   container) exactly as before.
2. **two more call sites on the cloud tick** (`main.swift`) — found by the new CI guard, not by
   inspection.
3. **`ClaudeSnapshotWriter`'s container destination** — also found by the guard.

Deliberately **not** done: mirroring the pairing into `~/.clipulse`. That would put a cloud
credential in plaintext outside the container to enable a path this binary cannot use.

### Security

A home dotdir is weaker than a container in exactly one way: **another local process can create it
first**. `RuntimeRoot.secureRoot()` opens the directory `O_NOFOLLOW` and validates through the **fd**
(`fstat`/`fchmod`), refusing a symlink, a non-directory, or foreign ownership. A root we *own* with
loose permissions is **tightened to 0700, not refused** — `~/.clipulse` already exists at 0755 on
real installs (`ClaudeSnapshotWriter` created it under the default umask years ago), so refusing it
would have failed token rotation on essentially every machine: empty token → all gated RPCs fail
closed → local session control silently dead. Found by *running* the binary, not by reading it.

Threat model stated honestly in-code: swapping that symlink needs write access to `$HOME`, i.e. the
same uid, which can read the token directly anyway. The **ownership** check is the load-bearing
control; fd pinning is defence in depth.

### App side

`LocalSessionControlClient` resolves between `~/.clipulse` and the container by **connecting**,
never by checking whether the socket file exists — an AF_UNIX node outlives its process, so an
existence check pins the app to a dead socket and hides a healthy helper. Socket and token always
come from the same base. `ClaudeHelperContract.snapshotPath` now picks the **freshest** copy across
both directories; a fixed preference is wrong in both directions.

### CI guard

`scripts/check_helper_no_container_touch.sh` fails the build if the daemon path can touch a
protected prefix again — including **indirect** access via `AuthToken.containerPath()`. This failure
class is invisible in CI and unit tests; it only appears as a dialog on a user's Mac. **It found two
real holes on its first run**, and a third (the P0 below) after being hardened.

## Review

`agy` and `codex` **independently converged on the same P0**: `ManagedSessionManager` still injected
the *old* container socket into every managed session's environment, so the unsandboxed approval hook
would connect into the container — re-arming the prompt **and** silently breaking every structured
approval. The fix would have accomplished nothing. Also fixed from review: a TOCTOU
(`lstat`→`chmod` follows a swapped symlink), a latent CI break (an existing test passed only because
the `.pkg` helper happened to be listening), freshest-wins never reaching the read path, and an
override that could re-arm the prompt through the escape hatch.

## Verification

- **`lsof` on the live daemon: zero open files under Group Containers**; only rendezvous is the
  private-root socket; container mtime untouched by the run.
- **`log stream` on tccd across install + restart: zero `SystemPolicyAppData` events.**
- **TCC AppData rows unchanged, 19 → 19**, across a full daemon lifecycle. A new row — even an
  allow — would mean a consult fired.
- Agent pid stable (no KeepAlive churn); authenticated UDS call with the same-base token returns ok.
- Every new test verified to **fail** against the code it guards.

## Shipped

- **PR #372** → `main` (squashed `5c55918`).
- **DEVID 1.41.2 (build 94)** = 1.41.1 + this fix only, cherry-picked onto the 1.41.1 release base
  (**not** `main`, which carries two unshipped epics). Published to `cli-pulse-distrib`; tag
  `app-v1.41.2`.
- **App Store: deliberately untouched.** The MAS build *strips* this helper entirely (ASC error
  90296 — MAS rejects unsandboxed nested binaries), so the fix does not apply there and a submission
  would burn a review cycle for nothing.

## Post-publish incident (same day)

The first upload of the 1.41.2 DMG to GitHub was **silently truncated by 160,506 bytes**
(24,800,930 vs 24,961,436) with `state=uploaded` and no error. Since the updater verifies SHA before
trusting, that would have made the update **rejected for every user** — a silently dead release. The
initial roundtrip check *passed* and hid it, because the manifest's `url` still points at the
pre-org-rename owner path, which served the correct object while the canonical org path served the
truncated one. Re-uploaded and verified via both paths.

**Mandatory post-publish gate now:** compare GitHub's own recorded asset size against the local file
(`gh api .../releases/tags/<tag> --jq '.assets[]|.size'` vs `stat -f%z`) **and** SHA-verify a
download via both the manifest URL and the canonical URL. Checking the manifest URL alone is not
sufficient.

## Not done here

- The `.pkg` Python helper still uses the container. It is entitled, has a working path-based grant,
  and serves the sandboxed MAS app which genuinely needs the container. Out of scope.
- The bundled helper's `hello` reports its own version line (`kHelperVersion`, currently 1.23.0), not
  the app version. Expected; do not "fix".

See memory `feedback_launchd_tcc_appdata_consult`, `project_devid_1_41_1_shipped`.
