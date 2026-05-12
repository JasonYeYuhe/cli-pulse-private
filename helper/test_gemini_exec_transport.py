"""Tests for `transports.gemini_exec.GeminiExecTransport`.

Exercises state machine + stream-json handling without invoking the
real `gemini` binary. Pattern mirrors `test_codex_exec_transport.py`:
override `CLI_PULSE_GEMINI_ARGV0` with a fake shell script that emits
controlled stream-json events.

Integration check against real gemini binary is opt-in via the
`CLI_PULSE_TEST_GEMINI_REAL=1` env var (currently no such test; first
real e2e runs are manual per `feedback_codex_exec_json_arch.md` model).
"""
from __future__ import annotations

import json
import shlex
import time

import pytest

from transports.gemini_exec import (
    GeminiExecTransport,
    _AGENT_PREFIX,
    _ERROR_PREFIX,
    _INFO_PREFIX,
    _USER_PREFIX,
    _WARN_PREFIX,
)


# ── helpers ─────────────────────────────────────────────────


def _drain(transport, handle, *, deadline_s: float, contains: str | None = None) -> bytes:
    """Read until `contains` appears in the buffer, or deadline elapses."""
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


def _make_fake_gemini_script(
    tmp_path,
    jsonl_lines: list[str],
    rc: int = 0,
    *,
    stderr_lines: list[str] | None = None,
    sleep_before_exit: float = 0.0,
    capture_argv_to: str | None = None,
    name: str = "fake_gemini.sh",
) -> str:
    """Build a shell script that emits the supplied stream-json lines
    to stdout one per line, then exits with `rc`. Optional knobs match
    the codex_exec test harness."""
    script = tmp_path / name
    body_lines = ["#!/usr/bin/env bash", "set -e"]
    if capture_argv_to:
        # Write the full argv (excluding $0) one-per-line so tests can
        # assert which flags the transport passed.
        body_lines.append(f"printf '%s\\n' \"$@\" > {shlex.quote(capture_argv_to)}")
    for line in jsonl_lines:
        body_lines.append(f"printf '%s\\n' {shlex.quote(line)}")
    if stderr_lines:
        for line in stderr_lines:
            body_lines.append(f"printf '%s\\n' {shlex.quote(line)} >&2")
    if sleep_before_exit > 0:
        body_lines.append(f"sleep {sleep_before_exit}")
    body_lines.append(f"exit {rc}")
    script.write_text("\n".join(body_lines) + "\n")
    script.chmod(0o755)
    return str(script)


# ── tests ───────────────────────────────────────────────────


class TestStartEmitBanner:
    def test_start_emits_banner_line(self):
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        data = t.read_stdout(h, 4096)
        assert b"Gemini exec-mode session started" in data
        t.close(h)

    def test_start_rejects_empty_argv(self):
        t = GeminiExecTransport()
        with pytest.raises(Exception):
            t.start("s1", [], env={}, cwd=None)


class TestPromptBufferingAndFlush:
    def test_input_without_newline_is_buffered(self):
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hel")
        assert t.read_stdout(h, 4096) == b""
        t.close(h)

    def test_newline_echoes_user_prompt_and_working_marker(self, monkeypatch, tmp_path):
        fake = _make_fake_gemini_script(tmp_path, [])
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hello\n")
        out = _drain(t, h, deadline_s=2.0, contains="Working")
        text = out.decode("utf-8", errors="replace")
        assert _USER_PREFIX + "hello" in text
        assert "Working" in text
        t.close(h)


