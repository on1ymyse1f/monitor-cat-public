from __future__ import annotations

import sys
import threading
import unittest
from dataclasses import asdict
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from aimonitor import (  # noqa: E402
    AIEvent,
    Confidence,
    EventStore,
    PricingCatalog,
    QuotaWindow,
    TokenBreakdown,
)
from aimonitor.report import profile_card_html, snapshot_json  # noqa: E402


class StoreReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.store = EventStore.in_memory()
        # Keep the two dashboard fixtures in one civil minute. Using the
        # wall-clock second made this test legitimately count two active
        # minutes whenever the test happened to start near a minute boundary.
        self.now = datetime.now(timezone.utc).replace(second=45, microsecond=0)

    def tearDown(self) -> None:
        self.store.close()

    def add(
        self,
        identity: str,
        provider: str,
        tokens: int,
        *,
        when: datetime | None = None,
        session: str = "session",
        model: str | None = "model",
        project: str | None = "project",
        cost: str | None = None,
    ) -> None:
        self.store.insert_event(
            AIEvent(
                id=identity,
                timestamp=when or self.now,
                provider=provider,
                model=model,
                session_id=session,
                project=project,
                tokens=TokenBreakdown(uncached_input=tokens),
                cost_usd=Decimal(cost) if cost is not None else None,
                confidence=Confidence.EXACT,
            )
        )

    def test_dashboard_timeline_models_and_live_contracts(self) -> None:
        self.add("a", "Claude Code", 100, when=self.now - timedelta(seconds=30), cost="0.02")
        self.add(
            "b",
            "Codex CLI",
            300,
            when=self.now - timedelta(seconds=20),
            session="codex-session",
            model="gpt-5.6-terra",
        )
        dashboard = self.store.dashboard(now=self.now)
        self.assertEqual(dashboard.today_tokens, 400)
        self.assertEqual(dashboard.today_requests, 2)
        self.assertEqual(dashboard.today_active_minutes, 1)
        self.assertAlmostEqual(sum(share.fraction for share in dashboard.usage_shares), 1.0)
        self.assertTrue(dashboard.flow_is_hourly)

        timeline = self.store.recent_events(provider="Claude Code")
        self.assertEqual(len(timeline), 1)
        self.assertEqual(timeline[0].billable, 100)
        models = self.store.totals_by_model()
        self.assertEqual({item.model for item in models}, {"model", "gpt-5.6-terra"})

        live = self.store.live_counters(now=self.now, limit=1)
        self.assertTrue(live.is_live)
        self.assertEqual(live.live_session_count, 2)
        self.assertEqual(live.hidden_sessions, 1)
        self.assertEqual(live.active_session_billable, 300)
        self.assertIn("is_live", asdict(live), "Tk dataclass conversion retains computed interface fields")

    def test_activity_groups_only_continuous_same_session_and_model(self) -> None:
        self.add("a", "Claude Code", 10, when=self.now - timedelta(minutes=4), session="one")
        self.add("b", "Claude Code", 20, when=self.now - timedelta(minutes=3), session="one")
        self.add("c", "Claude Code", 30, when=self.now, session="two")
        spans = self.store.recent_activity()
        self.assertEqual(len(spans), 2)
        self.assertEqual(spans[1].billable, 30)
        self.assertEqual(spans[1].events, 2)

    def test_quota_dedup_confirmation_and_dashboard(self) -> None:
        first = self.now - timedelta(minutes=5)
        reset = self.now + timedelta(hours=2)
        quota1 = QuotaWindow("q", "5h", 80, 300, first, reset)
        quota2 = QuotaWindow("q", "5h", 80, 300, self.now, reset)
        self.assertTrue(self.store.insert_quota("Claude", quota1))
        self.assertFalse(self.store.insert_quota("Claude", quota2))
        self.assertEqual(len(self.store.quota_history("Claude", "q")), 1)
        self.assertEqual(self.store.quota_confirmed_at("Claude", "q"), self.now)
        dashboard = self.store.dashboard(now=self.now)
        self.assertEqual(len(dashboard.quotas), 1)
        self.assertEqual(dashboard.quotas[0].window.used_percent, 80)

    def test_settings_retention_delete_and_privacy_scope(self) -> None:
        self.store.set_setting("appearance", "dark")
        self.store.set_setting("retention_days", "7")
        self.add("old", "Claude Code", 1, when=self.now - timedelta(days=8))
        self.add("new", "Claude Code", 2, when=self.now)
        self.assertEqual(self.store.apply_retention(now=self.now), 1)
        self.assertEqual(self.store.event_count(), 1)
        self.store.set_checkpoint("source", self._checkpoint())
        self.store.insert_quota(
            "Claude",
            QuotaWindow("q", "5h", 1, 300, self.now, self.now + timedelta(hours=1)),
        )
        deleted = self.store.delete_all_data()
        self.assertEqual(deleted, {"events": 1, "quota_snapshots": 1, "checkpoints": 1})
        self.assertEqual(self.store.get_setting("appearance"), "dark", "privacy deletion preserves preferences")
        self.assertEqual(self.store.event_count(), 0)

    @staticmethod
    def _checkpoint():
        from aimonitor import Checkpoint

        return Checkpoint(10, 10)

    def test_profile_card_streak_data_and_html_escape(self) -> None:
        local_today = self.now.astimezone().date()
        for index, tokens in ((2, 10), (1, 20), (0, 30)):
            local_noon = datetime.combine(
                local_today - timedelta(days=index), datetime.min.time(), tzinfo=self.now.astimezone().tzinfo
            ) + timedelta(hours=12)
            self.add(f"d{index}", "Claude <Code>", tokens, when=local_noon.astimezone(timezone.utc))
        data = self.store.profile_card_data("Claude <Code>", today=self.now)
        self.assertEqual(data.total_billable, 60)
        self.assertEqual(data.current_streak, 3)
        self.assertEqual(data.longest_streak, 3)
        document = profile_card_html(data, name="A & B", handle='a"b')
        self.assertIn("Claude &lt;Code&gt;", document)
        self.assertIn("A &amp; B", document)
        self.assertNotIn("A & B", document)

    def test_rlock_serializes_background_writers_and_snapshot_is_json(self) -> None:
        def writer(prefix: str) -> None:
            for index in range(50):
                self.add(f"{prefix}-{index}", "Claude Code", 1, session=prefix)

        threads = [threading.Thread(target=writer, args=(str(index),)) for index in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(self.store.event_count(), 200)
        rendered = snapshot_json(self.store, now=self.now)
        self.assertIn('"dashboard"', rendered)
        self.assertIn('"settings"', rendered)

    def test_explicit_transaction_rolls_back(self) -> None:
        with self.assertRaises(RuntimeError):
            with self.store.transaction():
                self.add("rollback", "Claude Code", 1)
                raise RuntimeError("stop")
        self.assertEqual(self.store.event_count(), 0)

    def test_late_model_backfill_escapes_windows_path_and_like_wildcards(self) -> None:
        prefix = r"codex:C:\Users\me\work_100%\rollout-test.jsonl@"
        self.add(prefix + "128", "Codex CLI", 100, model=None)

        updated = self.store.attribute_missing_model(
            prefix, "gpt-5.6-terra", PricingCatalog()
        )

        self.assertEqual(updated, 1)
        total = self.store.totals_by_model()[0]
        self.assertEqual(total.model, "gpt-5.6-terra")
        self.assertIsNotNone(total.cost_usd)


if __name__ == "__main__":
    unittest.main()
