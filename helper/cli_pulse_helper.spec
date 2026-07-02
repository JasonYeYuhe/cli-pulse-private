# PyInstaller spec for the CLI Pulse helper daemon.
#
# Produces a single self-contained binary at
# `helper/dist/cli_pulse_helper` that bundles a Python interpreter +
# the `cryptography` package (the only real 3rd-party dependency)
# alongside every helper module in this directory tree. The macOS
# app target ships this binary as an embedded LaunchAgent so users
# don't need a Python install + GitHub checkout to use the local
# fast-path Sessions feature.
#
# Build with:
#   cd helper
#   pyinstaller --clean --noconfirm cli_pulse_helper.spec
#
# Output: helper/dist/cli_pulse_helper (single file, ~30 MB).
#
# Universal2 (arm64 + x86_64) handling: PyInstaller's `target_arch`
# only emits the host-arch binary unless invoked on each arch and
# `lipo`-merged. Phase B intentionally targets the build host's
# arch only; the macOS app target's `Run Script` build phase wraps
# this command and runs `lipo -create` when both arch outputs exist.
# v1.13 release goal: arm64-only first (Apple Silicon majority);
# x86_64 fat-binary follow-up if the request volume justifies it.

# ruff: noqa: F821  -- spec file injects `Analysis` etc. globally

block_cipher = None


a = Analysis(
    ["cli_pulse_helper.py"],
    pathex=["."],
    binaries=[],
    # Helper modules are discovered automatically via static import
    # analysis; explicit datas only needed for runtime-resolved
    # files. provider_adapters/ contains parser modules imported
    # at runtime — pinned via hiddenimports below.
    datas=[],
    hiddenimports=[
        # provider_adapters/__init__.py loads adapters by module
        # name at runtime; hint PyInstaller about each adapter so
        # the static analysis doesn't drop them.
        "provider_adapters",
        "provider_adapters.base",
        "provider_adapters.claude",
        "provider_adapters.codex",
        "provider_adapters.shell",
        # transports package: PTY transports loaded by platform at
        # runtime (POSIX path on macOS).
        "transports",
        "transports.base",
        "transports.posix_pty",
        # cryptography backends loaded by name in
        # `system_collector.py` (PBKDF2HMAC, AES); ensure
        # PyInstaller's hook bundles the OpenSSL bindings.
        "cryptography.hazmat.backends.openssl",
        "cryptography.hazmat.bindings._rust",
        # R0 (S3): lazily imported terminal-broadcast producer (see the pkg
        # spec note). Pinned here too for parity (Codex P1-6) — cheap insurance
        # even though build_helper_pkg.sh's spec is the shipped one.
        "realtime_broadcast",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    # We do NOT exclude `tkinter`, `matplotlib`, etc. by hand —
    # PyInstaller already prunes unused stdlib modules and the
    # helper imports neither.
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="cli_pulse_helper",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,            # daemon writes to stderr; keep tty
    disable_windowed_traceback=False,
    argv_emulation=False,
    # `target_arch=None` = host arch only. macOS app build phase
    # handles the universal2 lipo-merge separately.
    target_arch=None,
    codesign_identity=None,  # signed later by Xcode build phase
    entitlements_file=None,
)
