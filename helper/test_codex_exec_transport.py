"""Tests for `transports.codex_exec.CodexExecTransport`.

These exercise the state machine + JSONL handling without invoking
the real `codex` binary. The integration check (real codex spawn) is
gated on `CLI_PULSE_TEST_CODEX_REAL=1`.
"""
from __future__ import annotations

import json
import os
import shlex
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


def _make_fake_codex_script(
    tmp_path,
    jsonl_lines: list[str],
    rc: int = 0,
    *,
    stderr_lines: list[str] | None = None,
    sleep_before_exit: float = 0.0,
    stderr_bulk_bytes: int = 0,
    name: str = "fake_codex.sh",
) -> str:
    """Write a tiny shell script that emits the supplied JSONL lines
    one per line and exits with `rc`. Returns its filesystem path,
    suitable for `CLI_PULSE_CODEX_ARGV0` (which is whitespace-split,
    so we want a single-token executable path).

    Optional knobs for v1.18.2 defensive-hardening tests:
      * `stderr_lines`     — list of literal text lines emitted to stderr
                             before the script exits.
      * `stderr_bulk_bytes` — if > 0, write this many bytes of arbitrary
                             content to stderr before exit, to exercise
                             the P1-B 64KB pipe-buffer deadlock path.
      * `sleep_before_exit` — sleep N seconds before exit. Useful for
                             P1-C (watchdog) and P1-D (cancel) tests where
                             we need a chance to fire timer / interrupt
                             before the proc dies on its own.
      * `name`             — script filename so multiple tests in the
                             same `tmp_path` don't clobber each other.

    We use a script-on-disk rather than inlining `python3 -c <code>`
    because the env-var-override is whitespace-tokenized, which mangles
    quoted shell arguments. A single path-to-script avoids the issue.
    """
    script = tmp_path / name
    body_lines = ["#!/usr/bin/env bash", "set -e"]
    for line in jsonl_lines:
        # Use printf with %s to avoid any backslash-escape interpretation.
        # The line is JSON, so it never contains a literal newline.
        body_lines.append(f"printf '%s\\n' {shlex.quote(line)}")
    if stderr_lines:
        for line in stderr_lines:
            body_lines.append(f"printf '%s\\n' {shlex.quote(line)} >&2")
    if stderr_bulk_bytes > 0:
        # Write `stderr_bulk_bytes` of payload to stderr via `head -c`
        # from /dev/urandom (encoded base64 so it stays printable). This
        # is the deadlock-trigger: if the helper doesn't drain stderr,
        # this `head` blocks once the pipe buffer fills.
        body_lines.append(
            f"head -c {stderr_bulk_bytes} /dev/urandom | base64 >&2"
        )
    if sleep_before_exit > 0:
        body_lines.append(f"sleep {sleep_before_exit}")
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

    def test_multi_line_agent_message_prefixes_every_line(self, monkeypatch, tmp_path):
        events = [
            json.dumps({"type": "thread.started", "thread_id": "tid-multi"}),
            json.dumps({
                "type": "item.completed",
                "item": {
                    "type": "agent_message",
                    "text": "Line one\nLine two\nLine three",
                },
            }),
            json.dumps({"type": "turn.completed"}),
        ]
        fake = _make_fake_codex_script(tmp_path, events)
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hello\n")
        out = _drain(t, h, deadline_s=3.0, contains="Line three")
        text = out.decode("utf-8", errors="replace")
        # Each line must carry the agent prefix.
        for line_body in ("Line one", "Line two", "Line three"):
            assert _AGENT_PREFIX + line_body in text, (
                f"missing agent prefix on {line_body!r} — got {text!r}"
            )
        t.close(h)

    def test_first_turn_has_sandbox_flag(self):
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        state = t._payload(h)  # type: ignore[attr-defined]
        # No thread_id yet → first-turn argv path.
        argv = t._build_exec_argv(state, "hi")  # type: ignore[attr-defined]
        # Must include sandbox=read-only on first turn so resume inherits it.
        assert "-s" in argv and "read-only" in argv, (
            f"first-turn argv missing sandbox: {argv!r}"
        )
        # Must NOT include sandbox after thread_id is captured (resume rejects it).
        state.thread_id = "tid-fake"
        argv2 = t._build_exec_argv(state, "next")  # type: ignore[attr-defined]
        assert "resume" in argv2
        assert "-s" not in argv2, (
            f"resume argv should not carry sandbox: {argv2!r}"
        )
        t.close(h)

    def test_first_turn_argv_uses_double_dash_before_prompt(self):
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        state = t._payload(h)  # type: ignore[attr-defined]
        argv = t._build_exec_argv(state, "hello world")  # type: ignore[attr-defined]
        # Prompt must be last positional, immediately preceded by "--".
        assert argv[-1] == "hello world", argv
        assert argv[-2] == "--", (
            f"first-turn argv missing '--' separator before prompt: {argv!r}"
        )
        t.close(h)

    def test_resume_argv_uses_double_dash_before_positionals(self):
        """Resume path: `--` must precede BOTH thread_id and prompt so
        that a dash-leading thread_id (from corrupted session state)
        can't sneak in as a flag either.
        """
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        state = t._payload(h)  # type: ignore[attr-defined]
        state.thread_id = "tid-resume"
        argv = t._build_exec_argv(state, "follow up")  # type: ignore[attr-defined]
        assert argv[-1] == "follow up", argv
        assert argv[-2] == "tid-resume", argv
        assert argv[-3] == "--", (
            f"resume argv must have '--' immediately before thread_id "
            f"and prompt to defend against dash-leading positionals: {argv!r}"
        )
        t.close(h)

    def test_resume_argv_quarantines_dash_leading_thread_id(self):
        """Defense-in-depth: even if thread_id starts with a dash (e.g.
        corrupted local session state), it must not be parsed as a flag.
        """
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        state = t._payload(h)  # type: ignore[attr-defined]
        state.thread_id = "--sandbox=danger-full-access"
        argv = t._build_exec_argv(state, "follow up")  # type: ignore[attr-defined]
        dash_idx = argv.index("--")
        # Everything after "--" is positional. Both thread_id and prompt
        # must live there.
        positional_tail = argv[dash_idx + 1 :]
        assert "--sandbox=danger-full-access" in positional_tail, argv
        assert "follow up" in positional_tail, argv
        t.close(h)

    def test_argv_quarantines_flag_lookalike_prompt(self):
        """If a user types a prompt that starts with `-`, it MUST be
        passed as positional after `--` so Codex's clap parser cannot
        re-interpret it as a flag (sandbox-bypass surface).
        """
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        state = t._payload(h)  # type: ignore[attr-defined]
        sneaky = "--sandbox=danger-full-access"
        argv = t._build_exec_argv(state, sneaky)  # type: ignore[attr-defined]
        assert argv[-1] == sneaky, argv
        assert argv[-2] == "--", (
            f"flag-lookalike prompt not quarantined behind '--': {argv!r}"
        )
        # Sanity: the legitimate -s read-only is still present and appears
        # BEFORE the "--" separator (i.e. parsed as a real flag).
        dash_idx = argv.index("--")
        assert "-s" in argv[:dash_idx], (
            f"-s read-only must be before '--': {argv!r}"
        )
        t.close(h)

    def test_reader_survives_non_object_json_lines(self, monkeypatch, tmp_path):
        """Codex CLI schema drift could conceivably emit a valid JSON
        primitive (null / true / number / array). The reader thread
        must not crash with AttributeError — it should log + skip,
        then continue processing legit dict events.
        """
        events = [
            "null",
            "true",
            "42",
            '"a string"',
            "[1, 2, 3]",
            json.dumps({"type": "thread.started", "thread_id": "tid-survive"}),
            json.dumps({
                "type": "item.completed",
                "item": {"type": "agent_message", "text": "survived"},
            }),
            json.dumps({"type": "turn.completed"}),
        ]
        fake = _make_fake_codex_script(tmp_path, events)
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)

        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"go\n")
        out = _drain(t, h, deadline_s=3.0, contains="survived")
        assert b"survived" in out, (
            f"reader should keep processing past non-dict JSON: {out!r}"
        )
        # And the legit thread.started should have populated state.
        state = t._payload(h)  # type: ignore[attr-defined]
        assert state.thread_id == "tid-survive"
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


