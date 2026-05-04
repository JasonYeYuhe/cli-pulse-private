"""Tests for provider quota parsing and collection in system_collector.py."""
from __future__ import annotations
import unittest
from datetime import datetime, timezone
from system_collector import (
    _parse_claude_api_response, _parse_claude_usage_output, _infer_claude_plan,
    _parse_gemini_quota_response, _load_gemini_project_id,
    _parse_codex_usage_response, collect_device_snapshot, collect_all,
    _detect_provider, _should_ignore_command, _deduplicate_sessions,
    CollectedSession,
)


class TestInferClaudePlan(unittest.TestCase):
    def test_max_5x_tier(self):
        self.assertEqual(_infer_claude_plan("max_5x", ""), "Max 5x")

    def test_max_20x_tier(self):
        self.assertEqual(_infer_claude_plan("max_20x", ""), "Max 20x")

    def test_max_20x_space(self):
        self.assertEqual(_infer_claude_plan("max 20x", ""), "Max 20x")

    def test_max_generic(self):
        self.assertEqual(_infer_claude_plan("max", ""), "Max 5x")

    def test_max_case_insensitive(self):
        self.assertEqual(_infer_claude_plan("MAX_20X", ""), "Max 20x")

    def test_max_from_sub_type(self):
        self.assertEqual(_infer_claude_plan("", "max_20x"), "Max 20x")

    def test_ultra_tier(self):
        self.assertEqual(_infer_claude_plan("ultra", ""), "Ultra")

    def test_pro_tier(self):
        self.assertEqual(_infer_claude_plan("pro", ""), "Pro")

    def test_free_sub(self):
        self.assertEqual(_infer_claude_plan("", "free"), "Free")

    def test_sub_type_fallback(self):
        self.assertEqual(_infer_claude_plan("", "team"), "Team")

    def test_unknown(self):
        self.assertEqual(_infer_claude_plan("", ""), "Unknown")


