"""Helper-side Unix domain socket server for local control.

Phase 3 — "Local Transport Foundation" (Iter 1) plus the next slice
that lets the macOS app drive same-Mac existing sessions (Iter 2A).

Wire format:
    [4-byte big-endian uint32 length] [UTF-8 JSON request body]

A single connection may carry multiple sequential request/response
pairs (no pipelining: client sends one frame, waits for the reply, then
sends the next). The 4-byte length cap is enforced symmetrically — both
read and write reject anything > 1 MiB without writing it.

Request envelope:
    {
        "id": "<opaque correlation id, echoed in reply>",
        "method": "hello" | "ping" | "get_local_control_status" |
                  "set_local_control_enabled" |
                  "start_session" | "list_sessions" | "stop_session" |
                  "send_input",
        "auth_token": "<base64 helper-auth-token>",
        "params": { ... method-specific ... }
    }

Reply envelope (success):
    { "id": "<echoed>", "ok": true, "result": { ... } }

Reply envelope (error):
    { "id": "<echoed>", "ok": false, "error": { "code": "...", "message": "..." } }

Error codes (stable contract — Swift `LocalSessionControlClient` maps
each one to a typed error case):

    "unauthenticated"     bad / missing / mismatched auth_token
    "version_mismatch"    client requested an unsupported protocol
    "not_implemented"     known method, not in this iteration's caps
    "local_control_off"   helper config has local_control_enabled = false
    "internal"            executor raised; details elided to message
    "bad_request"         malformed JSON or missing required field
    "unknown_method"      method string is not one of the documented set
    "frame_too_large"     declared length > MAX_PAYLOAD
    "frame_truncated"     stream closed mid-body
    "session_not_found"   send_input / stop_session referenced an id
                          that has no record in either the managed
                          set or the detected set
    "not_controllable"    the id IS visible (detected via process
                          scanning) but the helper does not own its
                          PTY, so write/stop is not safe to attempt

Auth posture
============

`hello` is the ONE method that may be called without a valid
`auth_token` — the client uses it to negotiate protocol / capabilities
before signing its first real call, AND to detect "helper not
running" without first needing the on-disk token to exist. Every
other method, including `ping`, requires a matching auth_token.

(Iter 1 of this branch let `ping` slip through unauthenticated; that
gave any local process a free liveness probe of the helper. The Codex
review caught it; this iteration tightens the policy to "hello-only
bypass". `ping` is still cheap and useful — clients just have to
include the token.)

Capabilities
============

The `hello` reply advertises a `capabilities` map the macOS UI uses
to gate features:

    {
        "send_input":        true,    # iter 2A: managed sessions accept stdin
        "subscribe_events":  false,   # iter 2A+: streaming output (deferred)
        "approvals":         false,   # iter 2B: hook approvals (deferred)
    }

Listing existing same-Mac sessions
==================================

`list_sessions` returns BOTH:
  * `managed`: sessions this helper spawned via `start_session` —
    full lifecycle control (start / list / stop / send_input).
  * `detected`: same-Mac processes the helper's existing
    `_should_ignore_command` + `_detect_provider` classifier
    (PR #14) recognises as Claude. **Read-only**: the helper does
    not own these PTYs, so `send_input` and `stop_session` against a
    detected-but-not-managed id are rejected with
    `session_not_found`. Listing is safe; arbitrary writes to a
    user terminal are not.
"""
from __future__ import annotations

import json
import logging
import os
import socket
import struct
import sys
import threading
from pathlib import Path
from typing import Any, Callable

from local_auth_token import compare as compare_tokens

logger = logging.getLogger("cli_pulse.local_session_server")

# ── wire constants ────────────────────────────────────────────

PROTOCOL_VERSION = 1
SOCK_FILENAME = "clipulse-helper.sock"
LENGTH_PREFIX = 4                # 4-byte big-endian uint32
MAX_PAYLOAD = 1 << 20            # 1 MiB
LISTEN_BACKLOG = 8

# Methods this revision of the helper advertises in `hello`. iter 2A
# adds `status` (authenticated state hydration), `send_input` (managed
# session stdin); iter 2B will add `subscribe_events` + approvals.
SUPPORTED_METHODS = (
    "hello",
    "ping",
    "get_local_control_status",
    "set_local_control_enabled",
    "start_session",
    "list_sessions",
    "stop_session",
    "send_input",
)

