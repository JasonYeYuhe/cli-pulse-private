from __future__ import annotations

import unittest

from machine_command_relay import MachineCommandRelay


class _FakeClock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t

    def advance(self, dt: float) -> None:
        self.t += dt


class _FakeRPC:
    """Records calls; returns a scripted result per RPC name (or raises)."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []
        self.results: dict[str, object] = {}
        self.raise_on: set[str] = set()

    def __call__(self, name: str, params: dict):
        self.calls.append((name, params))
        if name in self.raise_on:
            raise RuntimeError(f"{name} boom")
        return self.results.get(name, None)


def _fresh_report(remote_fan=True, remote_lpm=True, boost_active=False, rpm=None) -> dict:
    return {
        "remote_fan": remote_fan,
        "remote_lpm": remote_lpm,
        "boost_active": boost_active,
        "boost_target_rpm": rpm,
    }


class TestMachineCommandRelay(unittest.TestCase):
    def setUp(self):
        self.clock = _FakeClock()
        self.rpc = _FakeRPC()
        self.relay = MachineCommandRelay(
            self.rpc, "dev-1", "secret-1", clock=self.clock, control_fresh_s=15.0
        )

    # ── gating ────────────────────────────────────────────────────
    def test_should_not_pull_without_report(self):
        self.assertFalse(self.relay.should_pull())
        self.assertEqual(self.relay.pull_from_cloud(), 0)
        self.assertEqual(self.rpc.calls, [])  # never touched the cloud

    def test_should_not_pull_when_controls_off(self):
        self.relay.report_control_state(_fresh_report(remote_fan=False, remote_lpm=False))
        self.assertFalse(self.relay.should_pull())
        self.assertEqual(self.relay.pull_from_cloud(), 0)

    def test_stale_report_does_not_pull(self):
        self.relay.report_control_state(_fresh_report())
        self.clock.advance(16.0)  # past control_fresh_s
        self.assertFalse(self.relay.should_pull())
        self.assertEqual(self.relay.pull_from_cloud(), 0)

    # ── pull + drain ──────────────────────────────────────────────
    def test_pull_and_drain(self):
        self.relay.report_control_state(_fresh_report())
        self.rpc.results["remote_helper_pull_machine_commands"] = [
            {"id": "c1", "kind": "set_fan_target", "payload": {"rpm": 4200, "ttl_seconds": 900}},
            {"id": "c2", "kind": "revert_fan_auto", "payload": {}},
        ]
        n = self.relay.pull_from_cloud()
        self.assertEqual(n, 2)
        name, params = self.rpc.calls[-1]
        self.assertEqual(name, "remote_helper_pull_machine_commands")
        self.assertEqual(params["p_device_id"], "dev-1")
        self.assertEqual(params["p_helper_secret"], "secret-1")
        # app drains, queue clears
        drained = self.relay.drain_for_app()
        self.assertEqual([c["id"] for c in drained], ["c1", "c2"])
        self.assertEqual(self.relay.drain_for_app(), [])

    def test_pull_ignores_malformed_and_empty(self):
        self.relay.report_control_state(_fresh_report())
        self.rpc.results["remote_helper_pull_machine_commands"] = [
            {"kind": "set_fan_target"},  # no id → dropped
            "not-a-dict",
        ]
        self.assertEqual(self.relay.pull_from_cloud(), 0)
        self.assertEqual(self.relay.drain_for_app(), [])

    def test_pull_failsoft_on_rpc_error(self):
        self.relay.report_control_state(_fresh_report())
        self.rpc.raise_on.add("remote_helper_pull_machine_commands")
        self.assertEqual(self.relay.pull_from_cloud(), 0)  # no raise

    # ── complete ──────────────────────────────────────────────────
    def test_complete_forwards_with_result(self):
        out = self.relay.complete("c1", "done", {"applied": True})
        self.assertEqual(out, {"status": "ok"})
        name, params = self.rpc.calls[-1]
        self.assertEqual(name, "remote_helper_complete_machine_command")
        self.assertEqual(params["p_command_id"], "c1")
        self.assertEqual(params["p_status"], "done")
        self.assertEqual(params["p_result"], {"applied": True})

    def test_complete_omits_empty_result(self):
        self.relay.complete("c1", "failed")
        _name, params = self.rpc.calls[-1]
        self.assertNotIn("p_result", params)

    def test_complete_rejects_bad_status(self):
        with self.assertRaises(ValueError):
            self.relay.complete("c1", "delivered")
        self.assertEqual(self.rpc.calls, [])  # never forwarded

    # ── heartbeat fragment ────────────────────────────────────────
    def test_fragment_fresh(self):
        self.relay.report_control_state(
            _fresh_report(remote_fan=True, remote_lpm=False, boost_active=True, rpm=4200)
        )
        frag = self.relay.heartbeat_metrics_fragment()
        self.assertEqual(frag["machine_controls"], {"remote_fan": True, "remote_lpm": False})
        self.assertTrue(frag["fan_boost_active"])
        self.assertEqual(frag["fan_boost_target_rpm"], 4200)

    def test_fragment_stale_clears_controls(self):
        self.relay.report_control_state(_fresh_report(boost_active=True, rpm=4200))
        self.clock.advance(16.0)
        frag = self.relay.heartbeat_metrics_fragment()
        # actively clears so the phone hides controls (not preserve-last-known)
        self.assertEqual(frag["machine_controls"], {})
        self.assertFalse(frag["fan_boost_active"])
        self.assertNotIn("fan_boost_target_rpm", frag)

    def test_fragment_none_report_clears(self):
        frag = self.relay.heartbeat_metrics_fragment()
        self.assertEqual(frag, {"machine_controls": {}, "fan_boost_active": False})

    def test_report_rejects_bool_rpm(self):
        # a JSON bool must not sneak in as a target rpm
        self.relay.report_control_state(_fresh_report(boost_active=True, rpm=True))
        frag = self.relay.heartbeat_metrics_fragment()
        self.assertNotIn("fan_boost_target_rpm", frag)


if __name__ == "__main__":
    unittest.main()
