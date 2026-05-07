"""Tests for the local approval registry (Phase 3 Iter 2B).

Coverage:
  - register_session generates a fresh capability token
  - update_session_pid accepts post-spawn pid
  - authenticate_hook: capability mismatch / session-not-found / descent ok / descent reject
  - create_pending: respects per-session cap, emits approval_requested event
  - decide: approve / reject paths, wakes wait_for_decision
  - decide: rejects already-resolved / expired / wrong-session-hint
  - wait_for_decision: blocks then returns; respects timeout (returns timed_out flag)
  - wall-clock TTL auto-expires pending in list / wait
  - unregister_session cancels pending approvals & invalidates token
  - tool_metadata is sanitised (long strings truncated, illegal types dropped)
  - PID descent walking: matches root, exhausts at limit, handles None resolver

These tests use stubbed peer-pid + ppid resolvers so we don't depend
on actually spawning Claude in CI.
"""
from __future__ import annotations

import sys
import threading
import time
from pathlib import Path

import pytest

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

from local_approvals import (  # noqa: E402
    ApprovalError,
    ApprovalRegistry,
    DEFAULT_APPROVAL_TIMEOUT_S,
    MAX_PENDING_PER_SESSION,
)


# ── helpers ────────────────────────────────────────────────


def _registry_with_descent(
    *, ppid_chain: dict[int, int] | None = None,
    allow_descent_skip: bool = True,
) -> ApprovalRegistry:
    """Build a registry whose ppid resolver follows a deterministic
    chain. Disables the peer_pid_resolver since unit tests pass
    `peer_pid` directly.

    Defaults to `allow_descent_skip=True` because most unit tests
    here exercise the token + cancel + decide paths without setting
    a real Claude PID. Tests that specifically validate descent
    fail-closed behaviour pass `allow_descent_skip=False`.
    """
    events: list[dict] = []
    reg = ApprovalRegistry(
        on_event=events.append,
        allow_descent_skip=allow_descent_skip,
    )
    reg.peer_pid_resolver = None
    if ppid_chain is not None:
        reg.ppid_resolver = ppid_chain.get
    else:
        reg.ppid_resolver = lambda _pid: None
    reg._test_events = events  # type: ignore[attr-defined]  — handle for tests
    return reg


# ── register / update ──────────────────────────────────────


def test_register_session_generates_fresh_token():
    reg = _registry_with_descent()
    t1 = reg.register_session("S1", claude_pid=None)
    t2 = reg.register_session("S2", claude_pid=None)
    assert isinstance(t1, str) and len(t1) > 20
    assert isinstance(t2, str) and len(t2) > 20
    assert t1 != t2


def test_register_session_resession_invalidates_old_token():
    reg = _registry_with_descent()
    t1 = reg.register_session("S1", claude_pid=None)
    t2 = reg.register_session("S1", claude_pid=None)
    assert t1 != t2
    # Old token no longer authenticates.
    with pytest.raises(ApprovalError) as exc:
        reg.authenticate_hook("S1", t1)
    assert exc.value.code == ApprovalError.CAPABILITY_INVALID


def test_update_session_pid_sets_descent_root():
    reg = _registry_with_descent(ppid_chain={101: 100})
    token = reg.register_session("S1", claude_pid=None)
    reg.update_session_pid("S1", 100)
    # No raise → descent matched (101 → 100).
    reg.authenticate_hook("S1", token, peer_pid=101)


# ── authenticate_hook ─────────────────────────────────────


def test_authenticate_hook_unknown_session_raises():
    reg = _registry_with_descent()
    with pytest.raises(ApprovalError) as exc:
        reg.authenticate_hook("nope", "T")
    assert exc.value.code == ApprovalError.SESSION_NOT_FOUND


def test_authenticate_hook_capability_mismatch_raises():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    with pytest.raises(ApprovalError) as exc:
        reg.authenticate_hook("S1", "wrong-token")
    assert exc.value.code == ApprovalError.CAPABILITY_INVALID


def test_authenticate_hook_descent_ok_when_root_matches():
    reg = _registry_with_descent(ppid_chain={50: 100})
    token = reg.register_session("S1", claude_pid=100)
    reg.authenticate_hook("S1", token, peer_pid=50)


def test_authenticate_hook_descent_rejects_unrelated_pid():
    reg = _registry_with_descent(ppid_chain={50: 1})  # init parent
    token = reg.register_session("S1", claude_pid=100)
    with pytest.raises(ApprovalError) as exc:
        reg.authenticate_hook("S1", token, peer_pid=50)
    assert exc.value.code == ApprovalError.CAPABILITY_INVALID


def test_authenticate_hook_descent_skipped_when_test_opt_in_and_no_root_pid():
    """When the registry was constructed with allow_descent_skip=True
    (test mode) AND claude_pid wasn't recorded, the registry permits
    a token-only authentication. This path is intentionally test-only;
    the fail-closed equivalent is covered by the next test.
    """
    reg = _registry_with_descent(allow_descent_skip=True)
    token = reg.register_session("S1", claude_pid=None)
    reg.authenticate_hook("S1", token, peer_pid=99999)


