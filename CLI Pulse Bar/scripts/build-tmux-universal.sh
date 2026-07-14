#!/bin/bash
# Build a self-contained, universal, Developer-ID-signed `tmux` for bundling in
# the CLI Pulse .app (M4.4b — external-session control needs tmux, and clean
# Macs have none; a Homebrew dep is not shippable).
#
# The binary is intentionally minimal-dependency: libevent is STATIC-linked and
# utf8proc is disabled, so the only dylibs it loads are system libraries present
# on every macOS install (libSystem, libncurses, libresolv). Verified by the
# `otool -L` gate below — a non-/usr/lib dependency fails the build.
#
# Usage:  build-tmux-universal.sh [output-path]
#   default output: CLI Pulse Bar/Resources/bin/tmux (git-ignored build artifact;
#   the app build copies it into Contents/Helpers/tmux next to the helper).
#
# Requires: Xcode CLT (clang, lipo, codesign), autoconf-built configure in the
# release tarballs (no autoreconf needed), and — for the x86_64 slice on Apple
# Silicon — Rosetta 2 so the tarball's configure test programs run.
set -euo pipefail

TMUX_VER="3.5a"
LIBEVENT_VER="2.1.12-stable"
MIN_MACOS="11.0"
SIGN_ID="${TMUX_SIGN_IDENTITY:-Developer ID Application: Yuhe Ye (KHMK6Q3L3K)}"

# Pinned SHA-256 of the official release tarballs (integrity beyond TLS). These
# are NON-OVERRIDABLE constants on purpose — an env override would let a
# compromised build environment point at a substituted tarball and still get a
# Developer-ID signature (review: codex). Bump deliberately with the version.
LIBEVENT_SHA="92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb"
TMUX_SHA="16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${1:-$REPO_ROOT/Resources/bin/tmux}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/clip-tmux.XXXXXX")"
SDK="$(xcrun --show-sdk-path)"
trap 'rm -rf "$WORK"' EXIT

fetch() {  # url sha  (downloads to $WORK/src, verifies checksum)
  local url="$1"
  local sha="$2"
  local f="$WORK/src/$(basename "$url")"
  mkdir -p "$WORK/src"
  curl -fsSL -o "$f" "$url"
  local got
  got="$(shasum -a 256 "$f" | awk '{print $1}')"
  echo "  $(basename "$f"): $got"
  # Fail HARD if no checksum is pinned — never silently ship an unverified
  # download (review: agy).
  if [ -z "$sha" ]; then
    echo "!! no pinned checksum for $(basename "$f") — refusing to build"; exit 1
  fi
  if [ "$sha" != "$got" ]; then
    echo "!! checksum mismatch for $f (expected $sha)"; exit 1
  fi
}

build_arch() {  # arch
  local arch="$1" cc lev
  cc="clang -arch $arch -mmacosx-version-min=$MIN_MACOS -isysroot $SDK"
  lev="$WORK/libevent-$arch"
  # Run `configure` NATIVELY for the target arch instead of a `--host` cross-
  # compile: arm64 directly, x86_64 under Rosetta 2 (`arch -x86_64`). A --host
  # cross-compile SKIPS autoconf's AC_RUN feature tests and guesses their
  # results, which can mis-detect a feature and produce a subtly-broken slice;
  # running configure natively (Rosetta executes the x86_64 test programs) gets
  # correct detection. `make` runs unprefixed — only the compiler arch (via
  # CC/-arch) determines the output arch (review: agy).
  local ARCH_PREFIX=()
  [ "$arch" = "x86_64" ] && ARCH_PREFIX=(arch -x86_64)

  # static libevent
  ( cd "$WORK/src" && rm -rf "libevent-$arch" && tar xf "libevent-$LIBEVENT_VER.tar.gz" \
      && mv "libevent-$LIBEVENT_VER" "libevent-$arch" && cd "libevent-$arch" \
      && ${ARCH_PREFIX[@]+"${ARCH_PREFIX[@]}"} ./configure --prefix="$lev" --disable-shared --enable-static \
           --disable-openssl --disable-samples --disable-libevent-regress \
           --disable-debug-mode CC="$cc" >/dev/null \
      && make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null )

  # tmux against static libevent + system ncurses, no utf8proc
  ( cd "$WORK/src" && rm -rf "tmux-$arch" && tar xf "tmux-$TMUX_VER.tar.gz" \
      && mv "tmux-$TMUX_VER" "tmux-$arch" && cd "tmux-$arch" \
      && ${ARCH_PREFIX[@]+"${ARCH_PREFIX[@]}"} ./configure --disable-utf8proc CC="$cc" \
           CFLAGS="-arch $arch -mmacosx-version-min=$MIN_MACOS -isysroot $SDK -I$lev/include -O2" \
           LDFLAGS="-arch $arch -mmacosx-version-min=$MIN_MACOS -isysroot $SDK -L$lev/lib" \
           LIBEVENT_CFLAGS="-I$lev/include" LIBEVENT_LIBS="$lev/lib/libevent.a" >/dev/null \
      && make -j"$(sysctl -n hw.ncpu)" >/dev/null && cp tmux "$WORK/tmux-$arch" )
  echo "  built $arch"
}

echo "== fetch sources =="
fetch "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VER/libevent-$LIBEVENT_VER.tar.gz" "$LIBEVENT_SHA"
fetch "https://github.com/tmux/tmux/releases/download/$TMUX_VER/tmux-$TMUX_VER.tar.gz" "$TMUX_SHA"

echo "== build arm64 =="; build_arch arm64
echo "== build x86_64 =="; build_arch x86_64

echo "== lipo → universal =="
mkdir -p "$(dirname "$OUT")"
xcrun lipo -create "$WORK/tmux-arm64" "$WORK/tmux-x86_64" -output "$OUT"
xcrun lipo -info "$OUT"

echo "== dependency gate (system-only) =="
# `otool -L` on a fat binary emits a `<path> (architecture X):` HEADER line per
# slice plus tab-indented dependency lines. Isolate EVERY indented dependency
# line (matching the leading whitespace, NOT a leading `/`, so an @rpath/
# @loader_path/relative dep can't slip past) and fail unless it lives under
# /usr/lib or /System (review: agy + codex).
if otool -L "$OUT" | grep -E '^[[:space:]]' | grep -qvE '^[[:space:]]+(/usr/lib/|/System/)'; then
  echo "!! non-system dylib dependency found:"; otool -L "$OUT"; exit 1
fi
otool -L "$OUT" | grep -E '^[[:space:]]' | sort -u

echo "== codesign (Developer ID, hardened runtime, timestamped) =="
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$OUT"
codesign --verify --strict --verbose=2 "$OUT"
codesign -dv --verbose=2 "$OUT" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|flags=.*runtime" || true

echo "== done: $OUT ($("$OUT" -V)) =="
echo "NOTE: notarization happens at the .app level (this binary ships inside the"
echo "signed+notarized app bundle); no standalone notarization needed."
