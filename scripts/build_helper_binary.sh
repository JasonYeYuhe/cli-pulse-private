#!/bin/bash
# Phase 4 helper bundle build script.
#
# Invoked by the CLI Pulse Bar Xcode "Run Script" build phase to produce
# a self-contained `cli_pulse_helper` binary that gets embedded into the
# .app's Contents/Helpers/. The frozen binary lets the macOS app launch
# the helper as a LaunchAgent (via SMAppService.agent) without requiring
# users to install Python or clone this repo.
#
# Inputs (env, set by Xcode build phase or manually):
#   * `PROJECT_ROOT`       — repo root (defaults to script's grandparent)
#   * `BUILT_PRODUCTS_DIR` — Xcode's intermediate build output (set during
#                            Xcode invocation; not used when run manually)
#   * `CONFIGURATION`      — Debug | Release (Xcode-set; controls
#                            whether to skip rebuild on cached output)
#
# Outputs:
#   * `helper/dist/cli_pulse_helper` — single-file frozen binary
#                                        (~12 MB arm64)
#
# Behavior notes:
#   * arm64-only by default. Universal2 (arm64 + x86_64) requires
#     running this script under each arch and `lipo`-merging — that
#     work lands when v1.13 actually targets x86_64 distribution
#     (initial release is Apple Silicon only).
#   * Caching: skips the rebuild when `dist/cli_pulse_helper` is newer
#     than every .py file under `helper/`. This keeps incremental
#     Xcode builds fast (~1 s) while a full rebuild takes ~20 s.
#   * Failure mode: any pyinstaller or pip error propagates; the
#     Xcode build phase will fail loudly so the developer sees it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
HELPER_DIR="$PROJECT_ROOT/helper"
SPEC_FILE="$HELPER_DIR/cli_pulse_helper.spec"
OUTPUT_BIN="$HELPER_DIR/dist/cli_pulse_helper"

cd "$HELPER_DIR"

# Ensure pyinstaller is available. Use the system / venv python that
# Xcode picks up — if the developer hasn't installed pyinstaller, fail
# with a clear message rather than a cryptic ImportError.
if ! python3 -c 'import PyInstaller' 2>/dev/null; then
    echo "error: PyInstaller not installed. Run: pip3 install pyinstaller" >&2
    exit 1
fi

# Cache check: rebuild when any source .py is newer than the output.
# Note: PyInstaller's own cache (build/) is independent and survives
# across runs, so re-running pyinstaller on a no-change tree is still
# fast (~5 s) but we want incremental Xcode builds to be sub-second.
if [[ -f "$OUTPUT_BIN" ]]; then
    NEED_REBUILD=0
    while IFS= read -r -d '' src; do
        if [[ "$src" -nt "$OUTPUT_BIN" ]]; then
            NEED_REBUILD=1
            break
        fi
    done < <(find . -type f \( -name '*.py' -o -name '*.spec' \) -not -path './build/*' -not -path './dist/*' -not -path './__pycache__/*' -print0)
    if [[ $NEED_REBUILD -eq 0 ]]; then
        echo "build_helper_binary.sh: cached output is fresh ($OUTPUT_BIN)"
        exit 0
    fi
fi

echo "build_helper_binary.sh: building $OUTPUT_BIN ..."
python3 -m PyInstaller --clean --noconfirm "$SPEC_FILE"

if [[ ! -x "$OUTPUT_BIN" ]]; then
    echo "error: pyinstaller did not produce $OUTPUT_BIN" >&2
    exit 1
fi

echo "build_helper_binary.sh: built $OUTPUT_BIN ($(du -h "$OUTPUT_BIN" | cut -f1))"
