"""Thread-safe SQLite persistence and read models for the Windows app."""

from __future__ import annotations

import json
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterator, Sequence

from .models import (
    AIEvent,
    ActivitySpan,
    Checkpoint,
    Confidence,
    DashboardData,
    FlowPoint,
    LiveCounters,
    LiveSession,
    ModelTotals,
    ProviderTotals,
    QuotaView,
    QuotaWindow,
    TimelineEvent,
    TokenBreakdown,
    UsageShare,
)
from .pricing import PricingCatalog


DEFAULT_SETTINGS: dict[str, str] = {
    "appearance": "system",
    "language": "system",
    "claude_quota_optin": "false",
    "kimi_quota_optin": "false",
    "cursor_quota_optin": "false",
    "notifications_enabled": "false",
    "retention_days": "90",
    "menubar_metric": "quota",
}


def _epoch(value: datetime | None) -> float | None:
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.timestamp()


def _datetime(value: float | int | None) -> datetime | None:
    if value is None:
        return None
    return datetime.fromtimestamp(float(value), tz=timezone.utc)


class EventStore:
    """One serialized SQLite connection suitable for a long-running tray app.

    Every public read and write uses the same re-entrant lock.  The connection
    may therefore be called by the Tk main thread and a background sync thread
    without SQLite cursor interleaving.  Transactions hold that lock until the
    event rows, quota rows and checkpoint either all commit or all roll back.
    """

    QUOTA_CONFIRMATION_PREFIX = "quota_confirmed|"
    LIVE_WINDOW_SECONDS = 120.0
    DEFAULT_LIVE_LIMIT = 4

    def __init__(self, path: str | Path = ":memory:") -> None:
        self.path = str(path)
        if self.path != ":memory:" and not self.path.startswith("file:"):
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._transaction_depth = 0
        self._connection = sqlite3.connect(
            self.path,
            timeout=30,
            check_same_thread=False,
            uri=self.path.startswith("file:"),
        )
        self._connection.row_factory = sqlite3.Row
        with self._lock:
            self._connection.execute("PRAGMA busy_timeout=30000")
            if self.path != ":memory:" and "mode=memory" not in self.path:
                self._connection.execute("PRAGMA journal_mode=WAL")
                self._connection.execute("PRAGMA synchronous=NORMAL")
            self._migrate()

    @classmethod
    def in_memory(cls) -> "EventStore":
        return cls(":memory:")

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def __enter__(self) -> "EventStore":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()

    def _migrate(self) -> None:
        self._connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS events(
              id TEXT PRIMARY KEY,
              ts REAL,
              source TEXT NOT NULL,
              provider TEXT NOT NULL,
              application TEXT,
              model TEXT,
              session_id TEXT,
              project TEXT,
              event_type TEXT NOT NULL DEFAULT 'usage',
              uncached_input INTEGER NOT NULL DEFAULT 0,
              cached_input INTEGER NOT NULL DEFAULT 0,
              cache_write_5m INTEGER NOT NULL DEFAULT 0,
              cache_write_1h INTEGER NOT NULL DEFAULT 0,
              cache_write_unspecified INTEGER NOT NULL DEFAULT 0,
              output INTEGER NOT NULL DEFAULT 0,
              reasoning INTEGER NOT NULL DEFAULT 0,
              billable INTEGER NOT NULL DEFAULT 0,
              cost_usd REAL,
              confidence TEXT NOT NULL,
              speed TEXT
            );
            CREATE TABLE IF NOT EXISTS quota_snapshots(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              observed_at REAL NOT NULL,
              provider TEXT NOT NULL,
              window_id TEXT NOT NULL,
              label TEXT NOT NULL,
              used_percent REAL NOT NULL,
              window_minutes INTEGER NOT NULL,
              resets_at REAL,
              plan_type TEXT
            );
            CREATE TABLE IF NOT EXISTS checkpoints(
              path TEXT PRIMARY KEY,
              size INTEGER NOT NULL,
              offset INTEGER NOT NULL,
              state TEXT
            );
            CREATE TABLE IF NOT EXISTS settings(
              key TEXT PRIMARY KEY,
              value TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
            CREATE INDEX IF NOT EXISTS idx_events_provider_ts ON events(provider, ts);
            CREATE INDEX IF NOT EXISTS idx_events_model ON events(model);
            CREATE INDEX IF NOT EXISTS idx_events_project ON events(project);
            CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id);
            CREATE INDEX IF NOT EXISTS idx_quota_window_obs
              ON quota_snapshots(provider, window_id, observed_at);
            PRAGMA user_version=1;
            """
        )
        self._connection.commit()

    @contextmanager
    def transaction(self) -> Iterator["EventStore"]:
        """Re-entrant atomic transaction which also serializes all readers."""

        with self._lock:
            depth = self._transaction_depth
            savepoint = f"aimonitor_nested_{depth}"
            if depth == 0:
                self._connection.execute("BEGIN IMMEDIATE")
            else:
                self._connection.execute(f"SAVEPOINT {savepoint}")
            self._transaction_depth += 1
            try:
                yield self
            except BaseException:
                self._transaction_depth -= 1
                if depth == 0:
                    self._connection.rollback()
                else:
                    self._connection.execute(f"ROLLBACK TO SAVEPOINT {savepoint}")
                    self._connection.execute(f"RELEASE SAVEPOINT {savepoint}")
                raise
            else:
                self._transaction_depth -= 1
                if depth == 0:
                    self._connection.commit()
                else:
                    self._connection.execute(f"RELEASE SAVEPOINT {savepoint}")

    def _commit_if_outermost(self) -> None:
        if self._transaction_depth == 0:
            self._connection.commit()

    # Events -----------------------------------------------------------------

    def insert_event(self, event: AIEvent, *, keep_largest: bool = False) -> bool:
        values = (
            event.id,
            _epoch(event.timestamp),
            event.source,
            event.provider,
            event.application,
            event.model,
            event.session_id,
            event.project,
            event.event_type,
            event.tokens.uncached_input,
            event.tokens.cached_input,
            event.tokens.cache_write_5m,
            event.tokens.cache_write_1h,
            event.tokens.cache_write_unspecified,
            event.tokens.output,
            event.tokens.reasoning,
            event.tokens.billable,
            float(event.cost_usd) if event.cost_usd is not None else None,
            event.confidence.value,
            event.speed,
        )
        columns = """
            id,ts,source,provider,application,model,session_id,project,event_type,
            uncached_input,cached_input,cache_write_5m,cache_write_1h,
            cache_write_unspecified,output,reasoning,billable,cost_usd,confidence,speed
        """
        placeholders = ",".join("?" for _ in values)
        if keep_largest:
            conflict = """
                ON CONFLICT(id) DO UPDATE SET
                  ts=excluded.ts, source=excluded.source, provider=excluded.provider,
                  application=excluded.application, model=excluded.model,
                  session_id=excluded.session_id, project=excluded.project,
                  event_type=excluded.event_type,
                  uncached_input=excluded.uncached_input,
                  cached_input=excluded.cached_input,
                  cache_write_5m=excluded.cache_write_5m,
                  cache_write_1h=excluded.cache_write_1h,
                  cache_write_unspecified=excluded.cache_write_unspecified,
                  output=excluded.output, reasoning=excluded.reasoning,
                  billable=excluded.billable, cost_usd=excluded.cost_usd,
                  confidence=excluded.confidence, speed=excluded.speed
                WHERE excluded.billable > events.billable
            """
        else:
            conflict = "ON CONFLICT(id) DO NOTHING"
        with self._lock:
            before = self._connection.total_changes
            self._connection.execute(
                f"INSERT INTO events({columns}) VALUES({placeholders}) {conflict}", values
            )
            self._commit_if_outermost()
            return self._connection.total_changes > before

    # Compatibility alias used by thin UI/CLI adapters.
    insert = insert_event

    def attribute_missing_model(
        self, id_prefix: str, model: str, pricing: PricingCatalog
    ) -> int:
        """Backfill early Codex events after the first turn_context arrives."""

        # Event ids embed the source path. On Windows that path contains `\`,
        # which is also this LIKE expression's escape character. Escape it
        # before the wildcard characters or `C:\Users\...` silently stops
        # matching and late turn_context model names never reach early rows.
        pattern = (
            id_prefix.replace("\\", "\\\\")
            .replace("%", "\\%")
            .replace("_", "\\_")
            + "%"
        )
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT id,ts,uncached_input,cached_input,cache_write_5m,cache_write_1h,
                       cache_write_unspecified,output,reasoning,speed
                FROM events WHERE id LIKE ? ESCAPE '\\' AND model IS NULL
                """,
                (pattern,),
            ).fetchall()
            for row in rows:
                tokens = TokenBreakdown(
                    row["uncached_input"],
                    row["cached_input"],
                    row["cache_write_5m"],
                    row["cache_write_1h"],
                    row["cache_write_unspecified"],
                    row["output"],
                    row["reasoning"],
                )
                timestamp = _datetime(row["ts"])
                cost = pricing.cost(tokens, model, row["speed"], timestamp)
                self._connection.execute(
                    "UPDATE events SET model=?, cost_usd=? WHERE id=?",
                    (model, float(cost) if cost is not None else None, row["id"]),
                )
            self._commit_if_outermost()
            return len(rows)

    def event_count(self, provider: str | None = None) -> int:
        with self._lock:
            if provider is None:
                row = self._connection.execute("SELECT COUNT(*) FROM events").fetchone()
            else:
                row = self._connection.execute(
                    "SELECT COUNT(*) FROM events WHERE provider=?", (provider,)
                ).fetchone()
            return int(row[0]) if row else 0

    # Checkpoints -------------------------------------------------------------

    def checkpoint(self, path: str | Path) -> Checkpoint | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT size,offset,state FROM checkpoints WHERE path=?", (str(path),)
            ).fetchone()
            return Checkpoint(int(row[0]), int(row[1]), row[2]) if row else None

    def set_checkpoint(self, path: str | Path, checkpoint: Checkpoint) -> None:
        with self._lock:
            self._connection.execute(
                """
                INSERT INTO checkpoints(path,size,offset,state) VALUES(?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET
                  size=excluded.size,offset=excluded.offset,state=excluded.state
                """,
                (str(path), checkpoint.size, checkpoint.offset, checkpoint.state),
            )
            self._commit_if_outermost()

    # Quotas ------------------------------------------------------------------

    @classmethod
    def _confirmation_key(cls, provider: str, window_id: str) -> str:
        return f"{cls.QUOTA_CONFIRMATION_PREFIX}{provider}|{window_id}"

    def quota_confirmed_at(self, provider: str, window_id: str) -> datetime | None:
        value = self.get_setting(self._confirmation_key(provider, window_id))
        try:
            return _datetime(float(value)) if value is not None else None
        except ValueError:
            return None

    def _record_quota_confirmation(self, provider: str, quota: QuotaWindow) -> None:
        key = self._confirmation_key(provider, quota.id)
        timestamp = _epoch(quota.observed_at)
        self._connection.execute(
            """
            INSERT INTO settings(key,value) VALUES(?,?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            WHERE CAST(excluded.value AS REAL) > CAST(settings.value AS REAL)
            """,
            (key, str(timestamp)),
        )

    def insert_quota(self, provider: str, quota: QuotaWindow) -> bool:
        """Insert a chronology-aware point and always record confirmation."""

        observed = _epoch(quota.observed_at)
        with self._lock:
            previous = self._connection.execute(
                """
                SELECT used_percent FROM quota_snapshots
                WHERE provider=? AND window_id=? AND observed_at<=?
                ORDER BY observed_at DESC,id DESC LIMIT 1
                """,
                (provider, quota.id, observed),
            ).fetchone()
            following = self._connection.execute(
                """
                SELECT used_percent FROM quota_snapshots
                WHERE provider=? AND window_id=? AND observed_at>=?
                ORDER BY observed_at ASC,id ASC LIMIT 1
                """,
                (provider, quota.id, observed),
            ).fetchone()
            duplicate = (
                previous is not None and abs(float(previous[0]) - quota.used_percent) < 0.001
            ) or (following is not None and abs(float(following[0]) - quota.used_percent) < 0.001)
            if not duplicate:
                self._connection.execute(
                    """
                    INSERT INTO quota_snapshots(
                      observed_at,provider,window_id,label,used_percent,
                      window_minutes,resets_at,plan_type
                    ) VALUES(?,?,?,?,?,?,?,?)
                    """,
                    (
                        observed,
                        provider,
                        quota.id,
                        quota.label,
                        quota.used_percent,
                        quota.window_minutes,
                        _epoch(quota.resets_at),
                        quota.plan_type,
                    ),
                )
            self._record_quota_confirmation(provider, quota)
            self._commit_if_outermost()
            return not duplicate

    def latest_quotas(self) -> list[tuple[QuotaWindow, str]]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT q.* FROM quota_snapshots q
                WHERE q.id=(
                  SELECT q2.id FROM quota_snapshots q2
                  WHERE q2.provider=q.provider AND q2.window_id=q.window_id
                  ORDER BY q2.observed_at DESC,q2.id DESC LIMIT 1
                )
                """
            ).fetchall()
            return [
                (
                    QuotaWindow(
                        id=row["window_id"],
                        label=row["label"],
                        used_percent=float(row["used_percent"]),
                        window_minutes=int(row["window_minutes"]),
                        resets_at=_datetime(row["resets_at"]),
                        observed_at=_datetime(row["observed_at"]) or datetime.now(timezone.utc),
                        plan_type=row["plan_type"],
                    ),
                    row["provider"],
                )
                for row in rows
            ]

    def quota_history(self, provider: str, window_id: str) -> list[tuple[datetime, float]]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT observed_at,used_percent FROM quota_snapshots
                WHERE provider=? AND window_id=? ORDER BY observed_at,id
                """,
                (provider, window_id),
            ).fetchall()
            return [(_datetime(row[0]) or datetime.now(timezone.utc), float(row[1])) for row in rows]

    # Settings and privacy ----------------------------------------------------

    def get_setting(self, key: str, default: str | None = None) -> str | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT value FROM settings WHERE key=?", (key,)
            ).fetchone()
            if row is not None:
                return row[0]
            return DEFAULT_SETTINGS.get(key, default)

    setting = get_setting

    def set_setting(self, key: str, value: str | bool | int | None) -> None:
        normalized: str | None
        if isinstance(value, bool):
            normalized = "true" if value else "false"
        elif value is None:
            normalized = None
        else:
            normalized = str(value)
        with self._lock:
            if normalized is None:
                self._connection.execute("DELETE FROM settings WHERE key=?", (key,))
            else:
                self._connection.execute(
                    """
                    INSERT INTO settings(key,value) VALUES(?,?)
                    ON CONFLICT(key) DO UPDATE SET value=excluded.value
                    """,
                    (key, normalized),
                )
            self._commit_if_outermost()

    def settings_snapshot(self) -> dict[str, str]:
        with self._lock:
            result = dict(DEFAULT_SETTINGS)
            for row in self._connection.execute("SELECT key,value FROM settings"):
                if not str(row["key"]).startswith(self.QUOTA_CONFIRMATION_PREFIX):
                    result[row["key"]] = row["value"]
            return result

    def apply_retention(self, now: datetime | None = None) -> int:
        try:
            days = int(self.get_setting("retention_days", "90") or "90")
        except ValueError:
            days = 90
        if days <= 0:
            return 0
        instant = now or datetime.now(timezone.utc)
        cutoff = _epoch(instant - timedelta(days=days))
        with self._lock:
            before = self._connection.total_changes
            self._connection.execute(
                "DELETE FROM events WHERE ts IS NOT NULL AND ts<?", (cutoff,)
            )
            changed = self._connection.total_changes - before
            self._commit_if_outermost()
            return changed

    def delete_all_data(self) -> dict[str, int]:
        with self.transaction():
            counts = {
                "events": int(self._connection.execute("SELECT COUNT(*) FROM events").fetchone()[0]),
                "quota_snapshots": int(
                    self._connection.execute("SELECT COUNT(*) FROM quota_snapshots").fetchone()[0]
                ),
                "checkpoints": int(
                    self._connection.execute("SELECT COUNT(*) FROM checkpoints").fetchone()[0]
                ),
            }
            self._connection.execute("DELETE FROM events")
            self._connection.execute("DELETE FROM quota_snapshots")
            self._connection.execute("DELETE FROM checkpoints")
            self._connection.execute(
                "DELETE FROM settings WHERE key LIKE ?", (self.QUOTA_CONFIRMATION_PREFIX + "%",)
            )
            return counts

    # Analytics ---------------------------------------------------------------

    @staticmethod
    def _bounds(
        since: datetime | None, until: datetime | None
    ) -> tuple[str, list[float]]:
        clauses: list[str] = []
        values: list[float] = []
        if since is not None:
            clauses.append("ts>=?")
            values.append(_epoch(since) or 0.0)
        if until is not None:
            clauses.append("ts<?")
            values.append(_epoch(until) or 0.0)
        return (" WHERE ts IS NOT NULL AND " + " AND ".join(clauses), values) if clauses else ("", values)

    def totals_by_provider(
        self, since: datetime | None = None, until: datetime | None = None
    ) -> list[ProviderTotals]:
        where, values = self._bounds(since, until)
        with self._lock:
            rows = self._connection.execute(
                f"""
                SELECT provider,SUM(billable) billable,COUNT(*) requests,
                       SUM(cost_usd) cost,COUNT(DISTINCT session_id) sessions
                FROM events {where} GROUP BY provider ORDER BY billable DESC
                """,
                values,
            ).fetchall()
            return [
                ProviderTotals(
                    row["provider"],
                    int(row["billable"] or 0),
                    int(row["requests"]),
                    float(row["cost"]) if row["cost"] is not None else None,
                    int(row["sessions"]),
                )
                for row in rows
            ]

    def totals_by_model(self, since: datetime | None = None) -> list[ModelTotals]:
        values: Sequence[Any] = ((_epoch(since),) if since is not None else ())
        predicate = "AND ts>=?" if since is not None else ""
        with self._lock:
            rows = self._connection.execute(
                f"""
                SELECT COALESCE(model,'unknown') model,provider,SUM(billable) billable,
                       COUNT(*) requests,SUM(cost_usd) cost,
                       COUNT(DISTINCT session_id) sessions
                FROM events WHERE ts IS NOT NULL {predicate}
                GROUP BY model,provider ORDER BY billable DESC
                """,
                values,
            ).fetchall()
            return [
                ModelTotals(
                    row["model"],
                    row["provider"],
                    int(row["billable"] or 0),
                    int(row["requests"]),
                    float(row["cost"]) if row["cost"] is not None else None,
                    int(row["sessions"]),
                )
                for row in rows
            ]

    def token_breakdown(self, provider: str) -> TokenBreakdown | None:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT SUM(uncached_input),SUM(cached_input),SUM(cache_write_5m),
                       SUM(cache_write_1h),SUM(cache_write_unspecified),SUM(output),SUM(reasoning)
                FROM events WHERE provider=?
                """,
                (provider,),
            ).fetchone()
            if row is None or row[0] is None:
                return None
            return TokenBreakdown(*(int(value or 0) for value in row))

    def cumulative_billable(self) -> int:
        with self._lock:
            row = self._connection.execute(
                "SELECT COALESCE(SUM(billable),0) FROM events WHERE event_type='usage'"
            ).fetchone()
            return int(row[0]) if row else 0

    def _totals(self, since: datetime, until: datetime | None = None) -> sqlite3.Row:
        predicate = " AND ts<?" if until is not None else ""
        values: tuple[Any, ...] = (
            (_epoch(since), _epoch(until)) if until is not None else (_epoch(since),)
        )
        return self._connection.execute(
            f"""
            SELECT COALESCE(SUM(billable),0) billable,COUNT(*) requests,
                   SUM(cost_usd) cost,COUNT(DISTINCT session_id) sessions
            FROM events WHERE ts IS NOT NULL AND ts>=? {predicate}
            """,
            values,
        ).fetchone()

    def active_minutes(self, since: datetime, until: datetime | None = None) -> int:
        predicate = " AND ts<?" if until is not None else ""
        values = (_epoch(since), _epoch(until)) if until is not None else (_epoch(since),)
        with self._lock:
            row = self._connection.execute(
                f"""
                SELECT COUNT(DISTINCT strftime('%Y-%m-%d %H:%M',ts,'unixepoch','localtime'))
                FROM events WHERE ts IS NOT NULL AND ts>=? {predicate}
                """,
                values,
            ).fetchone()
            return int(row[0]) if row else 0

    def token_flow(
        self, since: datetime, until: datetime | None = None
    ) -> tuple[list[FlowPoint], bool]:
        end = until or datetime.now(timezone.utc)
        hourly = (end - since).total_seconds() <= 36 * 3600
        expression = (
            "strftime('%Y-%m-%d %H:00:00',ts,'unixepoch','localtime')"
            if hourly
            else "date(ts,'unixepoch','localtime')"
        )
        predicate = " AND ts<?" if until is not None else ""
        values = (_epoch(since), _epoch(until)) if until is not None else (_epoch(since),)
        with self._lock:
            rows = self._connection.execute(
                f"""
                SELECT {expression} bucket,SUM(billable) billable FROM events
                WHERE ts IS NOT NULL AND ts>=? {predicate}
                GROUP BY bucket ORDER BY bucket
                """,
                values,
            ).fetchall()
        fmt = "%Y-%m-%d %H:%M:%S" if hourly else "%Y-%m-%d"
        local_zone = datetime.now().astimezone().tzinfo
        return (
            [
                FlowPoint(
                    datetime.strptime(row["bucket"], fmt).replace(tzinfo=local_zone),
                    int(row["billable"] or 0),
                )
                for row in rows
            ],
            hourly,
        )

    def recent_events(
        self, limit: int = 300, provider: str | None = None
    ) -> list[TimelineEvent]:
        predicate = "AND provider=?" if provider is not None else ""
        values: tuple[Any, ...] = (max(0, int(limit)), provider) if provider is not None else (max(0, int(limit)),)
        with self._lock:
            rows = self._connection.execute(
                f"""
                SELECT ts,provider,model,billable,project,session_id FROM events
                WHERE ts IS NOT NULL {predicate} ORDER BY ts DESC LIMIT ?
                """,
                ((provider, max(0, int(limit))) if provider is not None else (max(0, int(limit)),)),
            ).fetchall()
            return [
                TimelineEvent(
                    _datetime(row["ts"]) or datetime.now(timezone.utc),
                    row["provider"],
                    row["model"],
                    int(row["billable"]),
                    row["project"],
                    row["session_id"],
                )
                for row in rows
            ]

    def recent_activity(
        self,
        limit: int = 60,
        provider: str | None = None,
        gap_seconds: float = 300,
        scan_limit: int = 4000,
    ) -> list[ActivitySpan]:
        predicate = "AND provider=?" if provider is not None else ""
        params = (provider, scan_limit) if provider is not None else (scan_limit,)
        with self._lock:
            rows = self._connection.execute(
                f"""
                SELECT ts,provider,model,billable,project,session_id,cost_usd FROM events
                WHERE event_type='usage' AND ts IS NOT NULL {predicate}
                ORDER BY ts DESC LIMIT ?
                """,
                params,
            ).fetchall()
        chronological = list(reversed(rows))
        spans: list[ActivitySpan] = []
        for row in chronological:
            timestamp = _datetime(row["ts"]) or datetime.now(timezone.utc)
            cost = float(row["cost_usd"]) if row["cost_usd"] is not None else None
            if (
                spans
                and spans[-1].provider == row["provider"]
                and spans[-1].session_id == row["session_id"]
                and spans[-1].model == row["model"]
                and (timestamp - spans[-1].ended_at).total_seconds() <= gap_seconds
            ):
                span = spans[-1]
                span.ended_at = timestamp
                span.billable += int(row["billable"])
                span.events += 1
                if cost is not None:
                    span.cost_usd = (span.cost_usd or 0.0) + cost
            else:
                spans.append(
                    ActivitySpan(
                        timestamp,
                        timestamp,
                        row["provider"],
                        row["model"],
                        row["project"],
                        row["session_id"],
                        int(row["billable"]),
                        cost,
                        1,
                    )
                )
        return list(reversed(spans))[: max(0, int(limit))]

    def live_counters(
        self,
        now: datetime | None = None,
        window_seconds: float = 300,
        limit: int = DEFAULT_LIVE_LIMIT,
    ) -> LiveCounters:
        instant = now or datetime.now(timezone.utc)
        window_start = instant - timedelta(seconds=window_seconds)
        live_start = instant - timedelta(seconds=self.LIVE_WINDOW_SECONDS)
        trusted_end = instant + timedelta(seconds=self.LIVE_WINDOW_SECONDS)
        row_limit = max(0, int(limit))
        result = LiveCounters(window_seconds=window_seconds)
        with self._lock:
            latest = self._connection.execute(
                """
                SELECT ts FROM events WHERE event_type='usage' AND ts IS NOT NULL
                ORDER BY ts DESC LIMIT 1
                """
            ).fetchone()
            if latest:
                result.last_event_at = _datetime(latest[0])
            burst = self._connection.execute(
                """
                SELECT COALESCE(SUM(billable),0) FROM events
                WHERE event_type='usage' AND ts BETWEEN ? AND ?
                """,
                (_epoch(window_start), _epoch(trusted_end)),
            ).fetchone()
            result.recent_billable = int(burst[0]) if burst else 0
            if result.recent_billable > 0 and window_seconds > 0:
                result.tokens_per_minute = result.recent_billable / (window_seconds / 60.0)
            count = self._connection.execute(
                """
                SELECT COUNT(*) FROM(
                  SELECT provider,session_id FROM events
                  WHERE event_type='usage' AND ts>? AND ts<=? AND session_id IS NOT NULL
                  GROUP BY provider,session_id
                )
                """,
                (_epoch(live_start), _epoch(trusted_end)),
            ).fetchone()
            result.live_session_count = int(count[0]) if count else 0

            if result.live_session_count > 0 and row_limit > 0:
                heads = self._connection.execute(
                    """
                    SELECT session_id,provider,project,MAX(ts) newest FROM events
                    WHERE event_type='usage' AND ts>? AND ts<=? AND session_id IS NOT NULL
                    GROUP BY provider,session_id ORDER BY newest DESC LIMIT ?
                    """,
                    (_epoch(live_start), _epoch(trusted_end), row_limit),
                ).fetchall()
            elif row_limit > 0:
                heads = self._connection.execute(
                    """
                    SELECT session_id,provider,project,ts newest FROM events
                    WHERE event_type='usage' AND ts IS NOT NULL AND session_id IS NOT NULL
                    ORDER BY ts DESC LIMIT 1
                    """
                ).fetchall()
            else:
                heads = []

            for head in heads:
                total = self._connection.execute(
                    """
                    SELECT COALESCE(SUM(billable),0) billable,MIN(ts) started,
                           SUM(cost_usd) cost,
                           COALESCE(SUM(CASE WHEN ts>=? AND ts<=? THEN billable ELSE 0 END),0) recent
                    FROM events WHERE event_type='usage' AND session_id=? AND provider=?
                    """,
                    (
                        _epoch(window_start),
                        _epoch(trusted_end),
                        head["session_id"],
                        head["provider"],
                    ),
                ).fetchone()
                named = self._connection.execute(
                    """
                    SELECT model FROM events WHERE event_type='usage' AND session_id=?
                      AND provider=? AND model IS NOT NULL AND billable>0
                    ORDER BY ts DESC LIMIT 1
                    """,
                    (head["session_id"], head["provider"]),
                ).fetchone()
                last = _datetime(head["newest"]) or instant
                started = _datetime(total["started"])
                recent = int(total["recent"])
                raw_skew = (last - instant).total_seconds()
                clock_disagrees = raw_skew > self.LIVE_WINDOW_SECONDS
                skew = round(raw_skew / 60.0) * 60.0 if raw_skew >= 60 else 0.0
                rate: float | None = None
                if recent > 0:
                    start = max(started or window_start, window_start)
                    end = max(instant, last)
                    span_seconds = max(60.0, (end - start).total_seconds())
                    rate = recent / (span_seconds / 60.0)
                result.sessions.append(
                    LiveSession(
                        session_id=head["session_id"],
                        provider=head["provider"],
                        model=named[0] if named else None,
                        project=head["project"],
                        billable=int(total["billable"]),
                        recent_billable=recent,
                        cost_usd=float(total["cost"]) if total["cost"] is not None else None,
                        tokens_per_minute=rate,
                        started_at=started,
                        last_event_at=last,
                        clock_skew_seconds=skew,
                        clock_disagrees=clock_disagrees,
                        is_live=(
                            not clock_disagrees
                            and max(0.0, (instant - last).total_seconds())
                            < self.LIVE_WINDOW_SECONDS
                        ),
                    )
                )
        return result.finalize()

    def daily_billable(self, provider: str) -> list[tuple[str, int]]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT date(ts,'unixepoch','localtime') day,SUM(billable) billable
                FROM events WHERE ts IS NOT NULL AND provider=?
                GROUP BY day ORDER BY day
                """,
                (provider,),
            ).fetchall()
            return [(row["day"], int(row["billable"] or 0)) for row in rows]

    def providers_present(self) -> list[str]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT provider,SUM(billable) total FROM events GROUP BY provider ORDER BY total DESC"
            ).fetchall()
            return [row["provider"] for row in rows]

    def dashboard(
        self, flow_range: str = "today", now: datetime | None = None
    ) -> DashboardData:
        # Keep all component queries on one coherent store state.  The methods
        # called below re-enter this same RLock; a background sync cannot commit
        # halfway through the dashboard snapshot.
        with self._lock:
            return self._dashboard_locked(flow_range, now)

    def _dashboard_locked(
        self, flow_range: str, now: datetime | None
    ) -> DashboardData:
        instant = now or datetime.now(timezone.utc)
        local_now = instant.astimezone()
        day_start = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
        range_start = {
            "today": day_start,
            "week": instant - timedelta(days=7),
            "7d": instant - timedelta(days=7),
            "month": instant - timedelta(days=30),
            "30d": instant - timedelta(days=30),
            "year": instant - timedelta(days=365),
            "all": datetime.fromtimestamp(0, tz=timezone.utc),
        }.get(flow_range.lower(), day_start)
        totals = self._totals(day_start)
        providers = self.totals_by_provider(day_start)
        grand = sum(item.billable for item in providers)
        shares = [
            UsageShare(item.provider, item.billable, item.billable / grand if grand else 0.0)
            for item in providers
        ]
        flow, hourly = self.token_flow(range_start)

        freshest: dict[tuple[str, str], QuotaView] = {}
        for window, provider in self.latest_quotas():
            confirmed = self.quota_confirmed_at(provider, window.id) or window.observed_at
            age = max(0.0, (instant - confirmed).total_seconds())
            span = window.window_minutes * 60.0
            expired = age > (span * QuotaWindow.EXPIRED_AGE_FRACTION if span > 0 else 1800)
            if expired or (window.resets_at is not None and window.resets_at <= instant):
                continue
            candidate = QuotaView(provider, window, confirmed)
            key = (provider, window.label)
            old = freshest.get(key)
            if old is None or candidate.confirmed_at > old.confirmed_at:
                freshest[key] = candidate
        quotas = sorted(freshest.values(), key=lambda item: item.window.used_percent, reverse=True)
        return DashboardData(
            today_tokens=int(totals["billable"]),
            today_active_minutes=self.active_minutes(day_start),
            today_requests=int(totals["requests"]),
            today_cost_usd=float(totals["cost"]) if totals["cost"] is not None else None,
            usage_shares=shares,
            quotas=quotas,
            flow=flow,
            flow_is_hourly=hourly,
            generated_at=instant,
        )

    def profile_card_data(
        self, provider: str, today: datetime | None = None
    ) -> "ProfileCardData":
        from .report import profile_card_data

        return profile_card_data(self, provider, today=today)
