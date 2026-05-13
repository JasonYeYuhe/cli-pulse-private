"""Tests for `transports.multiplex.MultiplexTransport`.

The multiplex transport is a thin strategy-pattern dispatcher: pick
the right inner transport at `start()` based on argv[0] basename, and
forward all other calls based on the handle's payload type.

These tests pin the routing rules + pass-through semantics so future
regressions (e.g. forgetting to forward a new method, swallowing a
flag at the multiplex layer) get caught before ship.
"""
from __future__ import annotations

from typing import Optional

import pytest

from transports.base import SessionHandle, SessionTransport, TransportError
from transports.multiplex import MultiplexTransport


# ── fakes ────────────────────────────────────────────────────────


class _FakePayload:
    """Marker payload that one of our fake transports owns."""

    def __init__(self, kind: str) -> None:
        self.kind = kind


class _FakeTransport(SessionTransport):
    """Minimal SessionTransport for routing tests.

    Records every call it receives so the test can assert which inner
    transport the multiplex actually dispatched to. Owns handles whose
    payload `kind` matches `self.kind`.
    """

    def __init__(self, kind: str) -> None:
        self.kind = kind
        self.calls: list[tuple[str, tuple]] = []

    def _payload(self, handle: SessionHandle) -> _FakePayload:
        if not isinstance(handle.payload, _FakePayload):
            raise TransportError("not a fake payload")
        if handle.payload.kind != self.kind:
            raise TransportError(f"wrong kind: expected {self.kind}")
        return handle.payload

    def start(
        self,
        session_id: str,
        argv: list[str],
        env: Optional[dict[str, str]] = None,
        cwd: Optional[str] = None,
    ) -> SessionHandle:
        # Record env + cwd too so tests can assert that the multiplex
        # forwards them verbatim without dropping or mutating them.
        # `argv is None` is recorded as None (not coerced) so the test
        # for None-tolerant routing can verify the multiplex actually
        # forwarded the value the caller passed.
        argv_recorded = tuple(argv) if argv is not None else None
        self.calls.append((
            "start",
            (session_id, argv_recorded, env, cwd),
        ))
        return SessionHandle(
            session_id=session_id,
            payload=_FakePayload(self.kind),
        )

    def write_stdin(self, handle: SessionHandle, data: bytes) -> int:
        self._payload(handle)
        self.calls.append(("write_stdin", (data,)))
        return len(data)

    def read_stdout(self, handle: SessionHandle, max_bytes: int = 4096) -> bytes:
        self._payload(handle)
        self.calls.append(("read_stdout", (max_bytes,)))
        return b""

    def interrupt(self, handle: SessionHandle) -> None:
        self._payload(handle)
        self.calls.append(("interrupt", ()))

    def terminate(self, handle: SessionHandle) -> None:
        self._payload(handle)
        self.calls.append(("terminate", ()))

    def is_alive(self, handle: SessionHandle) -> bool:
        self._payload(handle)
        self.calls.append(("is_alive", ()))
        return True

    def wait(self, handle: SessionHandle, timeout: Optional[float] = None) -> Optional[int]:
        self._payload(handle)
        self.calls.append(("wait", (timeout,)))
        return None

    def close(self, handle: SessionHandle) -> None:
        self._payload(handle)
        self.calls.append(("close", ()))


@pytest.fixture
def mux():
    pty = _FakeTransport("pty")
    codex = _FakeTransport("codex")
    return MultiplexTransport(pty, codex), pty, codex


@pytest.fixture
def mux_with_gemini():
    """v1.19+: mux fixture with the optional gemini_exec transport
    wired. Existing tests use the 2-arg fixture above to verify the
    backward-compat constructor signature (gemini=None) still routes
    gemini→PTY as a fallback."""
    pty = _FakeTransport("pty")
    codex = _FakeTransport("codex")
    gemini = _FakeTransport("gemini")
    return MultiplexTransport(pty, codex, gemini), pty, codex, gemini


# ── start() routing by argv ────────────────────────────────────


