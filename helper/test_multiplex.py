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
        *,
        pass_fds: tuple[int, ...] = (),
        env_remove: frozenset[str] = frozenset(),
    ) -> SessionHandle:
        # Record env + cwd too so tests can assert that the multiplex
        # forwards them verbatim without dropping or mutating them.
        # `argv is None` is recorded as None (not coerced) so the test
        # for None-tolerant routing can verify the multiplex actually
        # forwarded the value the caller passed.
        # v1.35: `env_remove` (the on-plan OPENAI_API_KEY scrub) is
        # forwarded to BOTH transports; stash the last value so a
        # dedicated test can assert the forwarding, but keep the recorded
        # `calls` tuple at its original 4-field shape so the routing
        # assertions below are undisturbed.
        self.last_env_remove = frozenset(env_remove)
        self.last_pass_fds = tuple(pass_fds)
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

    def test_env_remove_forwarded_to_codex(self, mux):
        """v1.35: the on-plan OPENAI_API_KEY scrub must reach codex_exec —
        the transport that actually spawns a managed Codex session."""
        m, pty, codex = mux
        m.start("sr1", ["codex"], env_remove=frozenset({"OPENAI_API_KEY"}))
        assert codex.last_env_remove == frozenset({"OPENAI_API_KEY"})

    def test_env_remove_forwarded_to_pty(self, mux):
        """And it forwards to the PTY transport too (claude/gemini path),
        so the seam is provider-agnostic."""
        m, pty, codex = mux
        m.start("sr2", ["claude"], env_remove=frozenset({"OPENAI_API_KEY"}))
        assert pty.last_env_remove == frozenset({"OPENAI_API_KEY"})

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
    """v-next P0-B: the GeminiExecTransport is DELETED — the gemini
    provider spawns `agy`, which routes to the PTY path like claude.
    These tests pin that a `gemini`/`agy` basename routes to PTY and the
    codex/claude routing invariants are unaffected.
    """

    def test_argv0_gemini_routes_to_pty(self, mux):
        """Retired binary name still routes to PTY (no gemini transport)."""
        m, pty, codex = mux
        env = {"GEMINI_API_KEY": "fake"}
        cwd = "/tmp/work"
        h = m.start("g1", ["gemini"], env=env, cwd=cwd)
        assert pty.calls == [("start", ("g1", ("gemini",), env, cwd))]
        assert codex.calls == []
        assert h.payload.kind == "pty"

    def test_argv0_agy_routes_to_pty(self, mux):
        """The live gemini-provider binary is `agy` → PTY."""
        m, pty, _codex = mux
        h = m.start("g2", ["/opt/homebrew/bin/agy"], env=None, cwd=None)
        assert pty.calls == [("start", ("g2", ("/opt/homebrew/bin/agy",), None, None))]
        assert h.payload.kind == "pty"

    def test_argv0_claude_routes_to_pty(self, mux):
        m, pty, codex = mux
        h = m.start("c1", ["claude"], env=None, cwd=None)
        assert pty.calls == [("start", ("c1", ("claude",), None, None))]
        assert codex.calls == []
        assert h.payload.kind == "pty"

    def test_argv0_codex_still_routes_to_codex(self, mux):
        m, pty, codex = mux
        h = m.start("c2", ["codex"], env=None, cwd=None)
        assert codex.calls == [("start", ("c2", ("codex",), None, None))]
        assert pty.calls == []
        assert h.payload.kind == "codex"

    def test_handle_dispatch_for_agy_goes_to_pty(self, mux):
        """Subsequent operations on an agy handle dispatch to PTY."""
        m, pty, codex = mux
        h = m.start("g4", ["agy"], env=None, cwd=None)
        m.write_stdin(h, b"hello\n")
        m.read_stdout(h, 4096)
        m.interrupt(h)
        m.close(h)
        op_kinds = [c[0] for c in pty.calls]
        assert op_kinds == ["start", "write_stdin", "read_stdout", "interrupt", "close"]
        assert codex.calls == []
