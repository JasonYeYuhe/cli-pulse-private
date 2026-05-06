#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from system_collector import CollectedAlert, collect_alerts, collect_device_snapshot, collect_sessions, estimate_provider_quotas
from git_collector import GitCollector, project_paths_from_sessions
import user_secret as _user_secret_module

logger = logging.getLogger("cli_pulse.helper")

# Exponential backoff for ingest_commits transient failures, in seconds.
# Values tuned to give a ~13s worst-case retry window before giving up
# without dragging out the daemon's main loop.
INGEST_RETRY_BACKOFFS = (1.0, 3.0, 9.0)


CONFIG_PATH = Path.home() / ".cli-pulse-helper.json"
SUPPORTED_PROVIDERS = {
    "Codex", "Gemini", "Claude", "Cursor", "OpenCode", "Droid", "Antigravity",
    "Copilot", "z.ai", "MiniMax", "Augment", "JetBrains AI", "Kimi K2",
    "Kimi", "Amp", "Synthetic", "Warp", "Kilo", "Ollama", "OpenRouter",
    "Alibaba", "Kiro", "Vertex AI", "Perplexity", "Volcano Engine",
}

SUPABASE_URL = os.environ.get("CLI_PULSE_SUPABASE_URL", "https://gkjwsxotmwrgqsvfijzs.supabase.co")
SUPABASE_ANON_KEY = os.environ.get("CLI_PULSE_SUPABASE_ANON_KEY", "")


@dataclass
class HelperConfig:
    device_id: str
    user_id: str
    device_name: str
    helper_version: str
    helper_secret: str = ""
    # Phase 3 Iter 1: gate for the local UDS control surface. Independent
    # from `remote_control_enabled` (which lives server-side and gates
    # Supabase RPCs) — different threat model, different consent
    # decision. Defaults to False so an existing config without this
    # key loads as opted-out.
    local_control_enabled: bool = False


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_config() -> HelperConfig:
    if not CONFIG_PATH.exists():
        raise ConfigError("helper is not paired yet — run 'pair' first")
    try:
        data = json.loads(CONFIG_PATH.read_text())
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ConfigError(f"corrupted config at {CONFIG_PATH}: {exc}") from exc
    # Detect legacy v0 config (has 'server' or missing 'helper_secret')
    if "server" in data or "helper_secret" not in data:
        raise ConfigError(
            f"legacy config detected at {CONFIG_PATH} — please re-pair:\n"
            f"  rm {CONFIG_PATH}\n"
            f"  python3 cli_pulse_helper.py pair --pairing-code <CODE>"
        )
    # Accept only known fields
    known = {f.name for f in HelperConfig.__dataclass_fields__.values()}
    return HelperConfig(**{k: v for k, v in data.items() if k in known})


def save_config(config: HelperConfig) -> None:
    CONFIG_PATH.write_text(json.dumps(asdict(config), indent=2))
    CONFIG_PATH.chmod(0o600)


def set_local_control_enabled(enabled: bool) -> bool:
    """Flip the `local_control_enabled` gate in the on-disk helper
    config. Idempotent. Returns the post-update value so the caller
    can echo it back to the UDS client.

    The function reads + writes the live config file, so a daemon
    that's already running picks up the change at the start of the
    next mutation that goes through the executor (the UDS server
    hands the getter a closure that re-reads the file each call).
    """
    config = load_config()
    config.local_control_enabled = bool(enabled)
    save_config(config)
    return config.local_control_enabled


class ConfigError(Exception):
    """Fatal configuration error — daemon should exit."""
    pass

class SyncError(Exception):
    """Transient sync/network error — daemon should retry."""
    pass

