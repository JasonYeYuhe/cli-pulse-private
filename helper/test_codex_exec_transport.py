"""Tests for `transports.codex_exec.CodexExecTransport`.

These exercise the state machine + JSONL handling without invoking
the real `codex` binary. The integration check (real codex spawn) is
gated on `CLI_PULSE_TEST_CODEX_REAL=1`.
"""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import time

import pytest

from transports.codex_exec import (
    CodexExecTransport,
    _AGENT_PREFIX,
    _USER_PREFIX,
)


# ── helpers ─────────────────────────────────────────────────


def _drain(transport, handle, *, deadline_s: float, contains: str | None = None) -> bytes:
    """Drain bytes until either (a) `contains` substring shows up,
    (b) wall-clock deadline elapses. Returns whatever was read."""
    buf = bytearray()
    end = time.time() + deadline_s
    while time.time() < end:
        chunk = transport.read_stdout(handle, 4096)
        if chunk:
            buf.extend(chunk)
            if contains is not None and contains.encode("utf-8") in bytes(buf):
                return bytes(buf)
        else:
            time.sleep(0.02)
    return bytes(buf)


def _make_fake_codex_script(tmp_path, jsonl_lines: list[str], rc: int = 0) -> str:
    """Write a tiny shell script that emits the supplied JSONL lines
    one per line and exits with `rc`. Returns its filesystem path,
    suitable for `CLI_PULSE_CODEX_ARGV0` (which is whitespace-split,
    so we want a single-token executable path).

    We use a script-on-disk rather than inlining `python3 -c <code>`
    because the env-var-override is whitespace-tokenized, which mangles
    quoted shell arguments. A single path-to-script avoids the issue.
    """
    script = tmp_path / "fake_codex.sh"
    body_lines = ["#!/usr/bin/env bash", "set -e"]
    for line in jsonl_lines:
        # Use printf with %s to avoid any backslash-escape interpretation.
        # The line is JSON, so it never contains a literal newline.
        body_lines.append(f"printf '%s\\n' {shlex.quote(line)}")
    body_lines.append(f"exit {rc}")
    script.write_text("\n".join(body_lines) + "\n")
    script.chmod(0o755)
    return str(script)


# ── tests ───────────────────────────────────────────────────


class TestStartEmitBanner:
    def test_start_emits_banner_line(self):
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        # First read should pull the banner line.
        data = t.read_stdout(h, 4096)
        assert b"Codex exec-mode session started" in data
        t.close(h)


class TestPromptBufferingAndFlush:
    def test_input_without_newline_is_buffered(self):
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)  # drain banner

        # Type "hel" with no newline — no subprocess should spawn.
        t.write_stdin(h, b"hel")
        # No echo yet; output queue is empty.
        assert t.read_stdout(h, 4096) == b""

        t.close(h)

    def test_newline_echoes_user_prompt_and_working_marker(self, monkeypatch, tmp_path):
        # Override codex with a fake that emits empty JSONL + exits 0.
        fake = _make_fake_codex_script(tmp_path, [])
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)  # drain banner

        t.write_stdin(h, b"hello\n")
        out = _drain(t, h, deadline_s=2.0, contains="Working")
        text = out.decode("utf-8", errors="replace")
        assert _USER_PREFIX + "hello" in text
        assert "Working" in text
        t.close(h)


class TestJSONLEventHandling:
    def test_agent_message_surfaces_with_bullet_prefix(self, monkeypatch, tmp_path):
        events = [
            json.dumps({"type": "thread.started", "thread_id": "tid-abc"}),
            json.dumps({"type": "turn.started"}),
            json.dumps({
                "type": "item.completed",
                "item": {"id": "i0", "type": "agent_message", "text": "Hi there!"},
            }),
            json.dumps({"type": "turn.completed",
                        "usage": {"input_tokens": 100, "output_tokens": 5}}),
        ]
        fake = _make_fake_codex_script(tmp_path, events)
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)  # drain banner

        t.write_stdin(h, b"hello\n")
        out = _drain(t, h, deadline_s=3.0, contains="Hi there!")
        text = out.decode("utf-8", errors="replace")
        assert _USER_PREFIX + "hello" in text
        assert _AGENT_PREFIX + "Hi there!" in text
        # Thread id captured for next turn.
        state = t._payload(h)  # type: ignore[attr-defined]
        assert state.thread_id == "tid-abc"
        t.close(h)

    def test_thread_id_is_reused_across_turns(self, monkeypatch, tmp_path):
        # Two sequential calls; verify second invocation uses
        # `resume <thread_id>` — we can't observe argv directly without
        # subprocess inspection, so we assert that thread_id was set
        # after turn 1 and persists into turn 2's argv build.
        events_t1 = [
            json.dumps({"type": "thread.started", "thread_id": "tid-xyz"}),
            json.dumps({
                "type": "item.completed",
                "item": {"type": "agent_message", "text": "first reply"},
            }),
            json.dumps({"type": "turn.completed"}),
        ]
        fake = _make_fake_codex_script(tmp_path, events_t1)
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)

        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"first\n")
        _ = _drain(t, h, deadline_s=3.0, contains="first reply")

        state = t._payload(h)  # type: ignore[attr-defined]
        assert state.thread_id == "tid-xyz"

        # Build a fresh argv as if for turn 2 — should include `resume`.
        argv = t._build_exec_argv(state, "second prompt")  # type: ignore[attr-defined]
        assert "resume" in argv
        assert "tid-xyz" in argv
        t.close(h)


class TestCloseKills:
    def test_close_marks_session_dead(self, monkeypatch, tmp_path):
        fake = _make_fake_codex_script(tmp_path, [])
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        assert t.is_alive(h) is True
        t.close(h)
        assert t.is_alive(h) is False
        # read_stdout returns empty after close.
        assert t.read_stdout(h, 1024) == b""


class TestErrorPath:
    def test_spawn_failure_surfaces_error(self, monkeypatch):
        # Force a spawn failure by pointing at a non-existent binary.
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", "/no/such/binary/here")
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)  # drain banner

        t.write_stdin(h, b"hi\n")
        # The spawn failure path doesn't run a reader thread; it
        # synchronously enqueues the error, so a tight drain catches it.
        out = _drain(t, h, deadline_s=1.0, contains="codex spawn failed")
        assert b"codex spawn failed" in out
        t.close(h)


# ── integration (gated on env) ──────────────────────────────


@pytest.mark.skipif(
    os.environ.get("CLI_PULSE_TEST_CODEX_REAL") != "1",
    reason="real-codex integration gated behind CLI_PULSE_TEST_CODEX_REAL=1",
)
class TestRealCodex:
    def test_real_codex_round_trip(self):
        """Smoke: spawn the actual `codex exec --json` and verify a
        round-trip reply. Skipped by default — depends on auth + may
        consume rate budget."""
        t = CodexExecTransport()
        h = t.start("smoke", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"Reply with the single word PONG\n")
        out = _drain(t, h, deadline_s=60.0, contains="PONG")
        assert b"PONG" in out
        t.close(h)