class TestStreamJsonEventHandling:
    def test_assistant_message_surfaces_with_bullet_prefix(self, monkeypatch, tmp_path):
        events = [
            json.dumps({"type": "init", "session_id": "uuid-abc",
                        "model": "gemini-2.5-flash"}),
            json.dumps({"type": "message", "role": "user", "content": "hello"}),
            json.dumps({"type": "message", "role": "assistant",
                        "content": "Hi there!", "delta": True}),
            json.dumps({"type": "result", "status": "success",
                        "stats": {"input_tokens": 50, "output_tokens": 10}}),
        ]
        fake = _make_fake_gemini_script(tmp_path, events)
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hello\n")
        out = _drain(t, h, deadline_s=3.0, contains="Hi there!")
        text = out.decode("utf-8", errors="replace")
        assert _USER_PREFIX + "hello" in text
        assert _AGENT_PREFIX + "Hi there!" in text
        # Session id captured.
        state = t._payload(h)  # type: ignore[attr-defined]
        assert state.gemini_session_id == "uuid-abc"
        # has_prior_turn set so the next turn uses --resume.
        assert state.has_prior_turn is True
        t.close(h)

    def test_user_role_message_is_dropped_no_duplicate_echo(self, monkeypatch, tmp_path):
        """The gemini 'user' echo must be suppressed — we already echoed
        the prompt ourselves in _maybe_flush_next_turn. Otherwise the
        user sees their prompt twice in the transcript."""
        events = [
            json.dumps({"type": "init", "session_id": "uuid", "model": "x"}),
            json.dumps({"type": "message", "role": "user", "content": "hello"}),
            json.dumps({"type": "message", "role": "assistant",
                        "content": "reply", "delta": True}),
            json.dumps({"type": "result", "status": "success", "stats": {}}),
        ]
        fake = _make_fake_gemini_script(tmp_path, events)
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hello\n")
        out = _drain(t, h, deadline_s=3.0, contains="reply")
        text = out.decode("utf-8", errors="replace")
        # User echo appears exactly once (the › "hello" we wrote
        # ourselves), not twice.
        assert text.count(_USER_PREFIX + "hello") == 1
        t.close(h)

    def test_multi_delta_assistant_message_concatenates(self, monkeypatch, tmp_path):
        """Multiple delta=true assistant messages must be concatenated
        and emitted as one bullet block at end-of-turn."""
        events = [
            json.dumps({"type": "init", "session_id": "uuid", "model": "x"}),
            json.dumps({"type": "message", "role": "assistant",
                        "content": "Hello ", "delta": True}),
            json.dumps({"type": "message", "role": "assistant",
                        "content": "world", "delta": True}),
            json.dumps({"type": "message", "role": "assistant",
                        "content": "!", "delta": True}),
            json.dumps({"type": "result", "status": "success", "stats": {}}),
        ]
        fake = _make_fake_gemini_script(tmp_path, events)
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hi\n")
        out = _drain(t, h, deadline_s=3.0, contains="Hello world!")
        text = out.decode("utf-8", errors="replace")
        assert _AGENT_PREFIX + "Hello world!" in text
        t.close(h)

    def test_multiline_assistant_content_prefixes_every_line(self, monkeypatch, tmp_path):
        events = [
            json.dumps({"type": "init", "session_id": "uuid", "model": "x"}),
            json.dumps({"type": "message", "role": "assistant",
                        "content": "Line one\nLine two\nLine three",
                        "delta": True}),
            json.dumps({"type": "result", "status": "success", "stats": {}}),
        ]
        fake = _make_fake_gemini_script(tmp_path, events)
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hi\n")
        out = _drain(t, h, deadline_s=3.0, contains="Line three")
        text = out.decode("utf-8", errors="replace")
        assert _AGENT_PREFIX + "Line one" in text
        assert _AGENT_PREFIX + "Line two" in text
        assert _AGENT_PREFIX + "Line three" in text
        t.close(h)

    def test_tool_call_and_result_events_are_dropped(self, monkeypatch, tmp_path):
        """v1.19 design choice: gemini runs many internal tool calls
        per prompt; surfacing each one spams the transcript. The
        assistant reply summarizes what was done."""
        events = [
            json.dumps({"type": "init", "session_id": "uuid", "model": "x"}),
            json.dumps({"type": "tool_call", "name": "read_file"}),
            json.dumps({"type": "tool_result", "name": "read_file"}),
            json.dumps({"type": "tool_call", "name": "list_directory"}),
            json.dumps({"type": "tool_result", "name": "list_directory"}),
            json.dumps({"type": "message", "role": "assistant",
                        "content": "Done", "delta": True}),
            json.dumps({"type": "result", "status": "success", "stats": {}}),
        ]
        fake = _make_fake_gemini_script(tmp_path, events)
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hi\n")
        out = _drain(t, h, deadline_s=3.0, contains="Done")
        text = out.decode("utf-8", errors="replace")
        # Agent reply still appears.
        assert _AGENT_PREFIX + "Done" in text
        # No tool spam in transcript.
        assert "calling tool" not in text
        assert "read_file" not in text
        assert "list_directory" not in text
        t.close(h)

    def test_result_error_surfaces_with_error_prefix(self, monkeypatch, tmp_path):
        events = [
            json.dumps({"type": "init", "session_id": "uuid", "model": "x"}),
            json.dumps({"type": "result", "status": "error",
                        "error": {"message": "quota exhausted"},
                        "stats": {}}),
        ]
        # Non-zero rc so the failure path doesn't fall into the
        # "exited without reply" branch.
        fake = _make_fake_gemini_script(tmp_path, events, rc=1)
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hi\n")
        out = _drain(t, h, deadline_s=3.0, contains="quota exhausted")
        text = out.decode("utf-8", errors="replace")
        assert _ERROR_PREFIX + "quota exhausted" in text
        # has_prior_turn must NOT be set on a failed turn (otherwise
        # the next turn would pass --resume against a session that
        # never reached steady state).
        state = t._payload(h)  # type: ignore[attr-defined]
        assert state.has_prior_turn is False
        t.close(h)

    def test_usage_stats_surface_with_info_prefix(self, monkeypatch, tmp_path):
        events = [
            json.dumps({"type": "init", "session_id": "uuid", "model": "x"}),
            json.dumps({"type": "message", "role": "assistant",
                        "content": "OK", "delta": True}),
            json.dumps({"type": "result", "status": "success",
                        "stats": {"input_tokens": 100, "output_tokens": 5,
                                  "cached": 80}}),
        ]
        fake = _make_fake_gemini_script(tmp_path, events)
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hi\n")
        out = _drain(t, h, deadline_s=3.0, contains="usage:")
        text = out.decode("utf-8", errors="replace")
        assert "100 in" in text and "5 out" in text and "80 cached" in text
        t.close(h)

    def test_no_agent_text_clean_exit_emits_no_reply_warning(self, monkeypatch, tmp_path):
        events = [
            json.dumps({"type": "init", "session_id": "uuid", "model": "x"}),
            json.dumps({"type": "result", "status": "success", "stats": {}}),
        ]
        fake = _make_fake_gemini_script(tmp_path, events)
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hi\n")
        out = _drain(t, h, deadline_s=3.0, contains="without reply")
        text = out.decode("utf-8", errors="replace")
        assert _WARN_PREFIX + "gemini exited without reply" in text
        t.close(h)

    def test_non_json_lines_are_dropped(self, monkeypatch, tmp_path):
        """Non-JSON lines (warnings, banners) must be silently dropped
        rather than crashing the reader thread."""
        events = [
            "this is not json",
            json.dumps({"type": "init", "session_id": "uuid", "model": "x"}),
            "[chrome] yet another non-json line",
            json.dumps({"type": "message", "role": "assistant",
                        "content": "OK", "delta": True}),
            json.dumps({"type": "result", "status": "success", "stats": {}}),
        ]
        fake = _make_fake_gemini_script(tmp_path, events)
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hi\n")
        out = _drain(t, h, deadline_s=3.0, contains="OK")
        text = out.decode("utf-8", errors="replace")
        assert _AGENT_PREFIX + "OK" in text
        # Non-json content does NOT leak to user.
        assert "not json" not in text
        assert "chrome" not in text
        t.close(h)