# Methods whose body may skip auth_token validation. `hello` is the
# only one — the client uses it to negotiate protocol / capabilities
# before it has any reason to authenticate. `ping` no longer bypasses
# (Codex review fix): a free liveness probe was a small but pointless
# information leak, and clients always have the token by the time
# they're calling ping (they read it once at startup).
UNAUTHENTICATED_METHODS = frozenset({"hello"})

# Methods that do NOT require local_control_enabled = true. The
# handshake / introspection methods + the toggle itself all bypass
# this gate; the session-control methods do not.
GATE_BYPASSED_METHODS = frozenset(
    {"hello", "ping", "get_local_control_status", "set_local_control_enabled"}
)


def container_dir() -> Path:
    """Default app group container path. Lives next to the auth token."""
    from local_auth_token import container_path
    return container_path()


def default_socket_path() -> Path:
    return container_dir() / SOCK_FILENAME


# ── stale socket recovery ──────────────────────────────────────


def _is_socket_alive(path: Path) -> bool:
    """Return True iff a process is currently accepting on `path`."""
    if not path.exists():
        return False
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(0.5)
    try:
        probe.connect(str(path))
        probe.close()
        return True
    except OSError:
        return False


def prepare_socket_path(path: Path) -> None:
    """Ensure `path` is free for bind. Raises RuntimeError if a live
    server is already holding it (the daemon should fail loudly rather
    than silently take over an already-running helper).

    Creates the parent directory if missing. The macOS app group
    container is auto-created the first time the macOS app launches;
    on a fresh helper-only install the directory may not exist yet.
    """
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        if _is_socket_alive(path):
            raise RuntimeError(
                f"another server is already listening at {path}; refusing to bind"
            )
        logger.info("removing stale socket at %s", path)
        path.unlink()


# ── framing ────────────────────────────────────────────────────


