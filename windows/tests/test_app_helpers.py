from __future__ import annotations

import sys
import queue
import threading
import unittest
from datetime import datetime, timezone
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import (  # noqa: E402
    MonitorApp,
    _dashboard_visual,
    _live_visual,
    _plain,
    compact,
    duration,
    money,
)
from aimonitor.models import LiveCounters, LiveSession  # noqa: E402
from aimonitor.selftest import run_self_test  # noqa: E402


class AppHelperTests(unittest.TestCase):
    def test_formatters_keep_unknown_cost_distinct_from_zero(self):
        self.assertEqual(compact(1_250_000), "1.25M")
        self.assertEqual(duration(125), "2h 5m")
        self.assertEqual(money(None), "n/a")
        self.assertEqual(money(0), "~$0.00")

    def test_plain_preserves_live_counter_computed_properties(self):
        now = datetime.now(timezone.utc)
        counters = LiveCounters(
            sessions=[
                LiveSession(
                    session_id="s",
                    provider="Codex CLI",
                    model="gpt-test",
                    project="demo",
                    billable=50,
                    recent_billable=20,
                    cost_usd=None,
                    tokens_per_minute=10,
                    started_at=now,
                    last_event_at=now,
                    clock_skew_seconds=0,
                    clock_disagrees=False,
                    is_live=True,
                )
            ],
            live_session_count=1,
        )

        value = _plain(counters)

        self.assertTrue(value["is_live"])
        self.assertEqual(value["hidden_sessions"], 0)
        self.assertEqual(value["active_session_billable"], 50)

    def test_packaged_self_test_contract(self):
        self.assertTrue(run_self_test())

    def test_tray_actions_are_queued_without_touching_tk(self):
        app = object.__new__(MonitorApp)
        app._closing = False
        app._ui_queue = queue.Queue()
        called = []

        worker = threading.Thread(target=lambda: app._enqueue_ui(lambda: called.append("main")))
        worker.start()
        worker.join()

        self.assertEqual(called, [], "the tray worker must not execute UI code itself")
        app._ui_queue.get_nowait()()
        self.assertEqual(called, ["main"])

    def test_dashboard_visual_identity_ignores_refresh_timestamp(self):
        first = {
            "today_tokens": 10,
            "generated_at": "2026-08-23T01:00:00Z",
            "quotas": [{"confirmed_at": "a", "window": {"used_percent": 5, "observed_at": "a"}}],
        }
        second = {
            "today_tokens": 10,
            "generated_at": "2026-08-23T01:00:15Z",
            "quotas": [{"confirmed_at": "b", "window": {"used_percent": 5, "observed_at": "b"}}],
        }

        self.assertEqual(_dashboard_visual(first), _dashboard_visual(second))
        second["today_tokens"] = 11
        self.assertNotEqual(_dashboard_visual(first), _dashboard_visual(second))

    def test_live_visual_identity_ignores_unrendered_rate_drift(self):
        first = {
            "is_live": True,
            "live_session_count": 1,
            "hidden_sessions": 0,
            "sessions": [{"session_id": "s", "billable": 10, "tokens_per_minute": 8.0}],
        }
        second = {
            "is_live": True,
            "live_session_count": 1,
            "hidden_sessions": 0,
            "sessions": [{"session_id": "s", "billable": 10, "tokens_per_minute": 7.0}],
        }

        self.assertEqual(_live_visual(first), _live_visual(second))
        second["sessions"][0]["billable"] = 11
        self.assertNotEqual(_live_visual(first), _live_visual(second))


if __name__ == "__main__":
    unittest.main()
