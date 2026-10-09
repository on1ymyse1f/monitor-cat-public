from __future__ import annotations

import sys
import unittest
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from aimonitor.models import TokenBreakdown  # noqa: E402
from aimonitor.pricing import PricingCatalog  # noqa: E402


class NewOpenAIPricingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.catalog = PricingCatalog()
        self.when = datetime(2026, 9, 23, tzinfo=timezone.utc)

    def test_official_rates_and_cached_input(self) -> None:
        self.assertEqual(self.catalog.rate("gpt-5.4").input_per_mtok, Decimal("2.5"))
        self.assertEqual(self.catalog.rate("gpt-5.4").output_per_mtok, Decimal("15"))
        self.assertEqual(self.catalog.rate("gpt-6-astra").input_per_mtok, Decimal("10"))
        self.assertEqual(self.catalog.rate("gpt-6-astra").output_per_mtok, Decimal("50"))
        self.assertEqual(self.catalog.rate("gpt-6-sol").input_per_mtok, Decimal("2"))
        self.assertEqual(self.catalog.rate("gpt-6-sol").cached_input_per_mtok, Decimal("0.2"))
        self.assertEqual(self.catalog.rate("gpt-6-sol").output_per_mtok, Decimal("10"))
        self.assertEqual(self.catalog.rate("gpt-6-luna").input_per_mtok, Decimal("0.1"))
        self.assertEqual(self.catalog.rate("gpt-6-luna").cached_input_per_mtok, Decimal("0.01"))
        self.assertEqual(self.catalog.rate("gpt-6-luna").output_per_mtok, Decimal("0.5"))
        self.assertEqual(self.catalog.rate("gpt-5.5").input_per_mtok, Decimal("5"))
        self.assertEqual(self.catalog.rate("gpt-5.5").output_per_mtok, Decimal("30"))
        tokens = TokenBreakdown(uncached_input=1_000_000, cached_input=1_000_000, output=1_000_000)
        self.assertEqual(self.catalog.cost(tokens, "gpt-6-astra", at=self.when), Decimal("61"))
        self.assertEqual(self.catalog.cost(tokens, "gpt-5.5", at=self.when), Decimal("35.5"))
        with_cache_write = TokenBreakdown(
            uncached_input=1_000_000, cached_input=1_000_000,
            cache_write_unspecified=1_000_000, output=1_000_000,
        )
        self.assertEqual(self.catalog.cost(with_cache_write, "gpt-6-sol", at=self.when), Decimal("14.7"))
        self.assertEqual(self.catalog.cost(with_cache_write, "gpt-6-luna", at=self.when), Decimal("0.735"))

    def test_dated_snapshots_are_narrow_and_variants_are_unpriced(self) -> None:
        self.assertEqual(self.catalog.rate("gpt-5.5-2026-04-23").output_per_mtok, Decimal("30"))
        self.assertEqual(self.catalog.rate("gpt-6-astra-20260901").output_per_mtok, Decimal("50"))
        self.assertEqual(self.catalog.rate("gpt-6-sol-20260922").output_per_mtok, Decimal("10"))
        self.assertIsNone(self.catalog.rate("gpt-5.5-pro"))
        self.assertIsNone(self.catalog.rate("gpt-5.50"))
        self.assertIsNone(self.catalog.rate("gpt-6-luna-pro"))


class KimiPricingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.catalog = PricingCatalog()

    def test_published_cached_input_rates(self) -> None:
        tokens = TokenBreakdown(uncached_input=1_000_000, cached_input=1_000_000, output=1_000_000)
        self.assertEqual(self.catalog.cost(tokens, "k3-agent"), Decimal("18.3"))
        self.assertEqual(self.catalog.cost(tokens, "k2d6-agent"), Decimal("5.11"))
        self.assertEqual(self.catalog.cost(tokens, "kimi-code/kimi-for-coding"), Decimal("5.14"))


if __name__ == "__main__":
    unittest.main()