def supabase_rpc(function_name: str, params: dict[str, Any]) -> Any:
    url = f"{SUPABASE_URL}/rest/v1/rpc/{function_name}"
    headers = {
        "Content-Type": "application/json",
        "apikey": SUPABASE_ANON_KEY,
        "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
    }
    if not SUPABASE_ANON_KEY:
        raise ConfigError("Supabase credentials not configured — check helper .env file")
    body = json.dumps(params).encode("utf-8")
    request = urllib.request.Request(url=url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8")
        raise SyncError(f"Supabase error {error.code}: {detail}") from error
    except urllib.error.URLError as error:
        raise SyncError(f"Network error: {error.reason}") from error
    except TimeoutError as error:
        raise SyncError("Request timed out — check your network connection") from error


def _ingest_commits_with_retry(config: "HelperConfig",
                               payloads: list[dict[str, Any]],
                               batch_size: int = 200,
                               backoffs: tuple[float, ...] = INGEST_RETRY_BACKOFFS,
                               sleep_fn: Any = time.sleep) -> None:
    """Push commit payloads to `ingest_commits`, retrying each batch with
    the configured backoff schedule.

    Since v0.18 (PROJECT_FIX_v1.9.6c) the RPC authenticates via device_id +
    helper_secret (same pattern as helper_sync), because the daemon only
    has the anon key — no user JWT means `auth.uid()` is NULL and the old
    1-arg signature always returned "Not authenticated".

    `backoffs` is the sleep schedule BEFORE each retry — so a tuple of
    length N means 1 initial attempt + N retries = N+1 total attempts.
    Default (1, 3, 9) therefore means: try, wait 1s, retry, wait 3s,
    retry, wait 9s, retry — up to 4 attempts per chunk.

    Raises the last SyncError if every attempt fails so the caller can
    avoid advancing `last_scanned_projects` and the batch gets
    re-picked-up on the next daemon cycle.

    `sleep_fn` is a hook to skip real sleep in tests.
    """
    total_attempts = len(backoffs) + 1
    for i in range(0, len(payloads), batch_size):
        chunk = payloads[i:i + batch_size]
        last_exc: SyncError | None = None
        for attempt_idx in range(total_attempts):
            try:
                supabase_rpc("ingest_commits", {
                    "p_device_id": config.device_id,
                    "p_helper_secret": config.helper_secret,
                    "p_commits": chunk,
                })
                last_exc = None
                break
            except SyncError as exc:
                last_exc = exc
                if attempt_idx < len(backoffs):
                    delay = backoffs[attempt_idx]
                    logger.warning(
                        "ingest_commits chunk %d-%d attempt %d/%d failed: %s (retry in %.1fs)",
                        i, i + len(chunk), attempt_idx + 1, total_attempts, exc, delay,
                    )
                    sleep_fn(delay)
                else:
                    logger.error(
                        "ingest_commits chunk %d-%d attempt %d/%d failed: %s (giving up)",
                        i, i + len(chunk), attempt_idx + 1, total_attempts, exc,
                    )
        if last_exc is not None:
            raise last_exc


def _infer_source_kind(alert: CollectedAlert) -> str:
    if alert.related_session_id:
        return "session"
    if alert.related_provider:
        return "provider"
    if alert.related_project_id:
        return "project"
    return "device"


def pair(args: argparse.Namespace) -> None:
    device_name = args.device_name or "CLI Pulse Helper"
    response = supabase_rpc("register_helper", {
        "p_pairing_code": args.pairing_code,
        "p_device_name": device_name,
        "p_device_type": args.device_type,
        "p_system": args.system,
        "p_helper_version": args.helper_version,
    })
    if isinstance(response, dict) and response.get("error"):
        raise SyncError(
            response.get("message") or f"pairing rejected: {response['error']}"
        )
    config = HelperConfig(
        device_id=response["device_id"],
        user_id=response["user_id"],
        device_name=device_name,
        helper_version=args.helper_version,
        helper_secret=response.get("helper_secret", ""),
    )
    save_config(config)
    print(f"paired {config.device_name} as {config.device_id}")


def heartbeat(_: argparse.Namespace) -> None:
    config = load_config()
    snapshot = collect_device_snapshot()
    sessions = collect_sessions()
    supabase_rpc("helper_heartbeat", {
        "p_device_id": config.device_id,
        "p_helper_secret": config.helper_secret,
        "p_cpu_usage": snapshot.cpu_usage,
        "p_memory_usage": snapshot.memory_usage,
        "p_active_session_count": len(sessions),
    })
    logger.debug("heartbeat sent")


def sync(_: argparse.Namespace) -> None:
    config = load_config()
    collected_sessions = collect_sessions()
    sessions = [
        {
            "id": item.session_id,
            "name": item.name,
            "provider": item.provider,
            "project": item.project,
            "project_hash": item.project_hash,
            "status": item.status,
            "total_usage": item.total_usage,
            "exact_cost": item.exact_cost,
            "requests": item.requests,
            "error_count": item.error_count,
            "collection_confidence": item.collection_confidence,
            "started_at": item.started_at,
            "last_active_at": item.last_active_at,
        }
        for item in collected_sessions
        if item.provider in SUPPORTED_PROVIDERS
    ]
    device_snapshot = collect_device_snapshot()
    alerts = [
        {
            "id": item.alert_id,
            "type": item.type,
            "severity": item.severity,
            "title": item.title,
            "message": item.message,
            "created_at": item.created_at,
            "related_project_id": item.related_project_id,
            "related_project_name": item.related_project_name,
            "related_session_id": item.related_session_id,
            "related_session_name": item.related_session_name,
            "related_provider": item.related_provider,
            "related_device_name": item.related_device_name or config.device_name,
            "source_kind": _infer_source_kind(item),
            "source_id": item.related_session_id or item.related_project_id,
            "grouping_key": f"{item.type}:{item.related_provider or 'system'}",
            "suppression_key": f"{item.type}:{item.related_session_id or 'global'}",
        }
        for item in collect_alerts(collected_sessions, device_snapshot)
    ]

    provider_quotas = estimate_provider_quotas(collected_sessions)
    response = supabase_rpc("helper_sync", {
        "p_device_id": config.device_id,
        "p_helper_secret": config.helper_secret,
        "p_sessions": sessions,
        "p_alerts": alerts,
        "p_provider_remaining": {p: q["remaining"] for p, q in provider_quotas.items()},
        "p_provider_tiers": provider_quotas,
    })
    logger.info("synced %s sessions", response.get("sessions_synced", 0))


def _fetch_track_git_activity(config: HelperConfig) -> bool:
    """Read user_settings.track_git_activity for the helper's owner.

    Falls back to False on any error (no auth token, network failure, missing row)
    so privacy default holds. Helper has no user-bearing token; it queries via
    a small RPC that returns the boolean by device id + helper secret.
    """
    # The helper authenticates to Supabase by device_id + helper_secret, not by
    # JWT, so it can't query /rest/v1/user_settings directly under RLS.
    # We expose a SECURITY DEFINER RPC `get_track_git_activity(p_device_id, p_helper_secret)`
    # added in the same migration. If it's not present yet, return False.
    try:
        result = supabase_rpc("get_track_git_activity", {
            "p_device_id": config.device_id,
            "p_helper_secret": config.helper_secret,
        })
        return bool(result) if isinstance(result, bool) else False
    except SyncError:
        return False


def daemon(args: argparse.Namespace) -> None:
    """Run continuously: heartbeat + sync every interval seconds.

    Yield score: if CLI_PULSE_TRACK_GIT=1 in the environment (or the user's
    user_settings.track_git_activity is true once Stage 7 lands), runs a git
    log scan whenever the active project set changes or every 10 minutes,
    whichever comes first. Per Codex review: never every cycle.

    Remote Agent Sessions (iter 1): a `RemoteAgentManager` is constructed
    once at startup and `tick()`-ed every second from inside the inner
    sleep loop. This keeps the Sessions-Input UX snappy (a typed prompt
    reaches the spawned `claude` within ~1s of being enqueued) without
    stretching the slower heartbeat/sync cadence. The server-side
    `_remote_authenticate_helper_gated` already rejects helper RPCs when
    Remote Control is off, so calling tick() unconditionally is safe.
    """
    import signal

    interval = max(args.interval, 60)  # Match Swift helper minimum (60s)
    stopping = False

    # Yield score: source of truth is user_settings.track_git_activity on the server.
    # Re-checked every cycle so toggling the setting in the macOS app takes effect
    # within one heartbeat cycle. Env override CLI_PULSE_TRACK_GIT=1 forces on for
    # CI / dev / users who don't want to use the macOS UI.
    git_scanner: GitCollector | None = None
    last_scanned_projects: frozenset[str] = frozenset()
    last_scan_at: float = 0.0
    GIT_SCAN_BACKSTOP_SECONDS = 600  # 10 minutes
    env_force_git = os.environ.get("CLI_PULSE_TRACK_GIT") == "1"
    if env_force_git:
        logger.info("git activity tracking forced on via CLI_PULSE_TRACK_GIT=1")

    # Remote Agent Sessions manager. Lazily import so a Windows host (the
    # Tauri desktop track will eventually call this same module) doesn't
    # crash on `import pty` from the POSIX transport. POSIX transport is
    # the default; ConPtyTransport is a stub for the desktop track.
    #
    # Phase 3 Iter 1: a `LocalExecutor` is constructed alongside the
    # manager and shared with the UDS server below, so the daemon poll
    # loop and the local-app fast path serialize all mutations onto a
    # single writer thread. The executor stays alive for the daemon's
    # full lifetime; the `finally` block below shuts it down cleanly.
    remote_agent_manager = None
    local_executor = None
    local_uds_server = None
    local_auth_token: str | None = None
    local_event_broker = None
    local_approval_registry = None
    try:
        from local_approvals import ApprovalRegistry  # type: ignore
        from local_events import EventBroker  # type: ignore
        from local_executor import LocalExecutor  # type: ignore
        from local_session_server import default_socket_path  # type: ignore
        from remote_agent import RemoteAgentManager  # type: ignore
        config_for_manager = load_config()
        local_executor = LocalExecutor()
        # Phase 3 Iter 2B: broker + registry are constructed BEFORE
        # the manager so the manager can publish session_started /
        # output_delta on its own initiative. The registry's
        # `on_event` taps into the broker so approval lifecycle
        # events show up on subscribed streams without the manager
        # having to forward them by hand.
        local_event_broker = EventBroker()
        local_approval_registry = ApprovalRegistry(
            on_event=local_event_broker.publish,
        )
        remote_agent_manager = RemoteAgentManager(
            helper_config=config_for_manager,
            rpc_caller=supabase_rpc,
            executor=local_executor,
            event_broker=local_event_broker,
            approval_registry=local_approval_registry,
            local_helper_socket_path=str(default_socket_path()),
        )
        logger.info(
            "remote agent manager initialised (executor=on, broker=on, approvals=on)",
        )
    except ConfigError:
        # Helper not paired yet — daemon will likely fail in heartbeat
        # too. Don't synthesise a manager; the next iteration's
        # heartbeat will surface the same error with the user-facing
        # "run pair first" message.
        pass
    except NotImplementedError as exc:
        # Windows ConPTY path — daemon still runs, just without managed
        # sessions. The cli-pulse-desktop track owns this surface.
        logger.warning("remote agent manager unavailable on this platform: %s", exc)
    except Exception as exc:
        logger.warning("remote agent manager init failed: %s", exc)

    # Phase 3 Iter 1: local UDS control surface. Only stood up when we
    # have a manager — without it there's nothing for the local server
    # to dispatch to. Failures here are non-fatal: the daemon still
    # services Supabase-routed sessions even if the local socket can't
    # bind (e.g. another helper is already listening, missing app
    # group container).
    if remote_agent_manager is not None:
        try:
            from local_auth_token import rotate_token, token_path
            from local_session_server import LocalSessionServer, default_socket_path
            local_auth_token = rotate_token()

            def _get_token() -> str:
                # Re-read from disk on each request so a manual rotation
                # takes effect without restarting the daemon. The
                # in-process `local_auth_token` is the fallback.
                from local_auth_token import load_token
                return load_token() or local_auth_token or ""

            def _get_local_enabled() -> bool:
                try:
                    return bool(load_config().local_control_enabled)
                except ConfigError:
                    return False

            def _set_local_enabled(value: bool) -> None:
                set_local_control_enabled(bool(value))

            def _start_local(payload: dict[str, Any]) -> dict[str, Any]:
                return remote_agent_manager.local_start_claude_session(payload)

            def _list_local() -> list[dict[str, Any]]:
                return remote_agent_manager.local_list_sessions()

            def _stop_local(session_id: str) -> dict[str, Any]:
                return remote_agent_manager.local_stop_session(session_id)

            def _send_input_local(session_id: str, payload: str) -> dict[str, Any]:
                return remote_agent_manager.local_send_input(session_id, payload)

            def _list_detected_local() -> list[dict[str, Any]]:
                # iter 2A: surface same-Mac Claude processes the
                # PR #14 collector recognises. Read-only on the UDS
                # surface — the helper does NOT own these PTYs.
                # Wrapped lazily so an unrelated `system_collector`
                # import failure (e.g. missing ps on a stripped
                # container) doesn't break the whole UDS server.
                try:
                    from system_collector import collect_sessions
                    rows: list[dict[str, Any]] = []
                    for sess in collect_sessions():
                        if sess.provider != "Claude":
                            continue
                        rows.append({
                            "session_id": sess.session_id,
                            "provider": sess.provider,
                            "client_label": sess.name,
                            "project": sess.project,
                            "status": sess.status,
                            # Process-confirmed → controllable=False on
                            # the UDS surface; the server adds the flag
                            # before the reply leaves.
                            "started_at": sess.started_at,
                            "last_active_at": sess.last_active_at,
                            "collection_confidence": sess.collection_confidence,
                        })
                    return rows
                except Exception as exc:  # noqa: BLE001
                    logger.warning("detected-session collector failed: %s", exc)
                    return []

            local_uds_server = LocalSessionServer(
                socket_path=default_socket_path(),
                get_auth_token=_get_token,
                get_local_control_enabled=_get_local_enabled,
                set_local_control_enabled=_set_local_enabled,
                start_session=_start_local,
                list_sessions=_list_local,
                stop_session=_stop_local,
                send_input=_send_input_local,
                list_detected_sessions=_list_detected_local,
                # Iter 2B: broker drives subscribe_events; registry
                # backs approve_action / get_pending_approvals plus
                # the hook-side hook_create_approval / wait_decision
                # path.
                event_broker=local_event_broker,
                approval_registry=local_approval_registry,
            )
            local_uds_server.start()
            logger.info(
                "local UDS server started; auth token at %s", token_path()
            )
        except Exception as exc:
            logger.warning("local UDS server init failed: %s", exc)
            local_uds_server = None

    def _handle_shutdown(signum, _frame):
        nonlocal stopping
        sig_name = signal.Signals(signum).name
        logger.info("%s received — shutting down gracefully...", sig_name)
        stopping = True

    signal.signal(signal.SIGTERM, _handle_shutdown)
    signal.signal(signal.SIGHUP, _handle_shutdown)

    logger.info("CLI Pulse helper daemon started (interval=%ds). Press Ctrl+C to stop.", interval)
    try:
        while not stopping:
            try:
                heartbeat(args)
                sync(args)

                # Re-evaluate the user's track_git_activity opt-in each cycle so
                # toggling it in the macOS UI takes effect within one heartbeat.
                config = load_config()
                track_git = env_force_git or _fetch_track_git_activity(config)
                if track_git and git_scanner is None:
                    try:
                        git_scanner = GitCollector(secret=_user_secret_module.load_or_create_secret())
                        logger.info("git activity tracking enabled")
                    except Exception as exc:
                        logger.warning("failed to initialize git tracking: %s", exc)
                elif not track_git and git_scanner is not None:
                    logger.info("git activity tracking disabled by user")
                    git_scanner = None
                    last_scanned_projects = frozenset()
                    last_scan_at = 0.0

                if git_scanner is not None:
                    # Re-collect just for the project set; the sync above already
                    # handled the session payload, this is purely for git scanning.
                    sessions = collect_sessions()
                    paths = project_paths_from_sessions(sessions)
                    current_projects = frozenset(str(p) for p in paths)
                    now_ts = time.time()
                    set_changed = current_projects != last_scanned_projects
                    backstop_due = (now_ts - last_scan_at) >= GIT_SCAN_BACKSTOP_SECONDS
                    if paths and (set_changed or backstop_due):
                        commits = git_scanner.collect(paths)
                        ingest_ok = True
                        if commits:
                            # Server caps at 500/batch (see migrate_v0.14 P0-2).
                            # Shard at 200 to leave headroom for client/server skew.
                            payloads = [c.to_dict() for c in commits]
                            try:
                                _ingest_commits_with_retry(config, payloads, batch_size=200)
                                logger.info(
                                    "submitted %d commits across %d project(s)",
                                    len(commits), len(paths),
                                )
                            except SyncError as exc:
                                ingest_ok = False
                                logger.error(
                                    "commit submit failed after retries: %s "
                                    "(keeping project set unscanned so next cycle retries)",
                                    exc,
                                )
                        # Only advance the cursor when the submit succeeded.
                        # Otherwise the current project set stays "unscanned" so
                        # the commits get picked up again next cycle instead of
                        # being silently dropped.
                        if ingest_ok:
                            last_scanned_projects = current_projects
                            last_scan_at = now_ts
            except ConfigError:
                raise  # Fatal config errors should stop the daemon
            except (Exception, SyncError) as exc:
                # Transient network/API errors — log and retry next cycle
                logger.error("daemon cycle failed: %s", exc)
            # Sleep in small increments so SIGTERM is handled promptly.
            # Remote agent manager ticks once per second so typed prompts
            # reach the spawned provider CLI within ~1s of being enqueued.
            for _ in range(interval):
                if stopping:
                    break
                if remote_agent_manager is not None:
                    try:
                        remote_agent_manager.tick()
                    except Exception as exc:
                        logger.warning("remote agent tick failed: %s", exc)
                time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        # Phase 3 Iter 1 ordering: stop the UDS server first so no new
        # local jobs land on the executor while we're draining; then
        # let the manager terminate child PTYs (which itself goes
        # through the executor); then shut the executor down. Each
        # step is best-effort — we want the daemon's exit to be clean
        # even if any one of them throws.
        if local_uds_server is not None:
            try:
                local_uds_server.stop()
            except Exception as exc:
                logger.warning("local UDS server stop failed: %s", exc)
        if remote_agent_manager is not None:
            try:
                remote_agent_manager.shutdown()
            except Exception as exc:
                logger.warning("remote agent shutdown failed: %s", exc)
        if local_executor is not None:
            try:
                local_executor.shutdown(wait=True, timeout=5.0)
            except Exception as exc:
                logger.warning("local executor shutdown failed: %s", exc)
        if local_event_broker is not None:
            try:
                local_event_broker.close()
            except Exception as exc:
                logger.warning("local event broker shutdown failed: %s", exc)
    logger.info("daemon stopped")


def run_demo(args: argparse.Namespace) -> None:
    for _ in range(args.cycles):
        heartbeat(args)
        sync(args)
        time.sleep(args.interval)


def inspect(_: argparse.Namespace) -> None:
    snapshot = collect_device_snapshot()
    sessions = collect_sessions()
    alerts = collect_alerts(sessions, snapshot)
    print(
        json.dumps(
            {
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "device": {"cpu_usage": snapshot.cpu_usage, "memory_usage": snapshot.memory_usage},
                "sessions": [item.__dict__ for item in sessions],
                "alerts": [item.__dict__ for item in alerts],
            },
            indent=2,
        )
    )


def _configure_logging() -> None:
    """Install a basicConfig once so helper + collector logs reach stderr.
    Idempotent — skipped if caller has already configured logging."""
    if logging.getLogger().handlers:
        return
    level_name = os.environ.get("CLI_PULSE_LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )


def main() -> None:
    _configure_logging()
    parser = argparse.ArgumentParser(description="CLI Pulse device helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    pair_parser = subparsers.add_parser("pair", help="pair this device with a CLI Pulse account")
    pair_parser.add_argument("--pairing-code", required=True)
    pair_parser.add_argument("--device-name")
    pair_parser.add_argument("--device-type", default="Mac")
    pair_parser.add_argument("--system", default="macOS")
    pair_parser.add_argument("--helper-version", default="0.1.0")
    pair_parser.set_defaults(func=pair)

    heartbeat_parser = subparsers.add_parser("heartbeat", help="send one heartbeat")
    heartbeat_parser.set_defaults(func=heartbeat)

    sync_parser = subparsers.add_parser("sync", help="sync sessions and alerts")
    sync_parser.set_defaults(func=sync)

    daemon_parser = subparsers.add_parser("daemon", help="run continuously syncing in the foreground")
    daemon_parser.add_argument("--interval", type=int, default=120, help="sync interval in seconds (default: 120)")
    daemon_parser.set_defaults(func=daemon)

    demo_parser = subparsers.add_parser("run-demo", help="emit heartbeats and syncs in a loop")
    demo_parser.add_argument("--cycles", type=int, default=3)
    demo_parser.add_argument("--interval", type=int, default=2)
    demo_parser.set_defaults(func=run_demo)

    inspect_parser = subparsers.add_parser("inspect", help="print the locally collected snapshot")
    inspect_parser.set_defaults(func=inspect)

    remote_hook_parser = subparsers.add_parser(
        "remote-approval-hook",
        help="provider PermissionRequest hook — bridge to remote app approval (Phase 1: Claude only)",
    )
    remote_hook_parser.add_argument("--provider", required=True, choices=("claude", "codex", "shell"))
    remote_hook_parser.add_argument("--timeout", type=float, default=10.0,
                                    help="max seconds to wait for a remote decision (default 10)")
    remote_hook_parser.add_argument("--poll-interval", type=float, default=1.0,
                                    help="seconds between poll attempts (default 1)")
    remote_hook_parser.add_argument("--allow-high-risk", action="store_true",
                                    help="allow high-risk requests to round-trip (default: fail closed)")
    remote_hook_parser.set_defaults(func=_remote_approval_hook_cmd)

    # Diagnostic / setup helpers for the Remote Approvals feature.
    # All three are READ-ONLY — they never mutate ~/.claude/settings.json
    # or any other user file. Hierarchical:
    #   remote-approvals status
    #   remote-approvals print-claude-hook-config
    #   remote-approvals diagnose-claude-permissions [--json]
    remote_parser = subparsers.add_parser(
        "remote-approvals",
        help="Remote Approvals diagnostics + setup helpers (read-only)",
    )
    remote_subparsers = remote_parser.add_subparsers(
        dest="remote_subcmd", required=True,
        title="remote-approvals subcommands",
    )

    ra_status_parser = remote_subparsers.add_parser(
        "status",
        help="print whether Remote Approvals is wired up on this Mac",
    )
    ra_status_parser.set_defaults(func=_remote_approvals_status_cmd)

    ra_print_parser = remote_subparsers.add_parser(
        "print-claude-hook-config",
        help="print the JSON snippet to paste into ~/.claude/settings.json",
    )
    ra_print_parser.add_argument(
        "--python", default=None,
        help="python3 interpreter to embed in the hook command (defaults to 'python3')",
    )
    ra_print_parser.set_defaults(func=_remote_approvals_print_hook_cmd)

    # Idempotent merge of the PermissionRequest hook into
    # ~/.claude/settings.json. Distinct from print-claude-hook-config
    # (which only echoes the snippet) — install actually mutates the
    # file. Preserves every other key the user has set, refuses to
    # overwrite malformed JSON.
    ra_install_parser = remote_subparsers.add_parser(
        "install-claude-hook",
        help="merge the CLI Pulse PermissionRequest hook into ~/.claude/settings.json (idempotent)",
    )
    ra_install_parser.add_argument(
        "--python", default=None,
        help="python3 interpreter to embed in the hook command (defaults to 'python3')",
    )
    ra_install_parser.add_argument(
        "--settings", default=None,
        help="override target settings file (default: ~/.claude/settings.json)",
    )
    ra_install_parser.set_defaults(func=_remote_approvals_install_hook_cmd)

    ra_diagnose_parser = remote_subparsers.add_parser(
        "diagnose-claude-permissions",
        help="diagnose Claude Code permission rules + hook wiring (read-only)",
    )
    ra_diagnose_parser.add_argument(
        "--json", action="store_true", help="emit a JSON report instead of human text",
    )
    ra_diagnose_parser.set_defaults(func=_remote_approvals_diagnose_cmd)

    args = parser.parse_args()
    args.func(args)


def _remote_approval_hook_cmd(args: argparse.Namespace) -> None:
    """Adapter from argparse → remote_hook.run_hook."""
    from remote_hook import HookConfig, run_hook
    config = HookConfig(
        poll_interval_s=args.poll_interval,
        timeout_s=args.timeout,
        ttl_seconds=max(int(args.timeout) + 30, 60),
        fail_closed_on_high_risk=not args.allow_high_risk,
    )
    run_hook(args.provider, config)


def _remote_approvals_status_cmd(_: argparse.Namespace) -> None:
    """Quick at-a-glance: is the helper paired, is Remote Control on,
    is the Claude hook wired? Read-only.
    """
    import permissions_diagnose

    print("CLI Pulse — Remote Approvals status")
    # Helper pairing
    try:
        config = load_config()
        print(f"  helper paired:           yes  (device_id={config.device_id})")
    except ConfigError as exc:
        print(f"  helper paired:           NO  ({exc})")
        config = None

    # Claude hook presence
    report = permissions_diagnose.diagnose()
    print(f"  Claude hook configured:  "
          f"{'yes' if report.has_permission_request_hook else 'NO'}")
    if report.has_pre_tool_use_hook and not report.has_permission_request_hook:
        print("                            (PreToolUse hook found, but CLI Pulse "
              "uses PermissionRequest)")

    # Server-side gate: this needs network. Skip if not paired.
    if config is None:
        print("  remote_control_enabled:  unknown (helper not paired)")
        return
    try:
        result = supabase_rpc("get_track_git_activity", {
            "p_device_id": config.device_id,
            "p_helper_secret": config.helper_secret,
        })
        # We don't have a dedicated get_remote_control_enabled RPC; the
        # gated auth helper simply returns null when off, which is what
        # we use here. Fall back to "unknown" rather than guess.
        _ = result  # reserved for future direct-flag RPC
        print("  remote_control_enabled:  unknown (no dedicated RPC; check the "
              "iOS / Mac Settings → Privacy toggle)")
    except SyncError as exc:
        print(f"  remote_control_enabled:  unknown (network error: {exc})")


def _remote_approvals_print_hook_cmd(args: argparse.Namespace) -> None:
    """Print a copy-pasteable JSON snippet for ~/.claude/settings.json.

    Uses absolute paths so the user can paste verbatim. Does NOT write
    anywhere — the user pastes the snippet themselves so they can review
    + merge with any existing hook config.
    """
    import permissions_diagnose

    helper_path = Path(__file__).resolve()
    snippet = permissions_diagnose.recommended_hook_config_snippet(
        helper_path=helper_path,
        python_path=args.python,
    )
    print(snippet)
    print()
    print("# Paste the `hooks.PermissionRequest` entry above into")
    print("# ~/.claude/settings.json. If that file already has a `hooks`")
    print("# section, MERGE rather than replace — keep your existing hooks.")
    print("# Restart Claude Code after saving so it picks up the change.")


def _remote_approvals_install_hook_cmd(args: argparse.Namespace) -> None:
    """Idempotently merge the CLI Pulse PermissionRequest hook into
    `~/.claude/settings.json`. Preserves every other key.

    Output the resulting status so the operator (or a calling script
    like the macOS app's Settings page) can tell which path was
    taken: `created` / `added` / `replaced` / `noop`.
    """
    import permissions_diagnose

    helper_path = Path(__file__).resolve()
    settings_path: Path | None = None
    if getattr(args, "settings", None):
        settings_path = Path(args.settings).expanduser().resolve()

    try:
        result = permissions_diagnose.install_claude_hook(
            helper_path=helper_path,
            settings_path=settings_path,
            python_path=getattr(args, "python", None),
        )
    except ValueError as exc:
        # Surfaces malformed-JSON / non-object-root cases with a
        # readable explanation rather than a Python traceback.
        print(f"install-claude-hook: error: {exc}", file=sys.stderr)
        sys.exit(2)

    print(f"settings_path: {result['settings_path']}")
    print(f"action:        {result['action']}")
    if result.get("previous_command") is not None and result["action"] != "noop":
        print(f"previous:      {result['previous_command']}")
    print(f"new_command:   {result['new_command']}")
    if result["action"] == "noop":
        print()
        print("# Hook already wired correctly. Nothing to do.")
    else:
        print()
        print("# Restart Claude Code so it picks up the new hook entry.")


def _remote_approvals_diagnose_cmd(args: argparse.Namespace) -> None:
    """Read-only Claude Code permission diagnosis.

    Surfaces:
      - settings files present + parse status across all 4 scopes
      - merged allow/ask/deny rule counts
      - findings (deny overriding allow, allow-too-narrow, hook missing,
        allow-only-in-local-scope, parse errors)

    Never mutates user files. Output to stdout; errors / parse warnings
    are visible inline via finding entries.
    """
    import permissions_diagnose

    report = permissions_diagnose.diagnose()
    if args.json:
        print(json.dumps(report.to_json(), indent=2))
    else:
        print(permissions_diagnose.render_text_report(report))


if __name__ == "__main__":
    main()