class TestStartRoutingByArgv:
    def test_argv0_codex_routes_to_codex(self, mux):
        m, pty, codex = mux
        # Pass concrete env + cwd to verify the multiplex forwards them
        # to the inner transport unchanged (regression guard against a
        # future refactor that hardcodes one of these to None).
        env = {"FOO": "bar"}
        cwd = "/tmp/work"
        h = m.start("s1", ["codex"], env=env, cwd=cwd)
        assert codex.calls == [("start", ("s1", ("codex",), env, cwd))]
        assert pty.calls == []
        assert h.payload.kind == "codex"

    def test_argv0_codex_with_absolute_path_routes_to_codex(self, mux):
        m, pty, codex = mux
        h = m.start("s2", ["/usr/local/bin/codex", "exec"], env=None, cwd=None)
        # basename("/usr/local/bin/codex") == "codex" → codex transport.
        assert codex.calls and codex.calls[0][0] == "start"
        assert pty.calls == []
        assert h.payload.kind == "codex"

    def test_argv0_homebrew_codex_routes_to_codex(self, mux):
        m, _pty, codex = mux
        h = m.start("s3", ["/opt/homebrew/bin/codex"], env=None, cwd=None)
        assert codex.calls and codex.calls[0][0] == "start"
        assert h.payload.kind == "codex"

    def test_argv0_claude_routes_to_pty(self, mux):
        m, pty, codex = mux
        h = m.start("s4", ["claude"], env=None, cwd=None)
        assert pty.calls and pty.calls[0][0] == "start"
        assert codex.calls == []
        assert h.payload.kind == "pty"

    def test_argv0_gemini_routes_to_pty(self, mux):
        m, pty, codex = mux
        h = m.start("s5", ["gemini"], env=None, cwd=None)
        assert pty.calls and pty.calls[0][0] == "start"
        assert codex.calls == []
        assert h.payload.kind == "pty"

    def test_argv0_arbitrary_binary_routes_to_pty(self, mux):
        m, pty, codex = mux
        h = m.start("s6", ["bash", "-c", "echo hi"], env=None, cwd=None)
        assert pty.calls and pty.calls[0][0] == "start"
        assert codex.calls == []
        assert h.payload.kind == "pty"

    def test_empty_argv_falls_through_to_pty(self, mux):
        """The multiplex's argv router defaults to pty when argv is
        empty. (The pty transport itself raises TransportError on empty
        argv — that's its concern, not the multiplex router's.)"""
        m, pty, codex = mux
        m.start("s7", [], env=None, cwd=None)
        assert pty.calls and pty.calls[0][0] == "start"
        assert codex.calls == []

    def test_none_argv_falls_through_to_pty(self, mux):
        """Defense-in-depth: Python doesn't enforce list[str] at
        runtime, so a caller could pass None. The `if argv:` guard in
        _transport_for_argv must not crash on this."""
        m, pty, codex = mux
        m.start("s7b", None, env=None, cwd=None)  # type: ignore[arg-type]
        assert pty.calls and pty.calls[0][0] == "start"
        assert codex.calls == []

    def test_argv0_codex_substring_does_not_match(self, mux):
        """Defense-in-depth: only exact basename match should route to
        codex. A plugin path like `/.../codex-plugin/bin/foo` must not
        be misclassified just because `codex` appears in the path."""
        m, pty, codex = mux
        h = m.start(
            "s8",
            ["/Users/x/.codex-plugin/bin/foo"],
            env=None, cwd=None,
        )
        assert pty.calls and pty.calls[0][0] == "start"
        assert codex.calls == []
        assert h.payload.kind == "pty"


# ── handle dispatch + per-method forwarding ────────────────────


class TestPerMethodForwardingForCodexHandle:
    def test_write_stdin_routes_to_codex(self, mux):
        m, pty, codex = mux
        h = m.start("s1", ["codex"], env=None, cwd=None)
        m.write_stdin(h, b"hello\n")
        assert ("write_stdin", (b"hello\n",)) in codex.calls
        assert all(name != "write_stdin" for name, _ in pty.calls)

    def test_read_stdout_routes_to_codex(self, mux):
        m, pty, codex = mux
        h = m.start("s1", ["codex"], env=None, cwd=None)
        m.read_stdout(h, 1024)
        assert ("read_stdout", (1024,)) in codex.calls

    def test_interrupt_routes_to_codex(self, mux):
        """Critical for v1.18.2 cancel_pending semantics — multiplex
        must NOT swallow or transform interrupt() so the codex
        transport's cancel_pending flag fires correctly downstream."""
        m, pty, codex = mux
        h = m.start("s1", ["codex"], env=None, cwd=None)
        m.interrupt(h)
        assert ("interrupt", ()) in codex.calls
        assert all(name != "interrupt" for name, _ in pty.calls)

    def test_terminate_routes_to_codex(self, mux):
        """Same concern as interrupt — terminate() also sets
        cancel_pending in v1.18.2 deep-check follow-up. Must forward
        cleanly."""
        m, pty, codex = mux
        h = m.start("s1", ["codex"], env=None, cwd=None)
        m.terminate(h)
        assert ("terminate", ()) in codex.calls
        assert all(name != "terminate" for name, _ in pty.calls)

    def test_is_alive_routes_to_codex(self, mux):
        m, _pty, codex = mux
        h = m.start("s1", ["codex"], env=None, cwd=None)
        m.is_alive(h)
        assert ("is_alive", ()) in codex.calls

    def test_wait_routes_to_codex(self, mux):
        m, _pty, codex = mux
        h = m.start("s1", ["codex"], env=None, cwd=None)
        m.wait(h, timeout=0.5)
        assert ("wait", (0.5,)) in codex.calls

    def test_close_routes_to_codex(self, mux):
        m, _pty, codex = mux
        h = m.start("s1", ["codex"], env=None, cwd=None)
        m.close(h)
        assert ("close", ()) in codex.calls


