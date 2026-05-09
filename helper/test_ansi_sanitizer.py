"""Tests for helper/ansi_sanitizer.py — parity with the Swift
`AnsiSanitizerTests` suite under CLIPulseCore."""
from __future__ import annotations

import pytest

from ansi_sanitizer import strip


class TestSGRColours:
    def test_sgr_colour_codes_are_stripped(self):
        assert strip("\x1b[38;2;215;119;87mhello\x1b[39m") == "hello"

    def test_sgr_reset_only(self):
        assert strip("\x1b[m") == ""

    def test_combined_attributes(self):
        assert strip("\x1b[1;31mbold red\x1b[0m") == "bold red"


class TestCursorMoves:
    """v1.16.2: cursor-move and erase CSIs are SPATIAL — TUIs use them
    where literal whitespace would have gone, so they're replaced with
    a single space (which then collapses into adjacent spaces). Without
    this, "official\\x1b[3CCLI" collapses to "officialCLI" instead of
    "official CLI". Parity with Swift `stripJoiningWithSpaces`."""

    def test_cuf_recovers_word_boundary(self):
        # `\x1b[3C` — cursor forward 3 → single space (preserve gap)
        assert strip("a\x1b[3Cb") == "a b"

    def test_cup_recovers_word_boundary(self):
        # `\x1b[2;5H` — cursor position 2,5
        assert strip("hello\x1b[2;5Hworld") == "hello world"

    def test_erase_line_treated_as_spatial(self):
        assert strip("before\x1b[Kafter") == "before after"

    def test_adjacent_cursor_moves_collapse(self):
        # Multiple consecutive moves shouldn't produce visible
        # whitespace runs.
        assert strip("a\x1b[1C\x1b[2D\x1b[3Bb") == "a b"


class TestOSC:
    def test_osc_with_bel_terminator(self):
        # Window title set
        assert strip("\x1b]0;CLI Pulse\x07ready") == "ready"

    def test_osc_with_st_terminator(self):
        # ESC \ string terminator variant
        assert strip("\x1b]0;CLI Pulse\x1b\\ready") == "ready"


class TestStrayEsc:
    def test_save_cursor(self):
        assert strip("a\x1b7b\x1b8c") == "abc"


class TestPlainText:
    def test_pass_through(self):
        assert strip("hello world\nline two\tindented") == "hello world\nline two\tindented"

    def test_empty(self):
        assert strip("") == ""

    def test_idempotent(self):
        raw = "x\x1b[31my\x1b[0mz\x1b[1Cw"
        once = strip(raw)
        twice = strip(once)
        assert once == twice


class TestDECSCUSR_v1_16_2_regression:
    """The user-reported leak that motivated this module: DECSCUSR
    sequences (`\\x1b[N SP q`) include an intermediate SPACE byte
    before the final `q`. Pre-fix client-side regex required the final
    byte right after params and skipped at the space, leaking `[0 q`
    fragments into the iPhone Codex transcript view."""

    @pytest.mark.parametrize("style", [0, 1, 2, 3, 4, 5, 6])
    def test_decscusr_styles_strip_cleanly(self, style: int):
        raw = f"x\x1b[{style} qy"
        assert strip(raw) == "xy"

    def test_multiple_decscusr_in_one_payload(self):
        # Mirrors what the user actually saw — Codex repeats the
        # cursor-style command on every redraw. DECSCUSR's final byte
        # `q` is NOT in the cursor-move alphabet so it falls through
        # to the strip-everything CSI pass; the surrounding inline
        # spaces then collapse to one.
        raw = "?  \x1b[0 q \x1b[0 q \x1b[0 q\nnext line"
        assert strip(raw) == "? \nnext line"


class TestPasted_hello:
    """Real production sample that originally drove the Swift Ansi
    Sanitizer test suite — Claude's `❯ hello` echo buried in cursor
    repaint. Verifies the Python port handles the same input."""

    def test_pasted_hello_becomes_readable(self):
        raw = "\x1b[2D\x1b[3B\r\x1b[2C\x1b[3Ahello                       \r"
        cleaned = strip(raw)
        assert "hello" in cleaned
        assert "\x1b" not in cleaned
