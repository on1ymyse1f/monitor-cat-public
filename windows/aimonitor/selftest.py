"""Non-interactive smoke test used against the packaged Windows executable."""

from __future__ import annotations

import json
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from .store import EventStore
from .sync import SyncEngine


def _line(value: dict) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"


def run_self_test() -> bool:
    try:
        with tempfile.TemporaryDirectory(prefix="aimonitor-selftest-") as temporary:
            root = Path(temporary)
            claude = root / "claude"
            codex = root / "codex"
            kimi = root / "kimi"
            claude_file = claude / "demo" / "session.jsonl"
            codex_file = codex / "2026" / "08" / "23" / "rollout-selftest.jsonl"
            kimi_file = kimi / "workspace" / "session_selftest" / "agents" / "main" / "wire.jsonl"
            for path in (claude_file, codex_file, kimi_file):
                path.parent.mkdir(parents=True, exist_ok=True)
            stamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            claude_file.write_text(
                _line(
                    {
                        "timestamp": stamp,
                        "requestId": "selftest-request",
                        "sessionId": "selftest-claude",
                        "message": {
                            "id": "selftest-message",
                            "model": "claude-sonnet-4-6",
                            "usage": {"input_tokens": 10, "output_tokens": 5},
                        },
                    }
                ),
                encoding="utf-8",
            )
            codex_file.write_text(
                _line(
                    {
                        "type": "session_meta",
                        "payload": {"id": "selftest-codex", "cwd": r"C:\work\selftest"},
                    }
                )
                + _line(
                    {
                        "timestamp": stamp,
                        "type": "event_msg",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": {
                                    "input_tokens": 20,
                                    "cached_input_tokens": 5,
                                    "output_tokens": 10,
                                }
                            },
                            "rate_limits": {
                                "limit_id": "selftest",
                                "primary": {
                                    "used_percent": 25,
                                    "window_minutes": 300,
                                },
                            },
                        },
                    }
                ),
                encoding="utf-8",
            )
            kimi_file.write_text(
                _line(
                    {
                        "type": "usage.record",
                        "model": "kimi-code/kimi-for-coding",
                        "usageScope": "turn",
                        "usage": {"inputOther": 7, "inputCacheRead": 3, "output": 2},
                        "time": int(datetime.now(timezone.utc).timestamp() * 1000),
                    }
                ),
                encoding="utf-8",
            )

            with EventStore(root / "aimonitor.db") as store:
                engine = SyncEngine(
                    store,
                    claude_root=claude,
                    codex_root=codex,
                    kimi_roots=(kimi,),
                )
                first = engine.sync()
                if first.events_written != 3 or store.event_count() != 3:
                    return False
                dashboard = store.dashboard()
                if dashboard.today_tokens != 57 or not dashboard.quotas:
                    return False
                second = engine.sync()
                if second.events_written != 0 or store.event_count() != 3:
                    return False
        return True
    except Exception:
        return False