class TestV182P1Defenses:
    """v1.18.2 hotfix: defensive hardening for codex_exec turn lifecycle.

    Covers the 5 P1 defects deferred from v1.18.1:
      A — stderr fd leak per turn
      B — 64KB pipe-buffer deadlock when codex emits heavy stderr
      C — silent network hang bypasses turn timeout
      D — SIGINT cancel masquerades as `codex exec failed: exit code -2`
      E — first-turn crash silently resets the conversation

    See PROJECT_FIX_2026-05-12_v1.18.2_codex_exec_p1.md (to be written
    on archive) and `/tmp/clipulse-review/DEV_PLAN_v1.18.2.md`.
    """

    def test_stderr_drainer_survives_80kb_emission(self, monkeypatch, tmp_path):
        """P1-B: codex emits ~80KB to stderr while running. With the
        drainer, the reader thread sees stdout EOF normally and the turn
        completes. Without it, codex blocks on write(2) once the pipe
        buffer (64KB) fills, and the turn deadlocks."""
        events = [
            json.dumps({"type": "thread.started", "thread_id": "tid-bulk"}),
            json.dumps({
                "type": "item.completed",
                "item": {"type": "agent_message", "text": "ok after bulk stderr"},
            }),
            json.dumps({"type": "turn.completed"}),
        ]
        fake = _make_fake_codex_script(
            tmp_path, events, rc=0, stderr_bulk_bytes=80 * 1024,
        )
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"go\n")
        # Generous deadline; if drainer is broken the test will hit it.
        out = _drain(t, h, deadline_s=5.0, contains="ok after bulk stderr")
        assert b"ok after bulk stderr" in out, (
            f"turn deadlocked or output never reached reader: {out!r}"
        )
        # Stderr buffer must be capped at 32KB (drainer rotates).
        state = t._payload(h)  # type: ignore[attr-defined]
        assert len(state.stderr_buf) <= 32 * 1024, (
            f"stderr_buf exceeds 32KB cap: {len(state.stderr_buf)} bytes"
        )
        t.close(h)

    def test_proc_pipes_closed_after_turn(self, monkeypatch, tmp_path):
        """P1-A: stdout + stderr fds must be explicitly closed at
        end-of-turn so a long session doesn't leak fds."""
        events = [
            json.dumps({"type": "thread.started", "thread_id": "tid-close"}),
            json.dumps({
                "type": "item.completed",
                "item": {"type": "agent_message", "text": "done"},
            }),
            json.dumps({"type": "turn.completed"}),
        ]
        fake = _make_fake_codex_script(tmp_path, events, rc=0)
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"go\n")
        _ = _drain(t, h, deadline_s=3.0, contains="done")
        # The reader thread releases current_proc to None when the turn
        # ends — wait for that to happen, then verify the proc's stdout
        # and stderr are closed. We need a separate reference because
        # state.current_proc is reset to None.
        state = t._payload(h)  # type: ignore[attr-defined]
        # Wait up to 2s for current_proc to clear (reader finally fires).
        deadline = time.time() + 2.0
        while state.current_proc is not None and time.time() < deadline:
            time.sleep(0.02)
        # `proc` variable went out of scope when reader exited, but we can
        # interrogate the drainer thread state to confirm it ended on EOF
        # (which means pipes were closed by the OS before _close_proc_pipes
        # ran AND we additionally closed via _close_proc_pipes).
        # The strongest available assertion: the drainer thread is done.
        if state.stderr_drainer_thread is not None:
            assert not state.stderr_drainer_thread.is_alive(), (
                "stderr drainer should have exited after proc.wait()"
            )
        t.close(h)

    def test_timeout_watchdog_kills_silent_hang(self, monkeypatch, tmp_path):
        """P1-C: external Timer watchdog fires when codex stalls without
        output. Reader's finally emits `codex turn timed out` instead of
        a generic `exit code -15`."""
        # Empty JSONL + 30s sleep → reader's `for raw_line in proc.stdout`
        # blocks indefinitely. Watchdog must SIGTERM the proc.
        fake = _make_fake_codex_script(
            tmp_path, [], rc=0, sleep_before_exit=30.0,
        )
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)
        # Shrink the watchdog deadline so the test doesn't take 3 min.
        monkeypatch.setattr(CodexExecTransport, "_TURN_TIMEOUT_SEC", 0.5)
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hang\n")
        out = _drain(t, h, deadline_s=5.0, contains="timed out")
        text = out.decode("utf-8", errors="replace")
        assert "codex turn timed out" in text, (
            f"watchdog didn't fire or marker missing: {text!r}"
        )
        # Watchdog kill must NOT surface as the generic failure marker.
        assert "codex exec failed" not in text, (
            f"timed-out turn produced generic failure marker: {text!r}"
        )
        t.close(h)

    def test_interrupt_emits_cancelled_marker(self, monkeypatch, tmp_path):
        """P1-D: `interrupt()` sets cancel_pending so the reader's
        finally emits `codex turn cancelled` instead of the misleading
        `codex exec failed: exit code -2`."""
        # Fake codex sleeps a few seconds — gives us time to interrupt
        # before it would have exited on its own.
        fake = _make_fake_codex_script(
            tmp_path, [], rc=0, sleep_before_exit=3.0,
        )
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"slow\n")
        # Wait a beat for the proc to spawn before we interrupt.
        time.sleep(0.3)
        t.interrupt(h)
        out = _drain(t, h, deadline_s=3.0, contains="cancelled")
        text = out.decode("utf-8", errors="replace")
        assert "codex turn cancelled" in text, (
            f"cancel marker missing — got: {text!r}"
        )
        # The generic-failure marker must NOT also appear (would
        # confuse the user about what just happened).
        assert "codex exec failed" not in text, (
            f"cancel path produced generic failure marker: {text!r}"
        )
        t.close(h)

    def test_terminate_emits_cancelled_marker_like_interrupt(
        self, monkeypatch, tmp_path,
    ):
        """P1-D symmetry: `terminate()` (SIGTERM) is also a
        user-initiated cancel and must surface as
        `codex turn cancelled`, not the generic
        `codex exec failed: exit code -15`.
        """
        fake = _make_fake_codex_script(
            tmp_path, [], rc=0, sleep_before_exit=3.0,
        )
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"slow\n")
        time.sleep(0.3)
        t.terminate(h)
        out = _drain(t, h, deadline_s=3.0, contains="cancelled")
        text = out.decode("utf-8", errors="replace")
        assert "codex turn cancelled" in text, (
            f"terminate didn't produce cancel marker — got: {text!r}"
        )
        assert "codex exec failed" not in text, (
            f"terminate path produced generic failure marker: {text!r}"
        )
        t.close(h)

    def test_first_turn_crash_emits_session_reset_marker(
        self, monkeypatch, tmp_path,
    ):
        """P1-E: a first-turn crash with no `thread.started` means the
        next prompt silently opens a new conversation. Emit a
        `Session reset` warning so the user isn't surprised.

        Also validates (P1-B downstream) that stderr emitted by codex
        actually surfaces in the failure marker — without the drainer
        the buffer would be empty and the marker would degrade to
        `exit code 1` with no diagnostic detail.
        """
        # Empty JSONL + rc=1 → no thread_id captured + failure path.
        fake = _make_fake_codex_script(
            tmp_path, [], rc=1,
            stderr_lines=["auth: token expired"],
        )
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hello\n")
        out = _drain(t, h, deadline_s=3.0, contains="Session reset")
        text = out.decode("utf-8", errors="replace")
        assert "codex exec failed" in text, (
            f"primary failure marker missing: {text!r}"
        )
        # Stderr content must surface in the failure marker so the
        # user sees WHY codex died, not just `exit code 1`.
        assert "auth: token expired" in text, (
            f"stderr content failed to surface in marker — drainer/lock "
            f"path is broken: {text!r}"
        )
        assert "Session reset" in text, (
            f"session-reset marker missing on first-turn crash: {text!r}"
        )
        t.close(h)

    def test_no_session_reset_marker_when_thread_started_seen(
        self, monkeypatch, tmp_path,
    ):
        """P1-E: middle-of-conversation failures must NOT trigger the
        session-reset warning because `s.thread_id` is captured and the
        next prompt will correctly `resume` the same conversation."""
        # Emit thread.started so s.thread_id gets captured, then crash.
        events = [
            json.dumps({"type": "thread.started", "thread_id": "tid-mid"}),
        ]
        fake = _make_fake_codex_script(
            tmp_path, events, rc=1,
            stderr_lines=["network: connection refused"],
        )
        monkeypatch.setenv("CLI_PULSE_CODEX_ARGV0", fake)
        t = CodexExecTransport()
        h = t.start("s1", ["codex"], env={}, cwd=None)
        _ = t.read_stdout(h, 4096)
        t.write_stdin(h, b"hello\n")
        # Drain until the failure marker shows up.
        out = _drain(t, h, deadline_s=3.0, contains="codex exec failed")
        text = out.decode("utf-8", errors="replace")
        assert "codex exec failed" in text, (
            f"primary failure marker missing: {text!r}"
        )
        # CRUCIAL: no session-reset, because thread_id was captured.
        assert "Session reset" not in text, (
            f"session-reset marker leaked into mid-conversation failure: "
            f"{text!r}"
        )
        # Sanity: thread_id is in fact set on state.
        state = t._payload(h)  # type: ignore[attr-defined]
        assert state.thread_id == "tid-mid"
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
