from __future__ import annotations

import sys
import unittest
import base64
import json
import sqlite3
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from aimonitor.quota import (  # noqa: E402
    _cursor_access_token,
    _cursor_cookie,
    parse_claude_desktop,
    parse_claude_online,
    parse_cursor,
    parse_kimi,
)


class QuotaParsingTests(unittest.TestCase):
    def test_claude_desktop_expires_each_window_by_its_own_age(self):
        now = datetime(2026, 8, 23, 12, tzinfo=timezone.utc)
        observed = now - timedelta(hours=2)
        root = {
            "samples": [
                {"t": observed.timestamp() * 1000, "u": {"fh": 46, "sd": 5, "xu": 70}}
            ]
        }

        windows = parse_claude_desktop(root, now)

        self.assertEqual([window.id for window in windows], ["claude-desktop-weekly"])
        self.assertEqual(windows[0].used_percent, 5)

    def test_claude_online_maps_only_present_windows(self):
        now = datetime(2026, 8, 23, 12, tzinfo=timezone.utc)
        windows = parse_claude_online(
            {
                "five_hour": {"utilization": 12.5, "resets_at": "2026-08-23T13:00:00Z"},
                "seven_day": None,
                "seven_day_sonnet": {"utilization": 45},
            },
            now,
        )

        self.assertEqual([window.id for window in windows], ["claude-five_hour", "claude-seven_day_sonnet"])
        self.assertEqual(windows[0].window_minutes, 300)
        self.assertEqual(windows[1].label, "weekly · Sonnet")

    def test_kimi_derives_window_and_recovers_used_from_remaining(self):
        now = datetime(2026, 8, 23, 12, tzinfo=timezone.utc)
        windows = parse_kimi(
            {
                "limits": [
                    {
                        "detail": {"limit": 100, "remaining": 98, "resetTime": "2026-08-23T13:00:00Z"},
                        "window": {"duration": 5, "timeUnit": "TIME_UNIT_HOUR"},
                    }
                ],
                "usage": {"limit": 100, "used": 7},
                "subType": "TYPE_PURCHASE",
            },
            now,
        )

        self.assertEqual([window.id for window in windows], ["kimi-window-300", "kimi-plan"])
        self.assertEqual(windows[0].used_percent, 2)
        self.assertEqual(windows[0].label, "5h")
        self.assertAlmostEqual(windows[1].used_percent, 7)

    def test_cursor_parses_plan_auto_and_named_model_windows(self):
        now = datetime(2026, 8, 23, 12, tzinfo=timezone.utc)
        windows = parse_cursor(
            {
                "billingCycleStart": "2026-08-01T00:00:00Z",
                "billingCycleEnd": "2026-09-01T00:00:00Z",
                "membershipType": "pro",
                "individualUsage": {
                    "plan": {
                        "totalPercentUsed": 12.5,
                        "autoPercentUsed": 4,
                        "apiPercentUsed": 0,
                    }
                },
            },
            now,
        )

        self.assertEqual([window.id for window in windows], ["cursor-plan", "cursor-auto", "cursor-api"])
        self.assertEqual(windows[0].label, "31d")
        self.assertEqual(windows[0].window_minutes, 44640)
        self.assertEqual(windows[2].used_percent, 0)
        self.assertEqual(windows[0].plan_type, "pro")

    def test_cursor_falls_back_to_real_used_limit_ratio(self):
        now = datetime(2026, 8, 23, 12, tzinfo=timezone.utc)
        windows = parse_cursor(
            {
                "individualUsage": {"overall": {"used": 25, "limit": 100}},
            },
            now,
        )
        self.assertEqual(len(windows), 1)
        self.assertEqual(windows[0].used_percent, 25)
        self.assertEqual(windows[0].label, "billing cycle")

    def test_cursor_cookie_rejects_expired_token(self):
        now = datetime(2026, 8, 23, 12, tzinfo=timezone.utc)
        encode = lambda value: base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
        token = f"{encode({'alg': 'none'})}.{encode({'sub': 'user|abc', 'exp': now.timestamp() - 1})}.sig"
        cookie, error = _cursor_cookie(token, now)
        self.assertIsNone(cookie)
        self.assertEqual(error, "token expired")

    def test_cursor_state_is_read_without_writing_the_database(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Cursor state % file.vscdb"
            connection = sqlite3.connect(path)
            connection.execute("CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)")
            connection.execute(
                "INSERT INTO ItemTable(key,value) VALUES(?,?)",
                ("cursorAuth/accessToken", json.dumps("header.payload.signature")),
            )
            connection.commit()
            connection.close()
            token, error = _cursor_access_token(path)
            self.assertEqual(token, "header.payload.signature")
            self.assertIsNone(error)


if __name__ == "__main__":
    unittest.main()