class TestPerMethodForwardingForPtyHandle:
    """Full symmetric coverage with TestPerMethodForwardingForCodexHandle.
    A copy-paste error or a future refactor that accidentally hardcodes
    one method to route to codex would otherwise slip through if pty
    coverage skipped methods."""

    def test_write_stdin_routes_to_pty(self, mux):
        m, pty, codex = mux
        h = m.start("s1", ["claude"], env=None, cwd=None)
        m.write_stdin(h, b"hello\n")
        assert ("write_stdin", (b"hello\n",)) in pty.calls
        assert all(name != "write_stdin" for name, _ in codex.calls)

    def test_read_stdout_routes_to_pty(self, mux):
        m, pty, codex = mux
        h = m.start("s1", ["claude"], env=None, cwd=None)
        m.read_stdout(h, 1024)
        assert ("read_stdout", (1024,)) in pty.calls
        assert all(name != "read_stdout" for name, _ in codex.calls)

    def test_interrupt_routes_to_pty(self, mux):
        m, pty, codex = mux
        h = m.start("s1", ["claude"], env=None, cwd=None)
        m.interrupt(h)
        assert ("interrupt", ()) in pty.calls
        assert all(name != "interrupt" for name, _ in codex.calls)

    def test_terminate_routes_to_pty(self, mux):
        m, pty, codex = mux
        h = m.start("s1", ["claude"], env=None, cwd=None)
        m.terminate(h)
        assert ("terminate", ()) in pty.calls
        assert all(name != "terminate" for name, _ in codex.calls)

    def test_is_alive_routes_to_pty(self, mux):
        m, pty, codex = mux
        h = m.start("s1", ["claude"], env=None, cwd=None)
        m.is_alive(h)
        assert ("is_alive", ()) in pty.calls
        assert all(name != "is_alive" for name, _ in codex.calls)

    def test_wait_routes_to_pty(self, mux):
        m, pty, codex = mux
        h = m.start("s1", ["claude"], env=None, cwd=None)
        m.wait(h, timeout=0.5)
        assert ("wait", (0.5,)) in pty.calls
        assert all(name != "wait" for name, _ in codex.calls)

    def test_close_routes_to_pty(self, mux):
        m, pty, codex = mux
        h = m.start("s1", ["claude"], env=None, cwd=None)
        m.close(h)
        assert ("close", ()) in pty.calls
        assert all(name != "close" for name, _ in codex.calls)


# ── handle ownership disambiguation ────────────────────────────


class TestHandleOwnershipErrors:
    def test_alien_handle_raises_transport_error(self, mux):
        """A handle from neither transport must raise TransportError
        rather than silently dispatching to one of them. Without this
        guard a foreign handle could end up on the wrong transport
        and produce hard-to-diagnose mis-routes."""
        m, _pty, _codex = mux

        class _AlienPayload:
            pass

        alien = SessionHandle(session_id="alien", payload=_AlienPayload())
        with pytest.raises(TransportError):
            m.write_stdin(alien, b"x")

    def test_handle_with_no_payload_attribute_raises(self, mux):
        """SessionHandle's payload is required; but defensive code in
        _transport_for_handle catches AttributeError too."""
        m, _pty, _codex = mux

        class _Brokenhandle:
            pass

        # Build a handle-shaped object that lacks a usable payload.
        broken = _Brokenhandle()
        with pytest.raises(TransportError):
            m.write_stdin(broken, b"x")  # type: ignore[arg-type]


