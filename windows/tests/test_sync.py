from __future__ import annotations

import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from aimonitor import EventStore, SyncEngine  # noqa: E402
from aimonitor.collectors import CLAUDE_PROVIDER, CODEX_PROVIDER, KIMI_PROVIDER  # noqa: E402


def append_jsonl(path: Path, *objects: dict, newline: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8", newline="") as handle:
        for index, obj in enumerate(objects):
            handle.write(json.dumps(obj, separators=(",", ":")))
            if newline or index < len(objects) - 1:
                handle.write("\n")


class SyncEngineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name)
        self.claude = base / ".claude" / "projects"
        self.codex = base / ".codex" / "sessions"
        self.kimi = base / ".kimi-code" / "sessions"
        self.store = EventStore.in_memory()
        self.engine = SyncEngine(
            self.store,
            claude_root=self.claude,
            codex_root=self.codex,
            kimi_roots=[self.kimi],
        )

    def tearDown(self) -> None:
        self.store.close()
        self.temp.cleanup()

    @staticmethod
    def claude_record(request: str, output: int, session: str = "c-session") -> dict:
        return {
            "timestamp": "2026-08-23T01:00:00Z",
            "requestId": request,
            "sessionId": session,
            "message": {
                "id": "message-" + request,
                "model": "claude-opus-5",
                "usage": {
                    "input_tokens": 10,
                    "cache_read_input_tokens": 20,
                    "cache_creation_input_tokens": 0,
                    "output_tokens": output,
                },
            },
        }

    def test_claude_progressive_snapshots_keep_largest_and_append_incrementally(self) -> None:
        log = self.claude / "-C-Users-me-project" / "session.jsonl"
        append_jsonl(log, self.claude_record("r1", 5), self.claude_record("r1", 30))
        first = self.engine.sync()
        self.assertEqual(first.files_scanned, 1)
        self.assertEqual(self.store.event_count(CLAUDE_PROVIDER), 1)
        self.assertEqual(self.store.token_breakdown(CLAUDE_PROVIDER).output, 30)

        unchanged = self.engine.sync()
        self.assertEqual(unchanged.files_skipped_unchanged, 1)
        append_jsonl(log, self.claude_record("r1", 7), self.claude_record("r2", 11))
        self.engine.sync()
        self.assertEqual(self.store.event_count(CLAUDE_PROVIDER), 2)
        self.assertEqual(self.store.token_breakdown(CLAUDE_PROVIDER).output, 41)
        checkpoint = self.store.checkpoint(log)
        self.assertEqual(checkpoint.offset, log.stat().st_size)

    def test_malformed_unterminated_tail_is_resumed_not_lost(self) -> None:
        log = self.claude / "project" / "tail.jsonl"
        append_jsonl(log, self.claude_record("complete", 1))
        with log.open("ab") as handle:
            handle.write(b'{"requestId":"later","message":{"usage":')
        self.engine.sync()
        boundary = self.store.checkpoint(log).offset
        self.assertLess(boundary, log.stat().st_size)
        with log.open("ab") as handle:
            handle.write(
                b'{"input_tokens":1,"output_tokens":9},"model":"claude-opus-5"},'
                b'"timestamp":"2026-08-23T01:01:00Z"}\n'
            )
        self.engine.sync()
        self.assertEqual(self.store.event_count(CLAUDE_PROVIDER), 2)

    def test_unterminated_tail_before_usage_needle_is_not_checkpointed(self) -> None:
        log = self.claude / "project" / "late-needle.jsonl"
        prefix = b'{"timestamp":"2026-08-23T01:01:00Z","requestId":"late","message":{'
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_bytes(prefix)
        self.engine.sync()
        self.assertEqual(self.store.checkpoint(log).offset, 0)
        with log.open("ab") as handle:
            handle.write(
                b'"model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":9}}}\n'
            )
        self.engine.sync()
        self.assertEqual(self.store.event_count(CLAUDE_PROVIDER), 1)

    def test_codex_cumulative_deltas_model_and_quota_survive_restart(self) -> None:
        log = self.codex / "2026" / "08" / "23" / "rollout-test.jsonl"
        meta = {"type": "session_meta", "payload": {"id": "thread-1", "cwd": "C:\\work\\demo"}}
        context = {"type": "turn_context", "payload": {"model": "gpt-5.6-terra"}}

        def count(at: str, input_tokens: int, cached: int, output: int, used: int) -> dict:
            return {
                "type": "event_msg",
                "timestamp": at,
                "payload": {
                    "type": "token_count",
                    "info": {
                        "total_token_usage": {
                            "input_tokens": input_tokens,
                            "cached_input_tokens": cached,
                            "output_tokens": output,
                        }
                    },
                    "rate_limits": {
                        "limit_id": "codex",
                        "plan_type": "plus",
                        "primary": {
                            "used_percent": used,
                            "window_minutes": 300,
                            "resets_at": 1_790_000_000,
                        },
                        "secondary": None,
                    },
                },
            }

        first_count = count("2026-08-23T01:00:00Z", 100, 20, 10, 10)
        append_jsonl(log, meta, context, first_count, first_count, count("2026-08-23T01:01:00Z", 150, 30, 20, 12))
        self.engine.sync()
        self.assertEqual(self.store.event_count(CODEX_PROVIDER), 2, "duplicate cumulative count has zero delta")
        self.assertEqual(self.store.token_breakdown(CODEX_PROVIDER).billable, 170)
        self.assertEqual(self.store.totals_by_model()[0].model, "gpt-5.6-terra")
        self.assertEqual(len(self.store.latest_quotas()), 1, "latest returns one row per window")
        self.assertEqual(len(self.store.quota_history(CODEX_PROVIDER, "codex")), 2)

        append_jsonl(log, count("2026-08-23T01:02:00Z", 180, 35, 25, 12))
        self.engine.sync()
        self.assertEqual(self.store.token_breakdown(CODEX_PROVIDER).billable, 205)
        self.assertEqual(len(self.store.quota_history(CODEX_PROVIDER, "codex")), 2)

    def test_codex_inherited_parent_snapshot_is_baseline(self) -> None:
        log = self.codex / "rollout-subagent.jsonl"
        append_jsonl(
            log,
            {
                "type": "session_meta",
                "payload": {"id": "child", "thread_source": "subagent"},
            },
            {"type": "turn_context", "payload": {"model": "gpt-5.6-luna"}},
            {
                "type": "event_msg",
                "timestamp": "2026-08-23T02:00:00Z",
                "payload": {
                    "type": "token_count",
                    "info": {"total_token_usage": {"input_tokens": 1000, "output_tokens": 100}},
                },
            },
            {
                "type": "event_msg",
                "timestamp": "2026-08-23T02:01:00Z",
                "payload": {
                    "type": "token_count",
                    "info": {"total_token_usage": {"input_tokens": 1100, "output_tokens": 110}},
                },
            },
        )
        self.engine.sync()
        tokens = self.store.token_breakdown(CODEX_PROVIDER)
        self.assertEqual(tokens.billable, 110)

    def test_kimi_turn_records_and_session_index(self) -> None:
        log = self.kimi / "wd_fallback_abcdef" / "session_abc" / "agents" / "main" / "wire.jsonl"
        append_jsonl(
            self.kimi.parent / "session_index.jsonl",
            {"sessionId": "session_abc", "workDir": "C:\\work\\indexed-project"},
        )
        append_jsonl(
            log,
            {
                "type": "usage.record",
                "usageScope": "turn",
                "model": "kimi-code/kimi-for-coding",
                "usage": {"inputOther": 10, "inputCacheRead": 20, "inputCacheCreation": 3, "output": 4},
                "time": 1_787_027_774_677,
            },
            {
                "type": "usage.record",
                "usageScope": "session",
                "usage": {"output": 999},
                "time": 1_787_027_775_677,
            },
        )
        self.engine.sync()
        self.assertEqual(self.store.event_count(KIMI_PROVIDER), 1)
        event = self.store.recent_events(provider=KIMI_PROVIDER)[0]
        self.assertEqual(event.project, "indexed-project")
        self.assertEqual(event.billable, 37)

    def test_event_and_checkpoint_rollback_together(self) -> None:
        class FailingCheckpointStore(EventStore):
            def set_checkpoint(self, path, checkpoint):  # type: ignore[override]
                raise ValueError("simulated checkpoint failure")

        self.store.close()
        self.store = FailingCheckpointStore.in_memory()
        self.engine = SyncEngine(
            self.store,
            claude_root=self.claude,
            codex_root=self.codex,
            kimi_roots=[self.kimi],
        )
        log = self.claude / "project" / "atomic.jsonl"
        append_jsonl(log, self.claude_record("atomic", 5))
        result = self.engine.sync()
        self.assertEqual(result.files_failed, 1)
        self.assertEqual(self.store.event_count(), 0)


if __name__ == "__main__":
    unittest.main()
