from __future__ import annotations

import sys
import unittest
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from aimonitor.collectors import (  # noqa: E402
    claude_tokens,
    codex_tokens,
    kimi_tokens,
    normalize_kimi_web_quota,
    parse_claude_quota_windows,
    parse_codex_quota_windows,
    parse_kimi_quota_windows,
    parse_timestamp,
)
from aimonitor.models import QuotaWindow, TokenBreakdown  # noqa: E402
from aimonitor.pricing import PricingCatalog  # noqa: E402


class CollectorContractTests(unittest.TestCase):
    def test_claude_cache_ttl_and_reasoning_are_preserved(self) -> None:
        tokens = claude_tokens(
            {
                "input_tokens": 100,
                "cache_read_input_tokens": 200,
                "cache_creation_input_tokens": 340,
                "cache_creation": {
                    "ephemeral_5m_input_tokens": 30,
                    "ephemeral_1h_input_tokens": 300,
                },
                "output_tokens": 40,
                "output_tokens_details": {"thinking_tokens": 12},
            }
        )
        self.assertEqual(tokens.uncached_input, 100)
        self.assertEqual(tokens.cache_write_5m, 30)
        self.assertEqual(tokens.cache_write_1h, 300)
        self.assertEqual(tokens.cache_write_unspecified, 10)
        self.assertEqual(tokens.reasoning, 12)
        self.assertEqual(tokens.billable, 680, "reasoning is already inside output")

    def test_codex_inclusive_input_is_normalized(self) -> None:
        tokens = codex_tokens(
            {
                "input_tokens": "300",
                "cached_input_tokens": 100,
                "cache_write_input_tokens": 5,
                "output_tokens": 20,
                "reasoning_output_tokens": 7,
            }
        )
        self.assertEqual(tokens.uncached_input, 200)
        self.assertEqual(tokens.cached_input, 100)
        self.assertEqual(tokens.billable, 325)

    def test_kimi_only_accepts_turn_scope(self) -> None:
        self.assertIsNone(kimi_tokens({"usageScope": "session", "usage": {"output": 9}}))
        tokens = kimi_tokens(
            {
                "type": "usage.record",
                "usageScope": "turn",
                "usage": {
                    "inputOther": 10,
                    "inputCacheRead": 20,
                    "inputCacheCreation": 30,
                    "output": 40,
                },
            }
        )
        self.assertEqual(tokens, TokenBreakdown(10, 20, 0, 0, 30, 40, 0))

    def test_timestamp_accepts_microseconds_and_epoch_milliseconds(self) -> None:
        expected = datetime(2026, 8, 18, 4, 22, 54, 677068, tzinfo=timezone.utc)
        self.assertEqual(parse_timestamp("2026-08-18T04:22:54.677068Z"), expected)
        self.assertEqual(parse_timestamp(expected.timestamp() * 1000), expected)

    def test_codex_quota_label_is_derived_and_null_secondary_is_absent(self) -> None:
        observed = datetime(2026, 8, 18, tzinfo=timezone.utc)
        windows = parse_codex_quota_windows(
            {
                "limit_id": "premium",
                "plan_type": "plus",
                "primary": {
                    "used_percent": 25,
                    "window_minutes": 10080,
                    "resets_at": 1_787_196_990,
                },
                "secondary": None,
            },
            observed,
        )
        self.assertEqual(len(windows), 1)
        self.assertEqual(windows[0].label, "weekly")
        self.assertEqual(windows[0].plan_type, "plus")
        self.assertEqual(windows[0].resets_at.timestamp(), 1_787_196_990)

    def test_claude_quota_missing_windows_are_not_zero(self) -> None:
        now = datetime.now(timezone.utc)
        windows = parse_claude_quota_windows(
            {
                "five_hour": {
                    "utilization": 33,
                    "resets_at": "2026-08-18T07:00:00.528743+00:00",
                },
                "seven_day": None,
            },
            now,
        )
        self.assertEqual([window.id for window in windows], ["claude-five_hour"])
        self.assertEqual(windows[0].window_minutes, 300)

    def test_kimi_quota_real_shape_and_web_normalization(self) -> None:
        now = datetime.now(timezone.utc)
        web = {
            "usages": [
                {"scope": "FEATURE_CHAT", "detail": {"limit": 1, "used": 1}},
                {
                    "scope": "FEATURE_CODING",
                    "detail": {"limit": "2048", "used": "214"},
                    "limits": [
                        {
                            "window": {
                                "duration": 300,
                                "timeUnit": "TIME_UNIT_MINUTE",
                            },
                            "detail": {"limit": "200", "remaining": "61"},
                        }
                    ],
                },
            ]
        }
        windows = parse_kimi_quota_windows(normalize_kimi_web_quota(web), now)
        five_hour = next(window for window in windows if window.label == "5h")
        plan = next(window for window in windows if window.label == "weekly")
        self.assertAlmostEqual(five_hour.used_percent, 69.5)
        self.assertAlmostEqual(plan.used_percent, 214 / 2048 * 100)

    def test_quota_staleness_scales_with_window(self) -> None:
        observed = datetime(2026, 8, 18, tzinfo=timezone.utc)
        quota = QuotaWindow("q", "5h", 10, 300, observed)
        self.assertEqual(quota.staleness(observed)[0], "live")
        self.assertEqual(quota.staleness(observed.replace(hour=1))[0], "aging")
        self.assertEqual(quota.staleness(observed.replace(hour=2))[0], "expired")

    def test_pricing_is_exact_and_unknown_model_is_none(self) -> None:
        pricing = PricingCatalog()
        tokens = TokenBreakdown(uncached_input=1_000_000, output=1_000_000)
        self.assertEqual(pricing.cost(tokens, "claude-opus-5"), Decimal("30"))
        self.assertIsNone(pricing.cost(tokens, "future-unknown-model"))


if __name__ == "__main__":
    unittest.main()