class TestParseClaudeAPIResponse(unittest.TestCase):
    def test_full_response(self):
        data = {
            "five_hour": {"utilization": 45, "resets_at": "2026-04-02T22:00:00Z"},
            "seven_day": {"utilization": 60, "resets_at": "2026-04-09T00:00:00Z"},
            "seven_day_opus": {"utilization": 75, "resets_at": "2026-04-09T00:00:00Z"},
            "seven_day_sonnet": {"utilization": 20, "resets_at": "2026-04-09T00:00:00Z"},
        }
        result = _parse_claude_api_response(data, "Max")
        self.assertIsNotNone(result)
        self.assertEqual(len(result["tiers"]), 4)
        self.assertEqual(result["plan_type"], "Max")

        # 5h Window tier
        t0 = result["tiers"][0]
        self.assertEqual(t0["name"], "5h Window")
        self.assertEqual(t0["quota"], 100)
        self.assertEqual(t0["remaining"], 55)  # 100 - 45
        self.assertEqual(t0["reset_time"], "2026-04-02T22:00:00Z")

        # Weekly tier
        t1 = result["tiers"][1]
        self.assertEqual(t1["name"], "Weekly")
        self.assertEqual(t1["remaining"], 40)  # 100 - 60

        # Opus tier
        t2 = result["tiers"][2]
        self.assertEqual(t2["name"], "Opus (Weekly)")
        self.assertEqual(t2["remaining"], 25)  # 100 - 75

        # Sonnet tier
        t3 = result["tiers"][3]
        self.assertEqual(t3["name"], "Sonnet (Weekly)")
        self.assertEqual(t3["remaining"], 80)  # 100 - 20

        # Top-level quota/remaining from primary tier
        self.assertEqual(result["quota"], 100)
        self.assertEqual(result["remaining"], 55)

    def test_minimal_response(self):
        data = {"five_hour": {"utilization": 10, "resets_at": "2026-04-02T22:00:00Z"}}
        result = _parse_claude_api_response(data)
        self.assertIsNotNone(result)
        self.assertEqual(len(result["tiers"]), 1)
        self.assertEqual(result["tiers"][0]["remaining"], 90)
        self.assertEqual(result["plan_type"], "Max")  # default

    def test_with_extra_usage(self):
        data = {
            "five_hour": {"utilization": 10, "resets_at": "2026-04-02T22:00:00Z"},
            "extra_usage": {
                "is_enabled": True,
                "monthly_limit": 5000.0,
                "used_credits": 1234.56,
                "currency": "USD",
            },
        }
        result = _parse_claude_api_response(data, "Max")
        self.assertEqual(len(result["tiers"]), 2)
        extra = result["tiers"][1]
        self.assertEqual(extra["name"], "Extra Usage")
        self.assertEqual(extra["quota"], 500_000_000)  # 5000 * 100000
        expected_remaining = int(max(0, 5000.0 - 1234.56) * 100_000)
        self.assertEqual(extra["remaining"], expected_remaining)

    def test_empty_response(self):
        self.assertIsNone(_parse_claude_api_response({}))

    def test_disabled_extra_usage(self):
        data = {
            "five_hour": {"utilization": 5, "resets_at": "2026-04-02T22:00:00Z"},
            "extra_usage": {"is_enabled": False, "monthly_limit": 0, "used_credits": 0},
        }
        result = _parse_claude_api_response(data)
        self.assertEqual(len(result["tiers"]), 1, "Disabled extra_usage should not produce a tier")

    def test_designs_and_daily_routines_from_api_response(self):
        data = {
            "five_hour": {"utilization": 22, "resets_at": "2026-05-05T08:00:00Z"},
            "seven_day": {"utilization": 18, "resets_at": "2026-05-05T12:00:01Z"},
            "seven_day_sonnet": {"utilization": 2, "resets_at": "2026-05-05T12:00:00Z"},
            "iguana_necktie": {"utilization": 25.0, "resets_at": "2026-05-05T12:00:01Z"},
            "seven_day_omelette": {"utilization": 5.0, "resets_at": None},
        }
        result = _parse_claude_api_response(data, "Max")
        self.assertIsNotNone(result)

        names = [t["name"] for t in result["tiers"]]
        self.assertEqual(
            names,
            ["5h Window", "Weekly", "Sonnet (Weekly)", "Designs", "Daily Routines"],
        )

        by_name = {t["name"]: t for t in result["tiers"]}
        self.assertEqual(by_name["Designs"]["remaining"], 75)
        self.assertEqual(by_name["Designs"]["reset_time"], "2026-05-05T12:00:01Z")
        self.assertEqual(by_name["Daily Routines"]["remaining"], 95)
        self.assertIsNone(by_name["Daily Routines"]["reset_time"])

    def test_designs_null_window_means_unused_bucket(self):
        # Mirrors the real scrubbed API payload where the launch windows are
        # present but null for accounts that haven't used the feature yet.
        data = {
            "five_hour": {"utilization": 0.0, "resets_at": None},
            "seven_day": {"utilization": 18.0, "resets_at": "2026-05-05T12:00:01Z"},
            "iguana_necktie": None,
            "seven_day_omelette": {"utilization": 0.0, "resets_at": None},
        }
        result = _parse_claude_api_response(data)
        self.assertIsNotNone(result)

        by_name = {t["name"]: t for t in result["tiers"]}
        self.assertIn("Designs", by_name)
        self.assertEqual(by_name["Designs"]["quota"], 100)
        self.assertEqual(by_name["Designs"]["remaining"], 100)
        self.assertIsNone(by_name["Designs"]["reset_time"])

    def test_daily_routines_zero_utilization_means_full_remaining(self):
        data = {
            "five_hour": {"utilization": 10, "resets_at": "2026-05-05T08:00:00Z"},
            "seven_day_omelette": {"utilization": 0.0, "resets_at": None},
        }
        result = _parse_claude_api_response(data)
        self.assertIsNotNone(result)

        by_name = {t["name"]: t for t in result["tiers"]}
        self.assertIn("Daily Routines", by_name)
        self.assertEqual(by_name["Daily Routines"]["quota"], 100)
        self.assertEqual(by_name["Daily Routines"]["remaining"], 100)
        self.assertIsNone(by_name["Daily Routines"]["reset_time"])

    def test_existing_opus_null_still_skipped(self):
        # Regression guard: the new launch-window null semantics must NOT
        # leak back to the original optional model windows. A null Opus
        # window is still "feature absent for this account", not
        # "enabled-but-unused".
        data = {
            "five_hour": {"utilization": 5, "resets_at": "2026-05-05T08:00:00Z"},
            "seven_day_opus": None,
        }
        result = _parse_claude_api_response(data)
        self.assertIsNotNone(result)
        names = [t["name"] for t in result["tiers"]]
        self.assertNotIn("Opus (Weekly)", names)

    def test_designs_absent_key_skipped(self):
        # Symmetry check: if the API hasn't started returning the new keys
        # at all yet, we must not synthesize a phantom "Designs" row.
        data = {"five_hour": {"utilization": 10, "resets_at": None}}
        result = _parse_claude_api_response(data)
        self.assertIsNotNone(result)
        names = [t["name"] for t in result["tiers"]]
        self.assertNotIn("Designs", names)
        self.assertNotIn("Daily Routines", names)

    def test_designs_malformed_utilization_falls_back_to_zero(self):
        # Don't crash on a string utilization value — surface a Designs
        # row with remaining=100 (treated as 0% used) for that one window.
        data = {
            "five_hour": {"utilization": 5, "resets_at": None},
            "iguana_necktie": {"utilization": "garbage", "resets_at": None},
        }
        result = _parse_claude_api_response(data)
        self.assertIsNotNone(result)
        by_name = {t["name"]: t for t in result["tiers"]}
        self.assertEqual(by_name["Designs"]["remaining"], 100)