class TestArgvConstruction:
    def test_first_turn_argv_no_resume(self, monkeypatch, tmp_path):
        """First turn must NOT include --resume; that flag would point
        at the wrong session (or nothing) before this transport has
        spawned anything."""
        captured = tmp_path / "argv.txt"
        events = [
            json.dumps({"type": "init", "session_id": "uuid", "model": "x"}),
            json.dumps({"type": "message", "role": "assistant",
                        "content": "OK", "delta": True}),
            json.dumps({"type": "result", "status": "success", "stats": {}}),
        ]
        fake = _make_fake_gemini_script(
            tmp_path, events, capture_argv_to=str(captured),
        )
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hi\n")
        _ = _drain(t, h, deadline_s=3.0, contains="OK")
        time.sleep(0.1)  # let the proc finish writing argv.txt
        argv_text = captured.read_text()
        assert "--resume" not in argv_text
        assert "-p" in argv_text
        assert "-o" in argv_text
        assert "stream-json" in argv_text
        assert "--skip-trust" in argv_text
        assert "--approval-mode" in argv_text
        # `-p <prompt>` must appear in order — gemini consumes the next
        # arg as the prompt value. A `--` sentinel between them would
        # make gemini complain "Not enough arguments following: p".
        lines = argv_text.splitlines()
        idx = lines.index("-p")
        assert lines[idx + 1] == "hi"
        t.close(h)

    def test_second_turn_argv_includes_resume_latest(self, monkeypatch, tmp_path):
        """After a successful first turn, subsequent turns must pass
        `--resume latest` so gemini continues the same conversation."""
        captured = tmp_path / "argv.txt"
        events = [
            json.dumps({"type": "init", "session_id": "uuid", "model": "x"}),
            json.dumps({"type": "message", "role": "assistant",
                        "content": "OK", "delta": True}),
            json.dumps({"type": "result", "status": "success", "stats": {}}),
        ]
        fake = _make_fake_gemini_script(
            tmp_path, events, capture_argv_to=str(captured),
        )
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        # First turn → has_prior_turn becomes True.
        t.write_stdin(h, b"first\n")
        _ = _drain(t, h, deadline_s=3.0, contains="OK")
        time.sleep(0.1)
        # Second turn — same fake; we'll re-read argv.txt to see the
        # second invocation's args (overwrites the first).
        t.write_stdin(h, b"second\n")
        _ = _drain(t, h, deadline_s=3.0, contains="OK")
        time.sleep(0.1)
        argv_text = captured.read_text()
        assert "--resume" in argv_text
        assert "latest" in argv_text
        t.close(h)

    def test_yolo_env_var_swaps_approval_mode(self, monkeypatch, tmp_path):
        captured = tmp_path / "argv.txt"
        events = [
            json.dumps({"type": "init", "session_id": "uuid", "model": "x"}),
            json.dumps({"type": "message", "role": "assistant",
                        "content": "OK", "delta": True}),
            json.dumps({"type": "result", "status": "success", "stats": {}}),
        ]
        fake = _make_fake_gemini_script(
            tmp_path, events, capture_argv_to=str(captured),
        )
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"],
                    env={"CLI_PULSE_GEMINI_YOLO": "1"}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hi\n")
        _ = _drain(t, h, deadline_s=3.0, contains="OK")
        time.sleep(0.1)
        argv_text = captured.read_text()
        # --approval-mode is followed by `yolo`.
        lines = argv_text.splitlines()
        idx = lines.index("--approval-mode")
        assert lines[idx + 1] == "yolo"
        t.close(h)

    def test_model_env_var_pins_model_flag(self, monkeypatch, tmp_path):
        captured = tmp_path / "argv.txt"
        events = [
            json.dumps({"type": "init", "session_id": "uuid", "model": "x"}),
            json.dumps({"type": "message", "role": "assistant",
                        "content": "OK", "delta": True}),
            json.dumps({"type": "result", "status": "success", "stats": {}}),
        ]
        fake = _make_fake_gemini_script(
            tmp_path, events, capture_argv_to=str(captured),
        )
        monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", fake)
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"],
                    env={"CLI_PULSE_GEMINI_MODEL": "gemini-2.5-flash"},
                    cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hi\n")
        _ = _drain(t, h, deadline_s=3.0, contains="OK")
        time.sleep(0.1)
        argv_text = captured.read_text()
        lines = argv_text.splitlines()
        idx = lines.index("-m")
        assert lines[idx + 1] == "gemini-2.5-flash"
        t.close(h)


class TestCancelAndClose:
    def test_close_marks_session_closed_and_subsequent_writes_noop(self):
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        t.close(h)
        state = t._payload(h)  # type: ignore[attr-defined]
        assert state.closed is True
        assert t.write_stdin(h, b"hello\n") == 0
        assert t.read_stdout(h, 4096) == b""

    def test_interrupt_clears_pending_prompts(self):
        """interrupt() must clear queued prompts so SIGINT actually
        halts the whole pipeline rather than just the running turn."""
        t = GeminiExecTransport()
        h = t.start("s1", ["gemini"], env={}, cwd=None)
        state = t._payload(h)  # type: ignore[attr-defined]
        # Manually inject pending prompts (no subprocess yet).
        with state.lock:
            state.pending_prompts.append("queued-1")
            state.pending_prompts.append("queued-2")
        t.interrupt(h)
        assert len(state.pending_prompts) == 0
        t.close(h)