class FrameError(Exception):
    """Raised when a frame is malformed, truncated, or oversize."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _recv_exact(conn: socket.socket, n: int) -> bytes | None:
    """Read exactly n bytes from `conn`. Returns None on clean EOF
    BEFORE any byte has been read; raises FrameError on EOF mid-frame.
    """
    if n == 0:
        return b""
    buf = bytearray()
    while len(buf) < n:
        try:
            chunk = conn.recv(n - len(buf))
        except OSError as exc:
            raise FrameError("frame_truncated", f"recv failed: {exc}") from exc
        if not chunk:
            if not buf:
                return None
            raise FrameError("frame_truncated", "stream closed mid-body")
        buf.extend(chunk)
    return bytes(buf)


def read_frame(conn: socket.socket, max_payload: int = MAX_PAYLOAD) -> bytes | None:
    """Read one length-prefixed frame. Returns None on clean EOF.

    Raises FrameError("frame_too_large") if the announced length
    exceeds `max_payload` (the connection is doomed at that point —
    the caller should close it without trying to skip the body).
    """
    header = _recv_exact(conn, LENGTH_PREFIX)
    if header is None:
        return None
    (length,) = struct.unpack("!I", header)
    if length > max_payload:
        raise FrameError(
            "frame_too_large",
            f"declared length {length} exceeds cap {max_payload}",
        )
    if length == 0:
        return b""
    body = _recv_exact(conn, length)
    if body is None:
        # _recv_exact returns None only when n=0 OR clean EOF before
        # the first byte. Length>0 + None means "clean EOF before
        # any body byte" — still a truncated frame from our perspective.
        raise FrameError("frame_truncated", "EOF before body bytes")
    return body


def write_frame(conn: socket.socket, body: bytes, max_payload: int = MAX_PAYLOAD) -> None:
    if len(body) > max_payload:
        raise FrameError(
            "frame_too_large",
            f"refusing to send oversize frame: {len(body)}",
        )
    conn.sendall(struct.pack("!I", len(body)) + body)


# ── reply helpers ─────────────────────────────────────────────


def _ok(req_id: Any, result: Any) -> bytes:
    return json.dumps({"id": req_id, "ok": True, "result": result}).encode("utf-8")


def _err(req_id: Any, code: str, message: str) -> bytes:
    return json.dumps(
        {"id": req_id, "ok": False, "error": {"code": code, "message": message}}
    ).encode("utf-8")


# ── server ────────────────────────────────────────────────────


class LocalSessionServer:
    """UDS server that exposes a small RPC surface to the macOS app
    on the same machine.

    Every request that mutates RemoteAgentManager state is dispatched
    via `executor.submit_and_wait(...)` so the daemon poll loop and
    the local server share a single writer thread. Read-only handlers
    (hello, ping) skip the executor.

    Lifecycle:
      * `start()` binds the socket, spawns the accept thread, returns.
      * `stop()` closes the listener, waits for the accept thread,
        and joins outstanding connection threads briefly. Idempotent.
    """

    def __init__(
        self,
        *,
        socket_path: Path | str,
        get_auth_token: Callable[[], str],
        get_local_control_enabled: Callable[[], bool],
        set_local_control_enabled: Callable[[bool], None],
        start_session: Callable[[dict], dict],
        list_sessions: Callable[[], list[dict]],
        stop_session: Callable[[str], dict],
        send_input: Callable[[str, str], dict],
        list_detected_sessions: Callable[[], list[dict]] | None = None,
        max_payload: int = MAX_PAYLOAD,
    ) -> None:
        self._socket_path = Path(socket_path)
        self._get_auth_token = get_auth_token
        self._get_local_control_enabled = get_local_control_enabled
        self._set_local_control_enabled = set_local_control_enabled
        self._start_session = start_session
        self._list_sessions = list_sessions
        self._stop_session = stop_session
        self._send_input = send_input
        # `list_detected_sessions` returns same-Mac Claude processes
        # the helper detected via PR #14's `_should_ignore_command` +
        # `_detect_provider`. These are read-only for the local UDS
        # surface — see module docstring for the controllability
        # boundary. Optional so unit tests can omit it.
        self._list_detected_sessions = list_detected_sessions
        self._max_payload = max_payload

        self._listener: socket.socket | None = None
        self._accept_thread: threading.Thread | None = None
        self._stop_flag = threading.Event()
        self._conn_threads: list[threading.Thread] = []
        self._conn_threads_lock = threading.Lock()

    # ── public ──────────────────────────────────────────────

    def start(self) -> None:
        """Bind the socket and start accepting connections in a
        background thread. Raises if the socket can't be bound (e.g.
        another server is live, or the container directory is missing).
        """
        prepare_socket_path(self._socket_path)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(str(self._socket_path))
        os.chmod(self._socket_path, 0o600)
        listener.listen(LISTEN_BACKLOG)
        listener.settimeout(0.5)  # so the accept loop notices stop_flag
        self._listener = listener
        self._accept_thread = threading.Thread(
            target=self._accept_loop,
            name="cli-pulse-uds-accept",
            daemon=True,
        )
        self._accept_thread.start()
        logger.info("local UDS server listening at %s (pid=%d)", self._socket_path, os.getpid())

    def stop(self, *, join_timeout: float = 1.0) -> None:
        """Stop accepting + close the listener. Idempotent."""
        if self._stop_flag.is_set():
            return
        self._stop_flag.set()
        if self._listener is not None:
            try:
                self._listener.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                self._listener.close()
            except OSError:
                pass
            self._listener = None
        if self._accept_thread is not None:
            self._accept_thread.join(timeout=join_timeout)
            self._accept_thread = None
        # Connection threads are daemonic; we attempt a brief join so
        # the daemon's shutdown reads cleanly in tests, but the OS will
        # reap them at process exit if a peer holds a connection open.
        with self._conn_threads_lock:
            threads = list(self._conn_threads)
            self._conn_threads.clear()
        for t in threads:
            t.join(timeout=join_timeout)
        # Best-effort socket cleanup. macOS app group containers are
        # writable by both helper and app; leaving the socket file
        # behind would cause the next helper start to attempt a stale-
        # socket recovery, which works but logs noisily.
        try:
            self._socket_path.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            logger.warning("socket unlink on stop failed: %s", exc)
        logger.info("local UDS server stopped")

    # ── internal ────────────────────────────────────────────

    def _accept_loop(self) -> None:
        listener = self._listener
        assert listener is not None
        while not self._stop_flag.is_set():
            try:
                conn, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                # Listener was closed from stop() — exit cleanly.
                return
            t = threading.Thread(
                target=self._serve_connection,
                args=(conn,),
                name="cli-pulse-uds-conn",
                daemon=True,
            )
            with self._conn_threads_lock:
                self._conn_threads.append(t)
            t.start()

    def _serve_connection(self, conn: socket.socket) -> None:
        try:
            while not self._stop_flag.is_set():
                try:
                    body = read_frame(conn, max_payload=self._max_payload)
                except FrameError as exc:
                    # No req_id available — best we can do is reply
                    # with an envelope-less error and close. The
                    # client treats that as a transport-level fault.
                    logger.warning("frame error: %s", exc)
                    try:
                        write_frame(
                            conn,
                            _err(None, exc.code, exc.message),
                            max_payload=self._max_payload,
                        )
                    except OSError:
                        pass
                    return
                if body is None:
                    return  # clean EOF
                reply = self._dispatch(body)
                try:
                    write_frame(conn, reply, max_payload=self._max_payload)
                except FrameError as exc:
                    # Reply itself oversize — should never happen for
                    # iter 1 methods (their results are tiny). Log and
                    # close; the client gets a transport-level error.
                    logger.warning("oversize reply: %s", exc)
                    return
                except OSError as exc:
                    logger.debug("client disconnected mid-reply: %s", exc)
                    return
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def _dispatch(self, body: bytes) -> bytes:
        """Decode + route one request frame. Always returns a complete
        reply envelope as bytes — never raises out to the caller, so
        the connection stays alive through transient logical errors.
        """
        # 1. JSON decode.
        try:
            req = json.loads(body.decode("utf-8"))
        except UnicodeDecodeError:
            return _err(None, "bad_request", "request body is not valid UTF-8")
        except json.JSONDecodeError as exc:
            return _err(None, "bad_request", f"invalid JSON: {exc.msg}")

        if not isinstance(req, dict):
            return _err(None, "bad_request", "request envelope must be an object")

        req_id = req.get("id")
        method = req.get("method")
        params = req.get("params") or {}
        if not isinstance(method, str) or not method:
            return _err(req_id, "bad_request", "missing or non-string 'method'")
        if not isinstance(params, dict):
            return _err(req_id, "bad_request", "'params' must be an object")

        if method not in SUPPORTED_METHODS:
            return _err(req_id, "unknown_method", f"unknown method: {method!r}")

        # 2. Auth gate. Hello / ping bypass; everything else requires a
        #    matching token. Constant-time comparison via local_auth_token.
        if method not in UNAUTHENTICATED_METHODS:
            supplied = req.get("auth_token")
            if not isinstance(supplied, str) or not supplied:
                return _err(req_id, "unauthenticated", "auth_token required")
            try:
                expected = self._get_auth_token()
            except Exception as exc:  # noqa: BLE001 — defensive
                logger.warning("auth_token getter raised: %s", exc)
                return _err(req_id, "internal", "auth state unavailable")
            if not compare_tokens(expected, supplied):
                return _err(req_id, "unauthenticated", "invalid auth_token")

        # 3. Local control enabled gate. Bypassed for handshake +
        #    the toggle method itself; required for everything else.
        if method not in GATE_BYPASSED_METHODS:
            try:
                enabled = bool(self._get_local_control_enabled())
            except Exception as exc:  # noqa: BLE001
                logger.warning("local_control_enabled getter raised: %s", exc)
                return _err(req_id, "internal", "config state unavailable")
            if not enabled:
                return _err(
                    req_id,
                    "local_control_off",
                    "local_control_enabled is false; toggle in the macOS app first",
                )

        # 4. Method-specific dispatch.
        # Diagnostic log — non-sensitive: only the method name and
        # (when present) the session_id reference. Never the payload.
        # Mirrors the existing Supabase remote-poll dispatcher's
        # observability so users can see in helper.log whether a UI
        # action took the local UDS path or the cloud queue path.
        sid = params.get("session_id") if isinstance(params, dict) else None
        if isinstance(sid, str):
            logger.info("local_rpc method=%s session=%s", method, sid)
        else:
            logger.info("local_rpc method=%s", method)
        try:
            result = self._handle_method(method, params)
        except _RequestError as exc:
            logger.info(
                "local_rpc method=%s result=error code=%s",
                method, exc.code,
            )
            return _err(req_id, exc.code, exc.message)
        except Exception as exc:  # noqa: BLE001 — internal
            logger.warning("method %s raised: %s", method, exc)
            return _err(req_id, "internal", f"{type(exc).__name__}")
        # Light result logging for list_sessions so the user can see
        # managed/detected counts without needing to capture the
        # whole reply.
        if method == "list_sessions" and isinstance(result, dict):
            logger.info(
                "local_rpc method=list_sessions managed=%d detected=%d",
                len(result.get("managed", []) or []),
                len(result.get("detected", []) or []),
            )
        return _ok(req_id, result)

    def _handle_method(self, method: str, params: dict) -> Any:
        if method == "hello":
            requested = params.get("client_protocol_version")
            if requested is not None and requested != PROTOCOL_VERSION:
                raise _RequestError(
                    "version_mismatch",
                    f"helper speaks protocol {PROTOCOL_VERSION}, client requested {requested}",
                )
            return {
                "protocol_version": PROTOCOL_VERSION,
                "supported_methods": list(SUPPORTED_METHODS),
                "helper_pid": os.getpid(),
                # Capability flags the UI uses to decide what to show.
                # send_input lights up this iteration — managed Claude
                # sessions accept stdin via the executor → same code
                # path as the existing Supabase prompt RPC.
                # subscribe_events + approvals stay false until iter 2B.
                "capabilities": {
                    "send_input": True,
                    "subscribe_events": False,
                    "approvals": False,
                },
            }

        if method == "ping":
            return {"pong": True}

        if method == "get_local_control_status":
            # Authenticated state hydration — the macOS app calls this
            # on launch (and after `set_local_control_enabled`) so the
            # toggle UI reflects the helper's actual state without the
            # app having to keep its own duplicate.
            try:
                enabled = bool(self._get_local_control_enabled())
            except Exception as exc:  # noqa: BLE001
                logger.warning("local_control_enabled getter raised: %s", exc)
                raise _RequestError("internal", "config state unavailable") from exc
            return {
                "local_control_enabled": enabled,
                "protocol_version": PROTOCOL_VERSION,
                "helper_pid": os.getpid(),
            }

        if method == "set_local_control_enabled":
            value = params.get("enabled")
            if not isinstance(value, bool):
                raise _RequestError(
                    "bad_request", "'enabled' must be a boolean"
                )
            self._set_local_control_enabled(value)
            return {"enabled": value}

        if method == "start_session":
            provider = params.get("provider", "claude")
            if not isinstance(provider, str) or not provider:
                raise _RequestError("bad_request", "'provider' must be a string")
            if provider != "claude":
                raise _RequestError(
                    "not_implemented",
                    f"provider {provider!r} not supported in this iteration",
                )
            client_label = params.get("client_label")
            cwd_basename = params.get("cwd_basename") or ""
            cwd_hmac = params.get("cwd_hmac")
            payload = {
                "provider": provider,
                "client_label": client_label if isinstance(client_label, str) else None,
                "cwd_basename": cwd_basename if isinstance(cwd_basename, str) else "",
                "cwd_hmac": cwd_hmac if isinstance(cwd_hmac, str) else None,
            }
            return self._start_session(payload)

        if method == "list_sessions":
            # The reply now distinguishes `managed` (helper-spawned;
            # full lifecycle control) from `detected` (visible via
            # process scan but NOT helper-owned; read-only). Both
            # arrays carry a `controllable` flag so the UI can render
            # the right action set without having to know the source
            # taxonomy.
            managed_rows = self._list_sessions() or []
            detected_rows: list[dict] = []
            if self._list_detected_sessions is not None:
                try:
                    detected_rows = list(self._list_detected_sessions() or [])
                except Exception as exc:  # noqa: BLE001
                    # Detection is best-effort — a `ps` failure must
                    # not break the (more important) managed list.
                    logger.warning("list_detected_sessions raised: %s", exc)
                    detected_rows = []
            for row in managed_rows:
                row.setdefault("controllable", True)
                row.setdefault("source", "managed")
            for row in detected_rows:
                row["controllable"] = False
                row["source"] = "detected"
            return {
                "managed": managed_rows,
                "detected": detected_rows,
                # `sessions` kept for backward compatibility with
                # any client written against the iter-1 reply shape.
                # New clients should consume `managed` + `detected`.
                "sessions": managed_rows,
            }

        if method == "stop_session":
            session_id = params.get("session_id")
            if not isinstance(session_id, str) or not session_id:
                raise _RequestError("bad_request", "'session_id' must be a non-empty string")
            result = self._stop_session(session_id)
            # `local_stop_session` returns {"session_id":..., "stopped": bool}.
            # If `stopped` is False AND the id is in the detected set,
            # surface `not_controllable` so the UI can phrase it
            # correctly. Otherwise treat as `session_not_found`.
            if isinstance(result, dict) and result.get("stopped") is False:
                if self._is_detected_only(session_id):
                    raise _RequestError(
                        "not_controllable",
                        "session is detected via process scan but not helper-owned; "
                        "stop must be done from the user's terminal directly",
                    )
                raise _RequestError(
                    "session_not_found",
                    f"no managed session with id {session_id!r}",
                )
            return result

        if method == "send_input":
            session_id = params.get("session_id")
            payload = params.get("payload")
            if not isinstance(session_id, str) or not session_id:
                raise _RequestError("bad_request", "'session_id' must be a non-empty string")
            if not isinstance(payload, str):
                raise _RequestError("bad_request", "'payload' must be a string")
            # Symmetric with stop: the helper-owned send delegates to
            # `RemoteAgentManager.write_to_session` (already covered by
            # `helper/test_remote_agent_submit.py` for CR/newline
            # behaviour, which we do NOT regress here).
            result = self._send_input(session_id, payload)
            if isinstance(result, dict) and result.get("written") is False:
                if self._is_detected_only(session_id):
                    raise _RequestError(
                        "not_controllable",
                        "session is detected via process scan but not helper-owned; "
                        "input would need to go through the user's terminal directly",
                    )
                raise _RequestError(
                    "session_not_found",
                    f"no managed session with id {session_id!r}",
                )
            return result

        # Should be unreachable: SUPPORTED_METHODS / _handle_method
        # must stay in sync.
        raise _RequestError("unknown_method", f"unhandled method: {method!r}")

    def _is_detected_only(self, session_id: str) -> bool:
        """True if `session_id` is in the detected-but-unmanaged set.
        Cheap re-call of the detected getter; the alternative
        (caching the detected list across the request) would risk
        showing stale ownership during a process restart.
        """
        if self._list_detected_sessions is None:
            return False
        try:
            for row in self._list_detected_sessions() or []:
                if row.get("session_id") == session_id:
                    return True
        except Exception:  # noqa: BLE001
            pass
        return False


class _RequestError(Exception):
    """Internal sentinel for handler-side typed errors. Never escapes
    the dispatch loop — _dispatch maps it to a wire-level error envelope.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# ── standalone CLI for ad-hoc testing ──────────────────────────


