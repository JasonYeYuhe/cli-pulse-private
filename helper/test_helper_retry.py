"""Tests for ingest_commits retry behavior in cli_pulse_helper."""
from __future__ import annotations

import unittest
from unittest.mock import patch

import cli_pulse_helper


def _fake_config() -> cli_pulse_helper.HelperConfig:
    """Minimal HelperConfig for retry tests — only device_id / helper_secret
    matter for the RPC auth path (v0.18 device-auth signature)."""
    return cli_pulse_helper.HelperConfig(
        device_id="dev-0000",
        user_id="usr-0000",
        device_name="test",
        helper_version="0.0.0",
        helper_secret="test-secret",
    )


class _FakeSleep:
    """Records sleep durations instead of actually sleeping."""
    def __init__(self) -> None:
        self.calls: list[float] = []

    def __call__(self, seconds: float) -> None:
        self.calls.append(seconds)


class IngestCommitsRetryTests(unittest.TestCase):

    def test_single_batch_success_on_first_attempt(self):
        fake_sleep = _FakeSleep()
        calls: list[dict] = []

        def fake_rpc(fn_name, params):
            assert fn_name == "ingest_commits"
            calls.append(params)
            return None

        config = _fake_config()
        with patch.object(cli_pulse_helper, "supabase_rpc", side_effect=fake_rpc):
            cli_pulse_helper._ingest_commits_with_retry(
                config,
                [{"id": "c1"}, {"id": "c2"}],
                batch_size=10,
                sleep_fn=fake_sleep,
            )
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["p_commits"], [{"id": "c1"}, {"id": "c2"}])
        # v0.18: device auth params must be threaded through on every call
        self.assertEqual(calls[0]["p_device_id"], "dev-0000")
        self.assertEqual(calls[0]["p_helper_secret"], "test-secret")
        self.assertEqual(fake_sleep.calls, [])

    def test_sharding_into_multiple_batches(self):
        fake_sleep = _FakeSleep()
        calls: list[list[dict]] = []

        def fake_rpc(fn_name, params):
            calls.append(params["p_commits"])
            return None

        commits = [{"id": f"c{i}"} for i in range(7)]
        with patch.object(cli_pulse_helper, "supabase_rpc", side_effect=fake_rpc):
            cli_pulse_helper._ingest_commits_with_retry(
                _fake_config(), commits, batch_size=3, sleep_fn=fake_sleep,
            )
        self.assertEqual(len(calls), 3)
        self.assertEqual([len(c) for c in calls], [3, 3, 1])

    def test_retries_then_succeeds(self):
        fake_sleep = _FakeSleep()
        attempts = {"n": 0}

        def flaky_rpc(fn_name, params):
            attempts["n"] += 1
            if attempts["n"] < 3:
                raise cli_pulse_helper.SyncError("HTTP 503")
            return None

        with patch.object(cli_pulse_helper, "supabase_rpc", side_effect=flaky_rpc):
            cli_pulse_helper._ingest_commits_with_retry(
                _fake_config(),
                [{"id": "c1"}],
                batch_size=10,
                backoffs=(0.1, 0.2, 0.4),
                sleep_fn=fake_sleep,
            )
        self.assertEqual(attempts["n"], 3)
        self.assertEqual(fake_sleep.calls, [0.1, 0.2])

    def test_exhausts_all_attempts_and_raises(self):
        fake_sleep = _FakeSleep()

        def always_fail(fn_name, params):
            raise cli_pulse_helper.SyncError("HTTP 500")

        with patch.object(cli_pulse_helper, "supabase_rpc", side_effect=always_fail):
            with self.assertRaises(cli_pulse_helper.SyncError):
                cli_pulse_helper._ingest_commits_with_retry(
                    _fake_config(),
                    [{"id": "c1"}],
                    batch_size=10,
                    backoffs=(0.0, 0.0, 0.0),
                    sleep_fn=fake_sleep,
                )
        self.assertEqual(fake_sleep.calls, [0.0, 0.0, 0.0])

    def test_partial_batch_failure_stops_advancing(self):
        """If an intermediate batch exhausts retries, the helper raises so the
        caller skips the last_scanned_projects update."""
        fake_sleep = _FakeSleep()
        batches_seen: list[list[dict]] = []

        def second_batch_fails(fn_name, params):
            batches_seen.append(params["p_commits"])
            if len(batches_seen) >= 2:
                raise cli_pulse_helper.SyncError("HTTP 500")
            return None

        commits = [{"id": f"c{i}"} for i in range(6)]
        with patch.object(cli_pulse_helper, "supabase_rpc",
                          side_effect=second_batch_fails):
            with self.assertRaises(cli_pulse_helper.SyncError):
                cli_pulse_helper._ingest_commits_with_retry(
                    _fake_config(),
                    commits,
                    batch_size=3,
                    backoffs=(0.0, 0.0, 0.0),
                    sleep_fn=fake_sleep,
                )
        # First batch succeeded once (1 RPC), second batch tried 4 times
        # (1 initial + 3 retries) → 5 RPCs total.
        self.assertEqual(len(batches_seen), 5)


if __name__ == "__main__":
    unittest.main()