class TestParseClaudeUsageOutput(unittest.TestCase):
    def test_standard_cli_output(self):
        output = """Settings: Usage

Current session
42% left
Resets in 2 hours

Current week (all models)
75% left
Resets Monday 12:00 AM

Current week (Opus)
60% left
Resets Monday 12:00 AM
"""
        result = _parse_claude_usage_output(output)
        self.assertIsNotNone(result)
        # 42% left → 58% used → remaining=42
        self.assertEqual(result["tiers"][0]["name"], "5h Window")
        self.assertEqual(result["tiers"][0]["remaining"], 42)
        # 75% left → 25% used → remaining=75
        self.assertEqual(result["tiers"][1]["name"], "Weekly")
        self.assertEqual(result["tiers"][1]["remaining"], 75)
        # Opus 60% left → 40% used → remaining=60
        self.assertEqual(result["tiers"][2]["name"], "Opus (Weekly)")
        self.assertEqual(result["tiers"][2]["remaining"], 60)

    def test_no_usage_data(self):
        self.assertIsNone(_parse_claude_usage_output("Loading...\nPlease wait"))

    def test_used_semantics(self):
        output = """Current session
58% used

Current week (all models)
25% used
"""
        result = _parse_claude_usage_output(output)
        self.assertIsNotNone(result)
        # 58% used → remaining=42
        self.assertEqual(result["tiers"][0]["remaining"], 42)
        # 25% used → remaining=75
        self.assertEqual(result["tiers"][1]["remaining"], 75)


class TestParseGeminiQuotaResponse(unittest.TestCase):
    def test_prefers_pro_order_and_primary(self):
        data = {
            "buckets": [
                {"modelId": "gemini-2.5-flash", "remainingFraction": 1.0, "resetTime": "2026-04-03T09:08:42Z", "tokenType": "REQUESTS"},
                {"modelId": "gemini-2.5-flash-lite", "remainingFraction": 1.0, "resetTime": "2026-04-03T09:08:42Z", "tokenType": "REQUESTS"},
                {"modelId": "gemini-2.5-pro", "remainingFraction": 0.81, "resetTime": "2026-04-03T04:39:00Z", "tokenType": "REQUESTS"},
            ]
        }
        result = _parse_gemini_quota_response(data)
        self.assertIsNotNone(result)
        self.assertEqual([tier["name"] for tier in result["tiers"]], ["Pro", "Flash", "Flash Lite"])
        self.assertEqual(result["remaining"], 81)
        self.assertEqual(result["reset_time"], "2026-04-03T04:39:00Z")


class TestGeminiLoadCodeAssist(unittest.TestCase):
    def test_load_project_id_from_string(self):
        import system_collector as sc
        original = sc.urllib.request.urlopen
        class Resp:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self): return b'{"cloudaicompanionProject":"centering-invention-98n20"}'
        try:
            sc.urllib.request.urlopen = lambda *args, **kwargs: Resp()
            self.assertEqual(_load_gemini_project_id("token"), "centering-invention-98n20")
        finally:
            sc.urllib.request.urlopen = original


