"""Tests for swarm.py — S1 (v1.22 P0 Swarm View)."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import swarm  # noqa: E402


# ── git fixtures ────────────────────────────────────────────


def _git(cwd: Path, *args: str) -> None:
    subprocess.run(
        ["git", *args],
        cwd=str(cwd), check=True,
        capture_output=True, text=True,
        env={
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
            "PATH": __import__("os").environ.get("PATH", ""),
            "HOME": str(cwd),
        },
    )


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    r = tmp_path / "proj"
    r.mkdir()
    _git(r, "init", "-q", "-b", "main")
    (r / "f.txt").write_text("x")
    _git(r, "add", ".")
    _git(r, "commit", "-qm", "init")
    return r


# ── resolve_worktree ────────────────────────────────────────


def test_resolve_none_for_empty_and_missing(tmp_path: Path):
    assert swarm.resolve_worktree("") is None
    assert swarm.resolve_worktree(str(tmp_path / "nope")) is None


def test_resolve_none_for_plain_dir(tmp_path: Path):
    d = tmp_path / "plain"
    d.mkdir()
    assert swarm.resolve_worktree(str(d)) is None


def test_resolve_basic_repo(repo: Path):
    wt = swarm.resolve_worktree(str(repo))
    assert wt is not None
    assert Path(wt.main_repo).resolve() == repo.resolve()
    assert wt.branch == "main"
    assert wt.is_linked_worktree is False


def test_resolve_detached_head(repo: Path):
    sha = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=str(repo),
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    _git(repo, "checkout", "-q", sha)
    wt = swarm.resolve_worktree(str(repo))
    assert wt is not None
    assert wt.branch == "(detached)"


def test_linked_worktrees_group_to_same_main_repo(repo: Path, tmp_path: Path):
    """R1-A1: every linked worktree of one repo must group into ONE
    swarm (same main_repo), with the branch as the per-agent axis."""
    wt_dir = tmp_path / "wt-feature"
    _git(repo, "worktree", "add", "-q", "-b", "feature", str(wt_dir))

    main = swarm.resolve_worktree(str(repo))
    linked = swarm.resolve_worktree(str(wt_dir))
    assert main is not None and linked is not None
    # Same canonical repo → same grouping component.
    assert Path(main.main_repo).resolve() == Path(linked.main_repo).resolve()
    # Different branch → different per-agent key.
    assert main.branch == "main"
    assert linked.branch == "feature"
    assert linked.is_linked_worktree is True


# ── compute_swarm_key / display_handle ──────────────────────


def test_swarm_key_deterministic_and_account_scoped():
    a = swarm.compute_swarm_key("/r", "main", "secretA")
    b = swarm.compute_swarm_key("/r", "main", "secretA")
    assert a == b and len(a) == 64  # stable, sha256 hex

    # R2-1: SAME account secret on a "different machine" → SAME key
    # (cross-device grouping). Different account → different key.
    assert swarm.compute_swarm_key("/r", "main", "secretB") != a
    # branch is part of the key (per-agent dimension)
    assert swarm.compute_swarm_key("/r", "dev", "secretA") != a
    # NUL-joining prevents ("a","bc") colliding with ("ab","c")
    assert (swarm.compute_swarm_key("a", "bc", "s")
            != swarm.compute_swarm_key("ab", "c", "s"))


def test_swarm_key_empty_secret_is_empty():
    assert swarm.compute_swarm_key("/r", "main", "") == ""


def test_display_handle_is_opaque():
    k = swarm.compute_swarm_key("/secret/client-x", "embargo-cve", "s")
    h = swarm.display_handle(k)
    assert h == f"swarm-{k[:6]}"
    # leaks nothing about the path/branch
    assert "client-x" not in h and "embargo" not in h


# ── account-envelope label crypto (v1.22.1-ready) ───────────


def test_label_encrypt_roundtrip():
    s = "account-secret-xyz"
    for plain in ["my-repo", "клиент", "a/b/c-codename", ""]:
        env = swarm.encrypt_label(plain, s)
        assert env.startswith("v1.")
        if plain:
            assert plain not in env  # ciphertext, not plaintext
        assert swarm.decrypt_label(env, s) == plain


def test_label_decrypt_rejects_tamper_and_wrong_key():
    env = swarm.encrypt_label("repo", "secretA")
    assert swarm.decrypt_label(env, "secretB") is None        # wrong key
    assert swarm.decrypt_label(env[:-2] + "AA", "secretA") is None  # tampered
    assert swarm.decrypt_label("garbage", "secretA") is None  # bad format
    assert swarm.decrypt_label(env, "") is None               # no secret


def test_encrypt_label_requires_secret():
    with pytest.raises(ValueError):
        swarm.encrypt_label("x", "")


# ── SwarmStore ──────────────────────────────────────────────


def _store(tmp_path: Path, clock):
    p = tmp_path / "swarm_state.json"
    return swarm.SwarmStore(path=p, now=clock), p


def test_store_record_and_rollup(tmp_path: Path):
    t = {"v": 1000.0}
    st, _ = _store(tmp_path, lambda: t["v"])
    st.record_activity("k1", handle="swarm-k1", branch="main",
                        provider="claude", session_id="s1",
                        status="awaiting-approval")
    st.record_activity("k1", handle="swarm-k1", branch="main",
                        provider="aider", session_id="s2", status="running")
    roll = st.rollup()
    assert len(roll) == 1
    r = roll[0]
    assert r["swarm_key"] == "k1"
    assert r["agents"] == 2
    assert r["blocked"] == 1
    assert sorted(r["providers"]) == ["aider", "claude"]


def test_store_prunes_stale_sessions_and_swarms(tmp_path: Path):
    t = {"v": 0.0}
    st, _ = _store(tmp_path, lambda: t["v"])
    st.record_activity("old", handle="h", branch="b",
                        provider="claude", session_id="s", status="running")
    t["v"] = swarm._ACTIVITY_TTL_S + 10  # everything ages out
    assert st.rollup() == []


def test_store_soft_fails_on_corrupt_file(tmp_path: Path):
    st, p = _store(tmp_path, lambda: 1.0)
    p.write_text("{ not json")
    # must not raise — corrupt state can never break the approval hook
    assert st.rollup() == []
    st.record_activity("k", handle="h", branch="b",
                       provider="claude", session_id="s")
    assert any(r["swarm_key"] == "k" for r in st.rollup())


def test_store_file_is_0600(tmp_path: Path):
    st, p = _store(tmp_path, lambda: 1.0)
    st.record_activity("k", handle="h", branch="b",
                       provider="claude", session_id="s")
    assert p.exists()
    assert (p.stat().st_mode & 0o777) == 0o600
    # and it's valid JSON
    json.loads(p.read_text())


def test_store_bounds_swarm_count(tmp_path: Path):
    t = {"v": 1.0}
    st, _ = _store(tmp_path, lambda: t["v"])
    for i in range(swarm._MAX_SWARMS + 20):
        t["v"] += 1.0  # distinct last_seen so prune order is deterministic
        st.record_activity(f"k{i}", handle="h", branch="b",
                           provider="claude", session_id=f"s{i}")
    assert len(st.rollup()) <= swarm._MAX_SWARMS
