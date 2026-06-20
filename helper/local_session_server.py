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

from local_approvals import ApprovalError, ApprovalRegistry
from local_auth_token import compare as compare_tokens
from local_events import EventBroker, Subscription

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
    # v1.30.x in-app xterm.js terminal: raw keystrokes + window resize.
    "send_input_raw",
    "resize",
    # v-next P1-2: reattach repaint — tail of the per-session raw output ring.
    "get_tail_snapshot",
    # Phase 3 Iter 2B: app-side streaming + structured approvals.
    "subscribe_events",
    "approve_action",
    "get_pending_approvals",
    # Hook-side ingress. These methods reject the app auth_token and
    # accept ONLY a per-session capability token + session_id. See
    # `_dispatch` for the auth-table enforcement.
    "hook_create_approval",
    "hook_wait_decision",
    # Phase 4 helper-bundling: idempotent install of the
    # PermissionRequest hook into ~/.claude/settings.json. Sandboxed
    # macOS app cannot write that path directly, so it asks the
    # unsandboxed helper (this UDS server) to do it. Wraps the
    # existing `permissions_diagnose.install_claude_hook` function
    # and reports the action / previous_command / new_command back
    # to the app for UI rendering.
    "install_claude_hook",
)

# Methods whose body uses the per-session capability token (set by
# `RemoteAgentManager._build_env`) instead of the global app auth
# token. They are reachable by the hook subprocess Claude spawns and
# are deliberately kept narrow: the hook can request an approval or
# wait for one to resolve, but cannot list sessions, cannot send
# input, and cannot decide approvals on its own.
HOOK_AUTH_METHODS = frozenset({"hook_create_approval", "hook_wait_decision"})

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
        send_input_raw: Callable[[str, str], bool] | None = None,
        resize: Callable[[str, int, int], bool] | None = None,
        get_tail_snapshot: Callable[[str, int], dict | None] | None = None,
        list_detected_sessions: Callable[[], list[dict]] | None = None,
        event_broker: EventBroker | None = None,
        approval_registry: ApprovalRegistry | None = None,
        subscribe_idle_timeout_s: float = 30.0,
        max_payload: int = MAX_PAYLOAD,
        get_helper_argv0: Callable[[], str | None] | None = None,
        get_paired: Callable[[], bool] | None = None,
    ) -> None:
        self._socket_path = Path(socket_path)
        self._get_auth_token = get_auth_token
        # v1.30.2 (RC-1): whether this helper has a usable pairing config.
        # Surfaced in the unauthenticated `hello` reply so the macOS app can
        # tell "installed + running but not paired" apart from "not installed"
        # — the local UDS surface now binds even when unpaired (so the app can
        # detect the helper at all), and `paired:false` lets the UI prompt the
        # user to pair instead of showing a misleading "not installed". Defaults
        # to True so existing callers / unit tests that omit it keep the old
        # behaviour (a helper that DID construct a manager is, by definition,
        # paired).
        self._get_paired = get_paired or (lambda: True)
        self._get_local_control_enabled = get_local_control_enabled
        self._set_local_control_enabled = set_local_control_enabled
        self._start_session = start_session
        self._list_sessions = list_sessions
        self._stop_session = stop_session
        self._send_input = send_input
        # v1.30.x in-app terminal: optional raw-input + resize. None ⇒ the UDS
        # method replies `not_implemented` (older wiring / unit tests).
        self._send_input_raw = send_input_raw
        self._resize = resize
        # v-next P1-2: reattach repaint. None ⇒ the UDS method replies
        # `not_implemented` (older wiring / unit tests).
        self._get_tail_snapshot = get_tail_snapshot
        # Phase 4 helper-bundling: `install_claude_hook` UDS method
        # asks the helper to write its OWN argv[0] into the
        # PermissionRequest hook command. Returning None signals
        # the install method is unavailable (older helper, test
        # harness without an argv0 source).
        self._get_helper_argv0 = get_helper_argv0 or (lambda: None)
        # `list_detected_sessions` returns same-Mac Claude processes
        # the helper detected via PR #14's `_should_ignore_command` +
        # `_detect_provider`. These are read-only for the local UDS
        # surface — see module docstring for the controllability
        # boundary. Optional so unit tests can omit it.
        self._list_detected_sessions = list_detected_sessions
        # Phase 3 Iter 2B: the broker drives `subscribe_events` and
        # the registry drives `approve_action` / `get_pending_approvals`
        # / `hook_*`. Both default to None so tests that exercise only
        # the iter-2A surface don't need to wire them.
        self._event_broker = event_broker
        self._approval_registry = approval_registry
        self._subscribe_idle_timeout_s = subscribe_idle_timeout_s
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
                action = self._dispatch(body, conn=conn)
                if isinstance(action, _StreamHandoff):
                    # subscribe_events takes over the connection — we
                    # write the initial ack frame, then loop pushing
                    # event frames until the subscriber closes / the
                    # peer disconnects / the broker tears us down. The
                    # connection is dedicated to streaming after this
                    # so we never read another request frame from it.
                    self._stream_loop(conn, action)
                    return
                try:
                    write_frame(conn, action, max_payload=self._max_payload)
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
            # v1.21 F2: prune ourselves from _conn_threads so a long-running
            # helper with many short connections doesn't grow the list (and
            # the thread objects it pins) forever. The list is only used in
            # stop() to join() all active threads — finished threads being
            # absent there is correct behaviour (they've already terminated).
            current = threading.current_thread()
            with self._conn_threads_lock:
                try:
                    self._conn_threads.remove(current)
                except ValueError:
                    pass  # stop() already cleared the list

    # ── streaming loop ──────────────────────────────────────

    def _stream_loop(self, conn: socket.socket, handoff: "_StreamHandoff") -> None:
        """Drive a `subscribe_events` connection. Writes the initial
        ack frame, then drains the subscription's queue, frame-encoding
        each event. Returns (and the connection is closed by the
        outer `finally`) when the subscriber sees a close sentinel,
        the peer disconnects, or any frame write fails.
        """
        sub = handoff.subscription
        try:
            # Initial ack — gives the client a deterministic stream
            # start it can use to switch into streaming mode without
            # needing to wait for the first real event.
            try:
                write_frame(
                    conn,
                    _ok(handoff.req_id, handoff.initial_payload),
                    max_payload=self._max_payload,
                )
            except (FrameError, OSError) as exc:
                logger.debug("subscribe initial ack send failed: %s", exc)
                return
            # Listen on the connection for a clean close from the
            # client side too (NWConnection cancel) — we use a
            # separate thread to detect EOF without coupling it to
            # the subscription's blocking get().
            close_event = threading.Event()
            reader = threading.Thread(
                target=self._stream_eof_reader,
                args=(conn, close_event),
                name="cli-pulse-uds-stream-eof",
                daemon=True,
            )
            reader.start()
            while not self._stop_flag.is_set() and not close_event.is_set():
                event = sub.next(timeout=self._subscribe_idle_timeout_s)
                if event is None:
                    # Subscription closed (overflow already emitted its
                    # own error frame above, or broker shut down).
                    return
                # Inject a top-level "event_frame" so the Swift decoder
                # has a stable wrapper to identify each frame as one
                # streaming event vs the request/reply envelope used
                # by every other method. Keeps the wire shape uniform
                # without forcing the client to mode-switch by method
                # name.
                payload = json.dumps(event).encode("utf-8")
                try:
                    write_frame(conn, payload, max_payload=self._max_payload)
                except FrameError as exc:
                    logger.warning("stream frame oversize: %s", exc)
                    return
                except OSError as exc:
                    logger.debug("stream peer disconnected: %s", exc)
                    return
        finally:
            try:
                if self._event_broker is not None:
                    self._event_broker.unsubscribe(sub)
            except Exception:  # noqa: BLE001
                pass

    @staticmethod
    def _stream_eof_reader(conn: socket.socket, close_event: threading.Event) -> None:
        """Background reader: blocks on recv() and signals on EOF.
        We only ever expect EOF from a streaming peer (clients never
        send another request after subscribe_events). Bytes received
        unexpectedly are logged and treated as a protocol error.
        """
        try:
            while not close_event.is_set():
                try:
                    data = conn.recv(4096)
                except (OSError, ValueError):
                    close_event.set()
                    return
                if not data:
                    close_event.set()
                    return
                # A misbehaving client wrote into a streaming
                # connection — we don't decode but flag so the loop
                # can tear down cleanly.
                logger.debug("subscribe peer wrote %d unexpected bytes", len(data))
        finally:
            close_event.set()

    def _dispatch(
        self,
        body: bytes,
        *,
        conn: socket.socket | None = None,
    ) -> "bytes | _StreamHandoff":
        """Decode + route one request frame. Returns either the
        encoded reply envelope (bytes) OR a `_StreamHandoff` if the
        connection should be promoted to a long-lived stream
        (`subscribe_events`). Never raises out to the caller — the
        connection stays alive through transient logical errors.
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

        # 2. Auth gate. Three cases:
        #
        #   (a) hello bypasses every auth check (handshake).
        #
        #   (b) hook_create_approval / hook_wait_decision use the
        #       per-session capability token, NOT the app auth token.
        #       The hook subprocess Claude spawns reads
        #       CLI_PULSE_LOCAL_HOOK_TOKEN from its env and presents
        #       it here. Presenting the app auth token to a hook
        #       method is a hard error — that would mean the app
        #       auth token leaked into Claude's env.
        #
        #   (c) every other authenticated method uses the app auth
        #       token (constant-time compared via local_auth_token).
        #       Presenting a hook token to an app method is also a
        #       hard error, for the symmetric reason.
        if method == "hello":
            pass  # no auth
        elif method in HOOK_AUTH_METHODS:
            # Hook auth: session_id + session_token, both required.
            if "auth_token" in req:
                return _err(
                    req_id,
                    "unauthenticated",
                    "hook methods do not accept the app auth_token; "
                    "use session_token instead",
                )
            session_id = params.get("session_id")
            session_token = params.get("session_token")
            if not isinstance(session_id, str) or not session_id:
                return _err(
                    req_id, "unauthenticated",
                    "hook auth requires 'session_id'",
                )
            if not isinstance(session_token, str) or not session_token:
                return _err(
                    req_id, "unauthenticated",
                    "hook auth requires 'session_token'",
                )
            if self._approval_registry is None:
                return _err(
                    req_id, "not_implemented",
                    "approval registry not configured on this helper",
                )
            try:
                self._approval_registry.authenticate_hook(
                    session_id, session_token, peer_socket=conn,
                )
            except ApprovalError as exc:
                return _err(req_id, exc.code, exc.message)
        else:
            # App auth.
            if "session_token" in params:
                return _err(
                    req_id, "unauthenticated",
                    "app methods do not accept session_token; use auth_token",
                )
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
        # Streaming handoff: caller (`_serve_connection`) detects the
        # sentinel and switches into the stream loop. Do NOT wrap in
        # _ok here — the streaming loop emits its own initial ack
        # frame plus a sequence of event frames. We stamp the request
        # id post-hoc so the ack echoes the client's correlation id.
        if isinstance(result, _StreamHandoff):
            result.req_id = req_id
            return result
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
            # v1.15: include the list of providers whose CLI binary
            # the helper can actually spawn on this host. The macOS /
            # iOS spawn picker uses this to gray out unavailable
            # providers in the dropdown so users don't try to start a
            # Codex session on a Mac that doesn't have Codex installed.
            # Falls back to a defensive empty list rather than raising,
            # so a stale `provider_spawners` import doesn't break the
            # whole hello reply.
            try:
                # Bare import (no `helper.` prefix) — CI runs pytest
                # with helper/ as the working directory, and the helper
                # daemon itself is invoked from within the helper/ dir
                # too, so the package-qualified path does not resolve
                # in either runtime.
                from provider_spawners import available_providers
                provider_availability = list(available_providers())
            except Exception:  # noqa: BLE001
                provider_availability = ["claude"]
            # v1.16: expose helper_version in the hello reply so the MAS
            # app's HelperInstaller state machine can distinguish
            # "v1.15 nohup helper" from "v1.16 pkg-installed helper" and
            # decide whether to offer the migration prompt.
            try:
                from system_collector import HELPER_VERSION as _hv
                helper_version = _hv
            except Exception:  # noqa: BLE001
                helper_version = "0.0.0"
            # v1.30.2 (RC-1): report pairing state. Failure-soft — a getter
            # exception must never break the hello handshake (that would
            # regress the helper back to undetectable), so default to True.
            try:
                paired = bool(self._get_paired())
            except Exception:  # noqa: BLE001
                paired = True
            return {
                "protocol_version": PROTOCOL_VERSION,
                "supported_methods": list(SUPPORTED_METHODS),
                "helper_pid": os.getpid(),
                "helper_version": helper_version,
                # v1.30.2: paired=false ⇒ installed + running but no usable
                # config yet. The macOS app renders "installed — pair to
                # activate" instead of "not installed".
                "paired": paired,
                # Capability flags the UI uses to decide what to show.
                # send_input lights up this iteration — managed Claude
                # sessions accept stdin via the executor → same code
                # path as the existing Supabase prompt RPC.
                # subscribe_events + approvals stay false until iter 2B.
                "capabilities": {
                    "send_input": True,
                    # Iter 2B: subscribe_events + approvals light up
                    # only when the helper actually wired the broker /
                    # registry. A daemon that fails to construct them
                    # (e.g. unsupported platform, init exception) keeps
                    # the iter-2A surface and the macOS UI silently
                    # falls back to snapshot polling.
                    "subscribe_events": self._event_broker is not None,
                    "approvals": self._approval_registry is not None,
                },
                # v1.15: array of installed providers (subset of
                # ['claude','codex','gemini']). UI uses this to disable
                # menu items for providers whose binary is missing.
                "provider_availability": provider_availability,
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
            # v1.15: accept any provider whose helper-side spawner
            # exists. The check uses the same registry as the remote
            # path so the two surfaces stay in lockstep — codex review
            # 2026-05-08 caught the local rejection bug where the
            # macOS picker would happily send `codex` and the helper
            # would refuse it with `not_implemented`.
            try:
                from provider_spawners import get_spawner
                allow_provider = get_spawner(provider) is not None
            except Exception:  # noqa: BLE001
                allow_provider = (provider == "claude")
            if not allow_provider:
                raise _RequestError(
                    "not_implemented",
                    f"provider {provider!r} not supported by this helper",
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

        if method == "subscribe_events":
            if self._event_broker is None:
                raise _RequestError(
                    "not_implemented",
                    "event broker not configured on this helper",
                )
            session_filter = params.get("session_id")
            if session_filter is not None and not isinstance(session_filter, str):
                raise _RequestError(
                    "bad_request", "'session_id' must be a string when present",
                )
            # v1.30.x in-app terminal: opt into the raw (un-stripped) output
            # stream. Default false → today's redacted+stripped output_delta.
            raw = bool(params.get("raw", False))
            sub = self._event_broker.subscribe(session_filter=session_filter, raw=raw)
            # Initial snapshot — gives the macOS app a deterministic
            # starting point for the row's preview state without a
            # second round-trip. We include the most recent
            # list_sessions managed rows + per-session pending
            # approvals (when scoped, just that session's).
            initial: dict[str, Any] = {
                "subscribed": True,
                "session_id": session_filter,
            }
            try:
                managed_rows = list(self._list_sessions() or [])
            except Exception as exc:  # noqa: BLE001
                logger.debug("snapshot list_sessions failed: %s", exc)
                managed_rows = []
            initial["managed_sessions"] = managed_rows
            if self._approval_registry is not None:
                try:
                    initial["pending_approvals"] = self._approval_registry.list_pending(
                        session_filter,
                    )
                except Exception as exc:  # noqa: BLE001
                    logger.debug("snapshot list_pending failed: %s", exc)
                    initial["pending_approvals"] = []
            else:
                initial["pending_approvals"] = []
            # Returning the handoff bypasses the normal one-shot
            # reply path; the caller (`_serve_connection`) detects
            # this sentinel and switches into the streaming loop.
            return _StreamHandoff(
                req_id=None,    # _dispatch stamps this before returning
                initial_payload=initial,
                subscription=sub,
            )

        if method == "approve_action":
            if self._approval_registry is None:
                raise _RequestError(
                    "not_implemented",
                    "approval registry not configured on this helper",
                )
            session_id = params.get("session_id")
            approval_id = params.get("approval_id")
            decision = params.get("decision")
            comment = params.get("comment")
            if not isinstance(session_id, str) or not session_id:
                raise _RequestError("bad_request", "'session_id' must be a string")
            if not isinstance(approval_id, str) or not approval_id:
                raise _RequestError("bad_request", "'approval_id' must be a string")
            if decision not in ("approve", "reject"):
                raise _RequestError(
                    "bad_request",
                    "'decision' must be 'approve' or 'reject'",
                )
            if comment is not None and not isinstance(comment, str):
                raise _RequestError("bad_request", "'comment' must be a string when present")
            comment_str = comment[:512] if isinstance(comment, str) else None
            try:
                resolved = self._approval_registry.decide(
                    approval_id, decision,
                    comment=comment_str,
                    session_id_hint=session_id,
                )
            except ApprovalError as exc:
                raise _RequestError(exc.code, exc.message) from exc
            return resolved

        if method == "get_pending_approvals":
            if self._approval_registry is None:
                raise _RequestError(
                    "not_implemented",
                    "approval registry not configured on this helper",
                )
            session_id = params.get("session_id")
            if session_id is not None and not isinstance(session_id, str):
                raise _RequestError(
                    "bad_request", "'session_id' must be a string when present",
                )
            return {
                "pending_approvals": self._approval_registry.list_pending(session_id),
            }

        if method == "hook_create_approval":
            # Hook auth ran upstream in `_dispatch`; we're guaranteed
            # the registry exists and the caller is descended from
            # the right Claude PID + holds the right capability token.
            assert self._approval_registry is not None
            session_id = params["session_id"]   # hook auth validated presence
            kind = params.get("type") or params.get("kind") or "PermissionRequest"
            title = params.get("title") or kind
            summary = params.get("summary") or ""
            metadata = params.get("tool_metadata") or {}
            if not isinstance(metadata, dict):
                raise _RequestError(
                    "bad_request", "'tool_metadata' must be an object when present",
                )
            timeout_s = params.get("timeout_s")
            if timeout_s is None:
                timeout_value = 60.0
            else:
                try:
                    timeout_value = float(timeout_s)
                except (TypeError, ValueError):
                    raise _RequestError(
                        "bad_request",
                        "'timeout_s' must be a number",
                    ) from None
                timeout_value = max(1.0, min(timeout_value, 300.0))
            try:
                approval_id = self._approval_registry.create_pending(
                    session_id,
                    kind=str(kind),
                    title=str(title),
                    summary=str(summary),
                    tool_metadata=metadata,
                    timeout_s=timeout_value,
                )
            except ApprovalError as exc:
                raise _RequestError(exc.code, exc.message) from exc
            return {"approval_id": approval_id}

        if method == "hook_wait_decision":
            assert self._approval_registry is not None
            session_id = params["session_id"]
            approval_id = params.get("approval_id")
            if not isinstance(approval_id, str) or not approval_id:
                raise _RequestError(
                    "bad_request", "'approval_id' must be a non-empty string",
                )
            timeout_s = params.get("timeout_s")
            if timeout_s is None:
                timeout_value = 120.0
            else:
                try:
                    timeout_value = float(timeout_s)
                except (TypeError, ValueError):
                    raise _RequestError(
                        "bad_request",
                        "'timeout_s' must be a number",
                    ) from None
                timeout_value = max(1.0, min(timeout_value, 600.0))
            # IMPORTANT: this call blocks for up to `timeout_value`s
            # waiting on a Condition var. It runs on the per-
            # connection thread (NOT the single-writer executor), so
            # other sessions' send / list / stop continue to flow.
            try:
                resolved = self._approval_registry.wait_for_decision(
                    session_id, approval_id, timeout_s=timeout_value,
                )
            except ApprovalError as exc:
                raise _RequestError(exc.code, exc.message) from exc
            return resolved

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

        if method == "send_input_raw":
            # v1.30.x in-app terminal: raw keystrokes (no CR mangling). The
            # client sends `payload_base64` (matches LocalSessionControlClient).
            session_id = params.get("session_id")
            payload_b64 = params.get("payload_base64")
            if not isinstance(session_id, str) or not session_id:
                raise _RequestError("bad_request", "'session_id' must be a non-empty string")
            if not isinstance(payload_b64, str):
                raise _RequestError("bad_request", "'payload_base64' must be a string")
            if self._send_input_raw is None:
                raise _RequestError("not_implemented", "send_input_raw unavailable on this helper")
            ok = self._send_input_raw(session_id, payload_b64)
            if ok is False:
                raise _RequestError("session_not_found",
                                    f"no managed session with id {session_id!r}")
            return {"written": True}

        if method == "resize":
            # v1.30.x in-app terminal: window resize (SIGWINCH to the PTY).
            session_id = params.get("session_id")
            rows = params.get("rows")
            cols = params.get("cols")
            if not isinstance(session_id, str) or not session_id:
                raise _RequestError("bad_request", "'session_id' must be a non-empty string")
            if not isinstance(rows, int) or not isinstance(cols, int):
                raise _RequestError("bad_request", "'rows' and 'cols' must be integers")
            if self._resize is None:
                raise _RequestError("not_implemented", "resize unavailable on this helper")
            ok = self._resize(session_id, rows, cols)
            if ok is False:
                raise _RequestError("session_not_found",
                                    f"no managed session with id {session_id!r}")
            return {"resized": True}

        if method == "get_tail_snapshot":
            # v-next P1-2: reattach repaint — return up to `max_bytes` of the
            # session's recent RAW redacted output as base64. The Swift client
            # sends {session_id, max_bytes} (default 8192) and expects
            # {bytes_base64}; the helper caps max_bytes at the ring size.
            session_id = params.get("session_id")
            if not isinstance(session_id, str) or not session_id:
                raise _RequestError("bad_request", "'session_id' must be a non-empty string")
            max_bytes = params.get("max_bytes", 8192)
            if not isinstance(max_bytes, int) or isinstance(max_bytes, bool):
                raise _RequestError("bad_request", "'max_bytes' must be an integer")
            if self._get_tail_snapshot is None:
                raise _RequestError("not_implemented",
                                    "get_tail_snapshot unavailable on this helper")
            result = self._get_tail_snapshot(session_id, max_bytes)
            if result is None:
                raise _RequestError("session_not_found",
                                    f"no managed session with id {session_id!r}")
            return result

        if method == "install_claude_hook":
            # Phase 4 helper-bundling: app asks helper to write the
            # PermissionRequest hook into ~/.claude/settings.json.
            # Sandboxed macOS app cannot touch that path; this
            # method runs the file write inside the unsandboxed
            # helper process (LaunchAgent). Wraps the same
            # `permissions_diagnose.install_claude_hook` function
            # the CLI subcommand calls, with identical
            # idempotency / auto-heal semantics.
            #
            # The helper supplies its OWN argv[0] as helper_path —
            # the app must NOT pass arbitrary paths. This protects
            # against a malicious socket peer rerouting the hook
            # command at a third-party Python script. Per-session
            # auth still applies; only authenticated app peers
            # reach this method.
            try:
                from permissions_diagnose import install_claude_hook  # type: ignore
            except ImportError as exc:  # pragma: no cover — module always present
                raise _RequestError(
                    "internal_error",
                    f"permissions_diagnose import failed: {exc}",
                ) from exc
            helper_argv0 = self._get_helper_argv0()
            if helper_argv0 is None:
                raise _RequestError(
                    "not_implemented",
                    "helper did not record its own argv[0] — install_claude_hook unavailable",
                )
            try:
                result = install_claude_hook(helper_path=Path(helper_argv0))
            except ValueError as exc:
                # Malformed / non-object settings.json — surface so
                # the app can show a "fix file by hand" banner.
                raise _RequestError("settings_malformed", str(exc)) from exc
            return dict(result)

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


class _StreamHandoff:
    """Sentinel returned by `_handle_method` for `subscribe_events`.

    Carries the request id (so the initial ack frame echoes it), the
    snapshot payload to send as that ack, and the live `Subscription`
    the streaming loop drains. The sentinel never crosses module
    boundaries — `_serve_connection` consumes it and switches to the
    streaming loop.
    """

    __slots__ = ("req_id", "initial_payload", "subscription")

    def __init__(
        self,
        *,
        req_id: Any,
        initial_payload: dict[str, Any],
        subscription: Subscription,
    ) -> None:
        self.req_id = req_id
        self.initial_payload = initial_payload
        self.subscription = subscription


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