def test_authenticate_hook_descent_fail_closed_when_no_root_pid_in_strict_mode():
    """Production posture: registry constructed without
    `allow_descent_skip` MUST refuse a hook whose session lacks a
    recorded claude_pid. The dual-defense (token + descent) is
    explicitly NOT degradable to token-only by accident.
    """
    reg = _registry_with_descent(allow_descent_skip=False)
    token = reg.register_session("S1", claude_pid=None)
    with pytest.raises(ApprovalError) as exc:
        reg.authenticate_hook("S1", token, peer_pid=99999)
    assert exc.value.code == ApprovalError.CAPABILITY_INVALID
    assert "claude_pid" in exc.value.message


def test_authenticate_hook_descent_fail_closed_when_peer_pid_unresolvable():
    """Strict-mode: if claude_pid IS recorded but the peer pid can't
    be resolved (no resolver, OS error, returned None), the registry
    must reject. Otherwise an attacker who has the token (e.g. read
    it from /proc/<pid>/environ on a sibling process) could bypass
    the descent check by causing the resolver to fail.
    """
    reg = _registry_with_descent(allow_descent_skip=False)
    token = reg.register_session("S1", claude_pid=100)
    # No peer_pid passed AND no peer_pid_resolver wired (the helper
    # disabled it in the fixture). Strict mode must refuse.
    with pytest.raises(ApprovalError) as exc:
        reg.authenticate_hook("S1", token)
    assert exc.value.code == ApprovalError.CAPABILITY_INVALID
    assert "peer pid" in exc.value.message


def test_descent_walk_bounded():
    """Cycle in the ppid chain must not loop forever."""
    chain = {2: 3, 3: 2}  # cyclic
    reg = _registry_with_descent(ppid_chain=chain)
    token = reg.register_session("S1", claude_pid=100)
    with pytest.raises(ApprovalError):
        reg.authenticate_hook("S1", token, peer_pid=2)


# ── create_pending / list_pending ─────────────────────────


def test_create_pending_returns_id_and_emits_event():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    aid = reg.create_pending(
        "S1",
        kind="PermissionRequest",
        title="Read",
        summary="Read /etc/hosts",
        tool_metadata={"path": "/etc/hosts"},
    )
    assert isinstance(aid, str) and len(aid) > 0
    pending = reg.list_pending("S1")
    assert len(pending) == 1
    assert pending[0]["approval_id"] == aid
    assert pending[0]["status"] == "pending"
    assert pending[0]["title"] == "Read"
    # Event emitted.
    events = reg._test_events  # type: ignore[attr-defined]
    assert any(e.get("event") == "approval_requested" for e in events)


def test_create_pending_unknown_session_raises():
    reg = _registry_with_descent()
    with pytest.raises(ApprovalError) as exc:
        reg.create_pending("nope", kind="K", title="T", summary="S", tool_metadata={})
    assert exc.value.code == ApprovalError.SESSION_NOT_FOUND


def test_create_pending_respects_session_cap():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    for i in range(MAX_PENDING_PER_SESSION):
        reg.create_pending(
            "S1", kind="K", title=f"T{i}", summary="", tool_metadata={},
        )
    with pytest.raises(ApprovalError) as exc:
        reg.create_pending("S1", kind="K", title="overflow", summary="", tool_metadata={})
    assert exc.value.code == ApprovalError.APPROVAL_LIMIT


def test_metadata_sanitisation_caps_lengths():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    huge = "x" * 5000
    reg.create_pending(
        "S1",
        kind="K",
        title="t",
        summary="s",
        tool_metadata={"big": huge, "ok": "small", "x" * 500: "ignored"},
    )
    pending = reg.list_pending("S1")[0]
    assert pending["tool_metadata"]["big"] != huge  # truncated
    assert pending["tool_metadata"]["ok"] == "small"
    # Long key was dropped.
    assert "x" * 500 not in pending["tool_metadata"]


# ── decide ────────────────────────────────────────────────


def test_decide_approve_resolves_to_approved():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    aid = reg.create_pending("S1", kind="K", title="t", summary="s", tool_metadata={})
    out = reg.decide(aid, "approve", session_id_hint="S1")
    assert out["status"] == "approved"
    assert out["decision"] == "approved"


def test_decide_reject_resolves_to_rejected():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    aid = reg.create_pending("S1", kind="K", title="t", summary="s", tool_metadata={})
    out = reg.decide(aid, "reject", session_id_hint="S1")
    assert out["status"] == "rejected"


def test_decide_unknown_id_raises():
    reg = _registry_with_descent()
    with pytest.raises(ApprovalError) as exc:
        reg.decide("nope-id", "approve")
    assert exc.value.code == ApprovalError.APPROVAL_NOT_FOUND


