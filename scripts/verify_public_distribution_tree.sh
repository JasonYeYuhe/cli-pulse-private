#!/usr/bin/env bash
#
# verify_public_distribution_tree.sh
#
# Asserts that a given git tree (a ref, a commit SHA, or the working tree)
# contains ONLY files allowed in the public CLI Pulse distribution repo
# (JasonYeYuhe/cli-pulse). Refuses anything that would expose product source,
# helper internals, backend schema, internal planning docs, or test fixtures.
#
# Run before pushing public/main, before creating public release tags, and
# from the pre-push hook (.githooks/pre-push).
#
# Usage:
#   scripts/verify_public_distribution_tree.sh                    # defaults to HEAD
#   scripts/verify_public_distribution_tree.sh <ref-or-sha>       # any git ref
#   scripts/verify_public_distribution_tree.sh public/main
#   scripts/verify_public_distribution_tree.sh v1.10.7
#
# Exit codes:
#   0 = clean
#   1 = forbidden path(s) found
#   2 = invalid input / git error

set -u

usage() {
    cat <<USAGE
Usage: $(basename "$0") [ref-or-sha]

Verifies that a git tree contains only public-distribution files.
With no argument, defaults to HEAD.
USAGE
}

if [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ]; then
    usage
    exit 0
fi

REF="${1-HEAD}"

# Forbidden top-level paths and patterns. Matched as anchored prefixes
# unless otherwise noted.
FORBIDDEN_PREFIXES=(
    "CLI Pulse Bar/"
    "CLI Pulse Bar iOS/"
    "CLI Pulse Bar Watch/"
    "CLI Pulse Widgets/"
    "CLIPulseCore/"
    "CLIPulseHelper/"
    "helper/"
    "backend/"
    "archive/"
    "android/"
    "scripts/"
    "codexbar/"
    "screenshots/"
)

# Forbidden filenames (exact match anywhere in the tree).
FORBIDDEN_FILENAMES=(
    "AGENTS.md"
    "BRANCHING.md"
    "RELEASE_WORKFLOW.md"
    "MERGE_AND_PUBLISH_RULES.md"
    "TASK_START_PROMPT.md"
    "REPO_VISIBILITY_STRATEGY.md"
)

# Forbidden glob/suffix patterns matched against the full path.
FORBIDDEN_GLOBS=(
    "*.xcodeproj"
    "*.xcodeproj/*"
    "PROJECT_*"
    "*/PROJECT_*"
)

# List the candidate file paths for the tree under inspection.
list_paths() {
    # Any git ref, tag, or commit SHA. Default REF=HEAD covers
    # "the most recently committed state" without forcing the caller to
    # name a ref explicitly.
    git ls-tree -r --name-only "$REF"
}

paths_output="$(list_paths 2>&1)"
list_status=$?
if [ $list_status -ne 0 ]; then
    echo "error: could not list tree for '${REF:-<working tree>}': $paths_output" >&2
    exit 2
fi

violations=()

while IFS= read -r path; do
    [ -z "$path" ] && continue

    # Forbidden top-level prefixes.
    for prefix in "${FORBIDDEN_PREFIXES[@]}"; do
        case "$path" in
            "$prefix"*)
                violations+=("[prefix:$prefix] $path")
                continue 2
                ;;
        esac
    done

    # Forbidden exact filenames (basename match).
    base="${path##*/}"
    for fname in "${FORBIDDEN_FILENAMES[@]}"; do
        if [ "$base" = "$fname" ]; then
            violations+=("[filename:$fname] $path")
            continue 2
        fi
    done

    # Forbidden globs/suffix patterns (whole-path match).
    for glob in "${FORBIDDEN_GLOBS[@]}"; do
        # shellcheck disable=SC2053
        case "$path" in
            $glob)
                violations+=("[glob:$glob] $path")
                continue 2
                ;;
        esac
    done
done <<< "$paths_output"

scope="${REF:-<working tree>}"
total_files=$(printf '%s\n' "$paths_output" | sed '/^$/d' | wc -l | tr -d ' ')

if [ ${#violations[@]} -eq 0 ]; then
    echo "OK: $scope is distribution-clean ($total_files files)"
    exit 0
fi

echo "FAIL: $scope contains forbidden paths (${#violations[@]} violations of $total_files files)" >&2
for v in "${violations[@]}"; do
    echo "  $v" >&2
done
echo "" >&2
echo "Refusing to treat this tree as a public-distribution tree." >&2
echo "If this is the private source workspace, push to 'origin' instead, not 'public'." >&2
exit 1
