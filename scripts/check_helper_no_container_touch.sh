#!/bin/bash
# Fail the build if the bundled Swift helper's DAEMON path can touch a
# TCC-protected prefix again.
#
# WHY THIS EXISTS
# ---------------
# `kTCCServiceSystemPolicyAppData` is path-prefix triggered: the kernel consults
# tccd when an open(2)/bind(2) lands under ~/Library/Containers/*,
# ~/Library/Group Containers/*, or another app's Application Support. The bundled
# helper is unsandboxed and launchd-started, so ANY such touch produces the
# "CLI Pulse would like to access data from other apps" dialog — and on this
# binary the answer is never persisted (verified: zero TCC rows despite repeated
# prompting), so it re-asks forever. The owner hit exactly that.
#
# The fix moved the socket, the auth token and the pairing read out of the
# container to ~/.clipulse. That fix is only one careless line from being undone,
# and the failure is INVISIBLE in CI and in unit tests — it only shows up as a
# dialog on a real user's Mac. Hence this guard.
#
# The cost of a false negative is a user-facing permission-prompt loop. The cost
# of a false positive is thirty seconds adding an exemption below. Bias hard
# toward failing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_DIR="$ROOT/HelperSwift/Sources"

# Files allowed to MENTION the container:
#  - AppGroupConfigReader.swift : the entitled-variant reader, deliberately no
#                                longer on the daemon path (kept for the app/tests)
#  - ContainerAccess.swift      : documents the measured consult + the hang guard
#  - AuthToken.swift            : retains containerPath()/legacyTokenPath() so the
#                                app-side migration can still find + clean up the
#                                legacy location
#  - RuntimeRoot.swift          : explains, in prose, what it replaced
ALLOWED_RE='(AppGroupConfigReader|ContainerAccess|AuthToken|RuntimeRoot)\.swift'

# Patterns that indicate a real protected-prefix touch.
PATTERNS=(
  'Group Containers'
  'containerURL\(forSecurityApplicationGroupIdentifier'
  'UserDefaults\(suiteName'
  'Library/Containers'
  # INDIRECT touches. The first version of this guard matched only literal path
  # strings and therefore MISSED the worst real bug in the change it was written
  # to protect: ManagedSessionManager injected
  # `AuthToken.containerPath()/clipulse-helper.sock` into every managed session's
  # environment, so the unsandboxed hook subprocess connected into the container —
  # re-arming the prompt AND failing to reach the daemon (silently breaking remote
  # approvals). Caught by review, not by this script. Match the accessors too.
  'AuthToken\.containerPath'
  'AuthToken\.legacyTokenPath'
  'ClaudeHelperContract\.appGroupHelperDir'
)

fail=0
for pat in "${PATTERNS[@]}"; do
  # Strip // comments before matching so prose can explain the history freely.
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file="${hit%%:*}"
    if [[ "$file" =~ $ALLOWED_RE ]]; then continue; fi
    echo "error: bundled helper may touch a TCC-protected prefix again"
    echo "       $hit"
    echo "       pattern: $pat"
    fail=1
  done < <(grep -rnE "$pat" "$DAEMON_DIR" --include='*.swift' 2>/dev/null \
             | sed 's://.*$::' | grep -E "$pat" || true)
done

# The daemon entrypoint must never use the container-reading default overload.
# Any cloudConfigSnapshot call on the daemon path MUST pass appGroupReader
# explicitly. Matching only the literal "()" was brittle (review: agy): it passed
# for `cloudConfigSnapshot( )` and, worse, for
# `cloudConfigSnapshot(legacyJSON: nil)` — which leaves the container-reading
# appGroupReader at its default. So: find every call, and flag any that does not
# name appGroupReader.
if grep -nE 'cloudConfigSnapshot[[:space:]]*\(' "$DAEMON_DIR/cli_pulse_helper/main.swift" 2>/dev/null \
     | sed 's://.*$::' | grep -E 'cloudConfigSnapshot[[:space:]]*\(' \
     | grep -qv 'appGroupReader'; then
  echo "error: main.swift calls cloudConfigSnapshot() with its DEFAULT reader."
  echo "       That default is AppGroupConfigReader.readPairing, which reads"
  echo "       UserDefaults(suiteName:) inside the app-group container and"
  echo "       re-arms the permission prompt. Pass appGroupReader: { nil }."
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "✓ bundled helper daemon path is free of TCC-protected-prefix touches"
fi
exit $fail