class TestParseCodexUsageResponse(unittest.TestCase):
    def test_full_response(self):
        data = {
            "plan_type": "plus",
            "rate_limit": {
                "primary_window": {
                    "used_percent": 23,
                    "reset_after_seconds": 2391,
                    "reset_at": 1775054266,
                },
                "secondary_window": {
                    "used_percent": 10,
                    "reset_after_seconds": 100000,
                    "reset_at": 1775200000,
                },
            },
        }
        result = _parse_codex_usage_response(data)
        self.assertIsNotNone(result)
        self.assertEqual(result["plan_type"], "Plus")
        self.assertEqual(len(result["tiers"]), 2)
        self.assertEqual(result["tiers"][0]["name"], "Session")
        self.assertEqual(result["tiers"][0]["remaining"], 77)
        self.assertEqual(result["tiers"][1]["name"], "Weekly")
        self.assertEqual(result["tiers"][1]["remaining"], 90)

    def test_primary_only(self):
        data = {
            "plan_type": "pro",
            "rate_limit": {
                "primary_window": {"used_percent": 50, "reset_at": 1775054266},
            },
        }
        result = _parse_codex_usage_response(data)
        self.assertIsNotNone(result)
        self.assertEqual(result["remaining"], 50)
        self.assertEqual(len(result["tiers"]), 1)

    def test_empty_rate_limit(self):
        self.assertIsNone(_parse_codex_usage_response({"plan_type": "free", "rate_limit": {}}))

    def test_no_rate_limit(self):
        self.assertIsNone(_parse_codex_usage_response({}))


class TestCollectDeviceSnapshot(unittest.TestCase):
    def test_returns_valid_snapshot(self):
        snapshot = collect_device_snapshot()
        self.assertGreaterEqual(snapshot.cpu_usage, 0)
        self.assertLessEqual(snapshot.cpu_usage, 100)
        self.assertGreaterEqual(snapshot.memory_usage, 0)
        self.assertLessEqual(snapshot.memory_usage, 100)


class TestCollectAll(unittest.TestCase):
    def test_returns_result_with_no_crash(self):
        result = collect_all()
        self.assertIsNotNone(result.device)
        self.assertIsInstance(result.sessions, list)
        self.assertIsInstance(result.alerts, list)
        self.assertIsInstance(result.provider_remaining, dict)
        self.assertIsInstance(result.collection_errors, list)


class TestDetectProviderClassification(unittest.TestCase):
    """Pin the executable-token-only matching that
    `_detect_provider` does, so plugin / arg paths can't influence
    provider classification.

    The shapes here come from Jason's actual `ps -axo command` output
    on a Mac running Claude Code 2.x — verbatim except for trimming
    repeated arg whitespace for readability.
    """

    # Scenario 1: Claude Code 2.x process whose argv contains an
    # `openai-codex` plugin path. Pre-fix this matched Codex first
    # (Codex's `\bcodex\b` pattern is checked before Claude's, and
    # the substring search ran over the whole command string).
    CLAUDE_CODE_2X_WITH_CODEX_PLUGIN = (
        "/Users/jason/Library/Application Support/Claude/claude-code/2.1.121/claude.app/Contents/MacOS/claude "
        "--output-format stream-json --verbose --input-format stream-json "
        "--plugin-dir /Users/jason/.claude/plugins/cache/openai-codex/codex/1.0.1 "
        "--model claude-opus-4-7"
    )

    # Scenario 2: /Applications/Claude.app's pre-launch wrapper.
    # Has the actual claude CLI as its first argv. The wrapper
    # process should be IGNORED by `_should_ignore_command`, so the
    # row never reaches `_detect_provider` in production.
    DISCLAIMER_WRAPPER = (
        "/Applications/Claude.app/Contents/Helpers/disclaimer "
        "/Users/jason/Library/Application Support/Claude/claude-code/2.1.121/claude.app/Contents/MacOS/claude "
        "--output-format stream-json --plugin-dir /Users/jason/.claude/plugins/..."
    )

    # Scenario 3: real Codex CLI invocations.
    REAL_CODEX_BREW = "/usr/local/bin/codex --some-flag"
    REAL_CODEX_BARE = "codex"

    def test_claude_code_2x_with_codex_plugin_classifies_as_claude(self):
        match = _detect_provider(self.CLAUDE_CODE_2X_WITH_CODEX_PLUGIN)
        self.assertIsNotNone(match)
        provider, confidence = match
        self.assertEqual(provider, "Claude")
        self.assertEqual(confidence, "high")

    def test_disclaimer_wrapper_is_ignored(self):
        # The dedicated guard: even before reaching _detect_provider,
        # the wrapper is filtered out as noise. This prevents it from
        # winning the dedup primary slot and surfacing a name that
        # the macOS Sessions panel then hides as artifact.
        self.assertTrue(_should_ignore_command(self.DISCLAIMER_WRAPPER))

    def test_disclaimer_wrapper_classification_when_not_ignored_is_still_claude(self):
        # Defensive: even if the ignore guard ever regresses, the
        # executable-only matcher must NOT classify the disclaimer
        # path as Codex (its argv contains openai-codex paths).
        match = _detect_provider(self.DISCLAIMER_WRAPPER)
        self.assertIsNotNone(match)
        provider, _confidence = match
        self.assertEqual(provider, "Claude")

    def test_real_codex_brew_path_classifies_as_codex(self):
        match = _detect_provider(self.REAL_CODEX_BREW)
        self.assertIsNotNone(match)
        provider, _confidence = match
        self.assertEqual(provider, "Codex")

    def test_real_codex_bare_command_classifies_as_codex(self):
        match = _detect_provider(self.REAL_CODEX_BARE)
        self.assertIsNotNone(match)
        provider, _confidence = match
        self.assertEqual(provider, "Codex")

    def test_empty_command_returns_none(self):
        self.assertIsNone(_detect_provider(""))
        self.assertIsNone(_detect_provider("   "))

    def test_args_only_codex_substring_does_not_classify_as_codex(self):
        # A node process whose argv mentions codex (e.g. running a
        # Codex unit test). Pre-fix would classify as Codex; post-fix
        # the executable token is `node` so no provider matches.
        match = _detect_provider("node --no-warnings /opt/codex/cli.js")
        # Note: this row is also caught by IGNORED_COMMAND_PATTERNS
        # (`node ` prefix + ` --no-warnings`), so in production it
        # wouldn't even reach detect_provider. We assert detection
        # alone here so a future ignore-pattern tweak doesn't silently
        # reintroduce the classification false positive.
        self.assertIsNone(match)