# ── v1.19: Gemini routing ─────────────────────────────────────


class TestGeminiRouting:
    """Routing tests for the optional gemini_exec_transport (v1.19+).

    Two fixtures exist: `mux` (2-arg, backward-compat — gemini routes
    to PTY as fallback) and `mux_with_gemini` (3-arg, gemini routes
    to dedicated transport).
    """

    def test_argv0_gemini_with_transport_routes_to_gemini(self, mux_with_gemini):
        m, pty, codex, gemini = mux_with_gemini
        env = {"GEMINI_API_KEY": "fake"}
        cwd = "/tmp/work"
        h = m.start("g1", ["gemini"], env=env, cwd=cwd)
        assert gemini.calls == [("start", ("g1", ("gemini",), env, cwd))]
        assert pty.calls == []
        assert codex.calls == []
        assert h.payload.kind == "gemini"

    def test_argv0_gemini_with_absolute_path_routes_to_gemini(self, mux_with_gemini):
        m, _pty, _codex, gemini = mux_with_gemini
        h = m.start("g2", ["/opt/homebrew/bin/gemini"], env=None, cwd=None)
        assert gemini.calls == [("start", ("g2", ("/opt/homebrew/bin/gemini",), None, None))]
        assert h.payload.kind == "gemini"

    def test_argv0_gemini_without_transport_falls_back_to_pty(self, mux):
        """Backward-compat: 2-arg constructor (no gemini_exec) → gemini
        argv routes to PTY. Existing helper deployments that haven't
        upgraded to the 3-arg constructor must keep working."""
        m, pty, codex = mux
        h = m.start("g3", ["gemini"], env=None, cwd=None)
        assert pty.calls == [("start", ("g3", ("gemini",), None, None))]
        assert codex.calls == []
        assert h.payload.kind == "pty"

    def test_argv0_claude_still_routes_to_pty_with_gemini_present(self, mux_with_gemini):
        """Claude must still route to PTY even when the gemini transport
        is wired — only "gemini" basenames trigger the new path."""
        m, pty, codex, gemini = mux_with_gemini
        h = m.start("c1", ["claude"], env=None, cwd=None)
        assert pty.calls == [("start", ("c1", ("claude",), None, None))]
        assert codex.calls == []
        assert gemini.calls == []
        assert h.payload.kind == "pty"

    def test_argv0_codex_still_routes_to_codex_with_gemini_present(self, mux_with_gemini):
        """Codex routing must be preserved when gemini is wired."""
        m, pty, codex, gemini = mux_with_gemini
        h = m.start("c2", ["codex"], env=None, cwd=None)
        assert codex.calls == [("start", ("c2", ("codex",), None, None))]
        assert pty.calls == []
        assert gemini.calls == []
        assert h.payload.kind == "codex"

    def test_handle_dispatch_to_gemini(self, mux_with_gemini):
        """Subsequent operations on a gemini-started handle must go to
        the gemini transport, not PTY or codex (regression guard for
        _transport_for_handle probe order)."""
        m, pty, codex, gemini = mux_with_gemini
        h = m.start("g4", ["gemini"], env=None, cwd=None)
        m.write_stdin(h, b"hello\n")
        m.read_stdout(h, 4096)
        m.interrupt(h)
        m.close(h)
        # Every operation should have hit gemini, none of the others.
        op_kinds = [c[0] for c in gemini.calls]
        assert op_kinds == ["start", "write_stdin", "read_stdout", "interrupt", "close"]
        assert pty.calls == []
        assert codex.calls == []

    def test_handle_dispatch_distinguishes_codex_and_gemini(self, mux_with_gemini):
        """Two concurrent sessions (one codex, one gemini) must route
        independently to their owning transport."""
        m, _pty, codex, gemini = mux_with_gemini
        h_codex = m.start("c-mixed", ["codex"], env=None, cwd=None)
        h_gemini = m.start("g-mixed", ["gemini"], env=None, cwd=None)
        m.write_stdin(h_codex, b"hi codex\n")
        m.write_stdin(h_gemini, b"hi gemini\n")
        codex_ops = [c for c in codex.calls if c[0] == "write_stdin"]
        gemini_ops = [c for c in gemini.calls if c[0] == "write_stdin"]
        assert len(codex_ops) == 1
        assert len(gemini_ops) == 1
