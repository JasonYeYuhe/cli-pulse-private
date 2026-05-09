"""ANSI / VT escape stripper for helper output uploads.

Python port of `CLIPulseCore/Sources/CLIPulseCore/AnsiSanitizer.swift`.
The Swift sanitizer runs client-side in the macOS / iOS apps that
consume `remote_session_events` rows, so historically the helper just
shipped raw PTY bytes upstream. That worked until v1.16.1 caught a
regex gap in the client (CSI sequences with intermediate bytes like
DECSCUSR `\x1b[0 q` were leaking through), at which point we noticed
the iPhone build can't easily be hot-fixed — App Store review takes
~24 h. Stripping helper-side means clients don't need to be rebuilt
to benefit.

Why a port and not just a regex inline at the call site:
  * The same patterns are needed by the local-broker publish path AND
    the Supabase upload path (both sites in `remote_agent.py`).
  * Future helper-only consumers (e.g. log scrubbers) can reuse it.
  * Shared module keeps the Swift / Python regexes in lockstep —
    grep parity becomes easy.

Patterns covered (parity with Swift `AnsiSanitizer.csiPattern` etc.):
  * CSI: ``ESC [ <param 0x30-0x3F>* <intermediate 0x20-0x2F>* <final 0x40-0x7E>``
  * OSC: ``ESC ] ... BEL`` or ``ESC ] ... ESC \\``
  * Stray ESC dispatcher: ``ESC <single private-use char>``
  * Bare BEL (``\\a``)

Things it deliberately does NOT do:
  * No cursor emulation — `\\r` / `\\b` pass through.
  * No charset switching (G0/G1) — providers don't use it.
  * No DCS / APC sequences — providers don't emit them.
"""
from __future__ import annotations

import re

# CSI: ESC [ <params 0x30-0x3F>* <intermediates 0x20-0x2F>* <final 0x40-0x7E>
# v1.16.2: include `[ -/]*` intermediate slot per ECMA-48 so DECSCUSR
# (`\x1b[0 q`) and similar forms are matched. The pre-fix regex required
# a final byte right after params and skipped at the SPACE intermediate.
_CSI_PATTERN = re.compile(r"\x1b\[[0-9;?<>=]*[ -/]*[@-~]")

# OSC: ESC ] ... BEL  OR  ESC ] ... ESC \
_OSC_PATTERN = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")

# Stray ESC followed by a single dispatcher (ESC 7 / ESC 8 save/restore
# cursor, ESC = / ESC > keypad mode, etc.). Same alphabet as the Swift
# version's strayEscPattern.
_STRAY_ESC_PATTERN = re.compile(r"\x1b[7-9=>NOPVWXZ\\]?")


def strip(raw: str) -> str:
    """Remove ANSI / VT escape sequences from `raw`.

    Returns a string safe to render as plain monospace text. Preserves
    printable characters, line breaks, tabs, and literal spaces.
    Pure / idempotent — `strip(strip(x)) == strip(x)`.
    """
    if not raw:
        return raw
    s = raw
    s = _CSI_PATTERN.sub("", s)
    s = _OSC_PATTERN.sub("", s)
    s = _STRAY_ESC_PATTERN.sub("", s)
    # Drop bare BEL — usually the OSC trailer that the regex above
    # already consumed, but Codex emits standalone BELs too (status
    # area / activity beeps).
    s = s.replace("\x07", "")
    return s