class TestSessionDedupClaudeCode2x(unittest.TestCase):
    """Mixed-input dedup must produce a clean Claude row even when the
    process tree includes the disclaimer wrapper alongside the real
    Claude Code child.
    """

    def _make(self, *, pid: str, name: str, provider: str, confidence: str,
              project: str = "Documents-cli-pulse",
              cpu_usage: float = 1.0) -> CollectedSession:
        ts = datetime.now(timezone.utc).isoformat()
        return CollectedSession(
            session_id=f"proc-{pid}",
            name=name,
            provider=provider,
            project=project,
            status="Running",
            total_usage=1000,
            requests=1,
            error_count=0,
            started_at=ts,
            last_active_at=ts,
            exact_cost=None,
            cpu_usage=cpu_usage,
            command="",
            collection_confidence=confidence,
            project_hash=None,
            project_root=None,
            _child_pids=[pid],
        )

    def test_dedup_picks_claude_child_not_disclaimer(self):
        # In production, the disclaimer row would be filtered before
        # entering dedup (test_disclaimer_wrapper_is_ignored above).
        # This test simulates a regression where it slipped through:
        # dedup must STILL produce a clean Claude row in that case.
        # The actual Claude child (high-conf, real binary path) wins
        # over the disclaimer wrapper because we deliberately give the
        # wrapper a lower-confidence label downstream of any helper-
        # side regressions.
        disclaimer = self._make(
            pid="6167",
            name="/Applications/Claude.app/Contents/Helpers/disclaim...",
            provider="Claude",
            confidence="medium",  # if the ignore guard ever lets this through, it should rank below the real child
        )
        real_child = self._make(
            pid="6168",
            name="/Users/jason/Library/Application Support/Cl...",
            provider="Claude",
            confidence="high",
        )
        merged = _deduplicate_sessions([disclaimer, real_child])
        self.assertEqual(len(merged), 1, "Same provider+project must dedup to one row")
        self.assertTrue(
            "/Library/" in merged[0].name or merged[0].name.startswith("/Users/"),
            f"Primary should be the real child, got name={merged[0].name}",
        )

    def test_dedup_keeps_codex_separate_from_claude(self):
        codex = self._make(
            pid="9001",
            name="/usr/local/bin/codex",
            provider="Codex",
            confidence="high",
            project="Documents-cli-pulse",
        )
        claude = self._make(
            pid="9002",
            name="/Users/jason/Library/.../claude",
            provider="Claude",
            confidence="high",
            project="Documents-cli-pulse",
        )
        merged = _deduplicate_sessions([codex, claude])
        # Different providers → both survive even with same project.
        providers = sorted(s.provider for s in merged)
        self.assertEqual(providers, ["Claude", "Codex"])


if __name__ == "__main__":
    unittest.main()