def test_decide_double_resolve_raises_already_resolved():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    aid = reg.create_pending("S1", kind="K", title="t", summary="s", tool_metadata={})
    reg.decide(aid, "approve", session_id_hint="S1")
    with pytest.raises(ApprovalError) as exc:
        reg.decide(aid, "approve", session_id_hint="S1")
    assert exc.value.code == ApprovalError.APPROVAL_ALREADY_RESOLVED


def test_decide_wrong_session_hint_raises_not_allowed():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    aid = reg.create_pending("S1", kind="K", title="t", summary="s", tool_metadata={})
    with pytest.raises(ApprovalError) as exc:
        reg.decide(aid, "approve", session_id_hint="other")
    assert exc.value.code == ApprovalError.APPROVAL_NOT_ALLOWED


def test_decide_unknown_decision_raises():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    aid = reg.create_pending("S1", kind="K", title="t", summary="s", tool_metadata={})
    with pytest.raises(ApprovalError):
        reg.decide(aid, "maybe-later", session_id_hint="S1")


# ── wait_for_decision ─────────────────────────────────────


def test_wait_for_decision_returns_immediately_when_already_resolved():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    aid = reg.create_pending("S1", kind="K", title="t", summary="s", tool_metadata={})
    reg.decide(aid, "approve", session_id_hint="S1")
    out = reg.wait_for_decision("S1", aid, timeout_s=1.0)
    assert out["status"] == "approved"


def test_wait_for_decision_blocks_until_decide():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    aid = reg.create_pending("S1", kind="K", title="t", summary="s", tool_metadata={})
    result_holder: list[dict] = []
    started = threading.Event()

    def waiter():
        started.set()
        out = reg.wait_for_decision("S1", aid, timeout_s=5.0)
        result_holder.append(out)

    t = threading.Thread(target=waiter, daemon=True)
    t.start()
    started.wait(timeout=1.0)
    # Sleep long enough that the waiter is parked in cond.wait
    # without being so slow it stretches the suite.
    time.sleep(0.05)
    reg.decide(aid, "approve", session_id_hint="S1")
    t.join(timeout=2.0)
    assert not t.is_alive()
    assert result_holder
    assert result_holder[0]["status"] == "approved"


def test_wait_for_decision_returns_timed_out_flag_after_timeout():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    aid = reg.create_pending("S1", kind="K", title="t", summary="s", tool_metadata={})
    out = reg.wait_for_decision("S1", aid, timeout_s=0.1)
    assert out.get("timed_out") is True
    assert out["status"] == "pending"


def test_wait_for_decision_unknown_id_raises():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    with pytest.raises(ApprovalError):
        reg.wait_for_decision("S1", "nope", timeout_s=0.1)


# ── TTL / expiry ───────────────────────────────────────────


def test_pending_auto_expires_via_list_pending():
    """A short TTL elapses → list_pending sweeps the row."""
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    reg.create_pending(
        "S1", kind="K", title="t", summary="s", tool_metadata={}, timeout_s=0.05,
    )
    assert reg.list_pending("S1")  # still pending
    time.sleep(0.1)
    assert reg.list_pending("S1") == []  # swept


def test_decide_after_expiry_raises_expired():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    aid = reg.create_pending(
        "S1", kind="K", title="t", summary="s", tool_metadata={}, timeout_s=0.05,
    )
    time.sleep(0.1)
    # Sweep first so expiry path is exercised.
    reg.list_pending("S1")
    with pytest.raises(ApprovalError) as exc:
        reg.decide(aid, "approve", session_id_hint="S1")
    assert exc.value.code == ApprovalError.APPROVAL_EXPIRED


# ── unregister cancels pending ─────────────────────────────


def test_unregister_session_cancels_pending_and_wakes_waiter():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    aid = reg.create_pending("S1", kind="K", title="t", summary="s", tool_metadata={})
    result_holder: list[dict] = []

    def waiter():
        out = reg.wait_for_decision("S1", aid, timeout_s=5.0)
        result_holder.append(out)

    t = threading.Thread(target=waiter, daemon=True)
    t.start()
    time.sleep(0.05)
    reg.unregister_session("S1")
    t.join(timeout=2.0)
    assert not t.is_alive()
    assert result_holder[0]["status"] == "cancelled"
    # And the session itself is gone.
    assert not reg.has_session("S1")


def test_unregister_then_decide_raises_not_found():
    reg = _registry_with_descent()
    reg.register_session("S1", claude_pid=None)
    aid = reg.create_pending("S1", kind="K", title="t", summary="s", tool_metadata={})
    reg.unregister_session("S1")
    with pytest.raises(ApprovalError) as exc:
        reg.decide(aid, "approve", session_id_hint="S1")
    assert exc.value.code == ApprovalError.APPROVAL_NOT_FOUND


# ── default timeout sanity ────────────────────────────────


def test_default_timeout_constant_is_positive():
    assert DEFAULT_APPROVAL_TIMEOUT_S > 0
