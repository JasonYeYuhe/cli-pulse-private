# PyInstaller spec for v1.16 Developer-ID notarized .pkg distribution.
#
# Diverges from `cli_pulse_helper.spec` (Phase 4D embedded-in-app one-file
# bundle) in one critical way: this spec uses `--onedir` mode (EXE +
# COLLECT) so each Mach-O binary inside the bundle has its own signature.
# That's required for `xcrun notarytool` to accept the .pkg —
# single-file pyinstaller binaries extract to /tmp at runtime and the
# extracted .so files don't carry signatures, which Gatekeeper rejects
# on first launch of a stapled pkg.
#
# Build with:
#   cd helper
#   pyinstaller --clean --noconfirm cli_pulse_helper_pkg.spec
#
# Output: helper/dist/cli_pulse_helper/ — directory containing
#   cli_pulse_helper           (the entry executable)
#   _internal/                 (Python interpreter + stdlib + cryptography)
#       Python                 (Mach-O, signed by build_helper_pkg.sh)
#       libcrypto.dylib        (Mach-O, signed)
#       cryptography/...       (Mach-O .so files, signed)
#       cli_pulse_helper.pyc   (script bytecode)
#       ...
#
# Everything Mach-O inside _internal/ + the entry executable gets signed
# individually by `scripts/build_helper_pkg.sh` after this spec runs.
# DO NOT use `codesign --deep` — it produces stale signatures that fail
# notarization. Sign each binary explicitly.
#
# See PROJECT_PLAN_v1.16_phase4e_helper_production.md §1.3 for the
# downstream signing + notarization pipeline.

# ruff: noqa: F821  -- spec file injects `Analysis` etc. globally

block_cipher = None


a = Analysis(
    ["cli_pulse_helper.py"],
    pathex=["."],
    binaries=[],
    datas=[],
    hiddenimports=[
        # provider_adapters/__init__.py loads adapters by module name
        # at runtime; explicit hint so PyInstaller's static analysis
        # bundles them.
        "provider_adapters",
        "provider_adapters.base",
        "provider_adapters.claude",
        "provider_adapters.codex",
        "provider_adapters.shell",
        # transports package — POSIX PTY path on macOS, plus v1.17
        # CodexExec subprocess-per-turn path + multiplex router.
        "transports",
        "transports.base",
        "transports.posix_pty",
        "transports.codex_exec",
        "transports.multiplex",
        # cryptography backends loaded by name in system_collector.py
        # (PBKDF2HMAC, AES). PyInstaller's hook bundles the OpenSSL
        # bindings when these are referenced explicitly.
        "cryptography.hazmat.backends.openssl",
        "cryptography.hazmat.bindings._rust",
        # provider_spawners is loaded dynamically by hello-reply +
        # start_session paths in local_session_server.py.
        "provider_spawners",
        # local_session_server is the UDS server entry — wired by
        # daemon() in cli_pulse_helper.py via runtime import.
        "local_session_server",
        "local_executor",
        "local_events",
        "local_approvals",
        "local_auth_token",
        "remote_agent",
        "remote_hook",
        # R0 (S3): the terminal-broadcast producer is imported LAZILY inside a
        # nested conditional in cli_pulse_helper.py (`from realtime_broadcast
        # import ...` under `if remote_realtime_broadcast_enabled`), which
        # PyInstaller's static graph can miss. Now that the gate defaults ON, a
        # missing module would ImportError → silently no broadcast. Pin it.
        "realtime_broadcast",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

# v1.16 onedir mode: EXE + COLLECT so each Mach-O is a separate file
# that can be signed individually.
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,    # binaries go into COLLECT instead
    name="cli_pulse_helper",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,             # daemon writes to stderr; keep tty
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,         # host arch; build_helper_pkg.sh runs once per arch
    codesign_identity=None,   # signed downstream by build_helper_pkg.sh
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="cli_pulse_helper",
)