def _cli() -> int:
    """Tiny standalone server used only when debugging the wire format
    without the full daemon. Not on the import path of any production
    code; safe to delete if it bitrots.
    """
    import argparse
    import time

    from local_auth_token import load_token, rotate_token

    parser = argparse.ArgumentParser(description="local UDS RPC test server")
    parser.add_argument("--rotate-token", action="store_true",
                        help="rotate the helper-auth-token before serving")
    parser.add_argument("--enabled", action="store_true",
                        help="run with local_control_enabled = true")
    args = parser.parse_args()

    if args.rotate_token:
        rotate_token()
    token = load_token() or rotate_token()
    enabled = {"v": args.enabled}

    def fake_start(_p: dict) -> dict:
        return {"session_id": "fake-cli", "ok": True}

    def fake_list() -> list[dict]:
        return []

    def fake_stop(sid: str) -> dict:
        return {"session_id": sid, "stopped": False}

    def fake_send_input(sid: str, _payload: str) -> dict:
        return {"session_id": sid, "written": False}

    server = LocalSessionServer(
        socket_path=default_socket_path(),
        get_auth_token=lambda: token,
        get_local_control_enabled=lambda: enabled["v"],
        set_local_control_enabled=lambda v: enabled.update(v=v),
        start_session=fake_start,
        list_sessions=fake_list,
        stop_session=fake_stop,
        send_input=fake_send_input,
        list_detected_sessions=lambda: [],
    )
    server.start()
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        pass
    finally:
        server.stop()
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
