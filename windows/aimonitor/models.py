"""Provider-neutral data contracts for the Windows AIMonitor core.

The core stores accounting metadata only.  Prompt and response content never
appears in these models, which keeps the same privacy boundary as the macOS
implementation and makes the objects safe to hand to the CLI or desktop UI.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field, is_dataclass
from datetime import datetime, timezone
from decimal import Decimal
from enum import Enum
from typing import Any, Iterable


def _json_value(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, Enum):
        return value.value
    if is_dataclass(value):
        return {key: _json_value(item) for key, item in asdict(value).items()}
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    return value


class Serializable:
    """Small JSON-ready adapter shared by all public dataclasses."""

    def as_dict(self) -> dict[str, Any]:
        return _json_value(self)


class Confidence(str, Enum):
    EXACT = "exact"
    ESTIMATED = "estimated"
    UNAVAILABLE = "unavailable"


@dataclass(slots=True)
class TokenBreakdown(Serializable):
    """Normalized tokens; ``reasoning`` is a subset of ``output``."""

    uncached_input: int = 0
    cached_input: int = 0
    cache_write_5m: int = 0
    cache_write_1h: int = 0
    cache_write_unspecified: int = 0
    output: int = 0
    reasoning: int = 0

    def __post_init__(self) -> None:
        for name in (
            "uncached_input",
            "cached_input",
            "cache_write_5m",
            "cache_write_1h",
            "cache_write_unspecified",
            "output",
            "reasoning",
        ):
            setattr(self, name, max(0, int(getattr(self, name))))

    @property
    def cache_write_total(self) -> int:
        return self.cache_write_5m + self.cache_write_1h + self.cache_write_unspecified

    @property
    def billable(self) -> int:
        return self.uncached_input + self.cached_input + self.cache_write_total + self.output

    def __add__(self, other: "TokenBreakdown") -> "TokenBreakdown":
        return TokenBreakdown(
            uncached_input=self.uncached_input + other.uncached_input,
            cached_input=self.cached_input + other.cached_input,
            cache_write_5m=self.cache_write_5m + other.cache_write_5m,
            cache_write_1h=self.cache_write_1h + other.cache_write_1h,
            cache_write_unspecified=self.cache_write_unspecified + other.cache_write_unspecified,
            output=self.output + other.output,
            reasoning=self.reasoning + other.reasoning,
        )

    def delta_from(self, previous: "TokenBreakdown") -> "TokenBreakdown":
        """Component-wise cumulative-counter delta, floored at zero."""

        return TokenBreakdown(
            uncached_input=max(0, self.uncached_input - previous.uncached_input),
            cached_input=max(0, self.cached_input - previous.cached_input),
            cache_write_5m=max(0, self.cache_write_5m - previous.cache_write_5m),
            cache_write_1h=max(0, self.cache_write_1h - previous.cache_write_1h),
            cache_write_unspecified=max(
                0, self.cache_write_unspecified - previous.cache_write_unspecified
            ),
            output=max(0, self.output - previous.output),
            reasoning=max(0, self.reasoning - previous.reasoning),
        )

    def indicates_reset_from(self, previous: "TokenBreakdown") -> bool:
        return (
            self.uncached_input < previous.uncached_input
            or self.cached_input < previous.cached_input
            or self.output < previous.output
        )

    @classmethod
    def sum(cls, values: Iterable["TokenBreakdown"]) -> "TokenBreakdown":
        total = cls()
        for value in values:
            total = total + value
        return total


@dataclass(slots=True)
class AIEvent(Serializable):
    id: str
    timestamp: datetime | None
    provider: str
    tokens: TokenBreakdown
    source: str = "local_log"
    application: str | None = None
    model: str | None = None
    session_id: str | None = None
    project: str | None = None
    event_type: str = "usage"
    speed: str | None = None
    cost_usd: Decimal | None = None
    confidence: Confidence = Confidence.EXACT


@dataclass(slots=True)
class QuotaWindow(Serializable):
    id: str
    label: str
    used_percent: float
    window_minutes: int
    observed_at: datetime
    resets_at: datetime | None = None
    plan_type: str | None = None

    LIVE_AGE_FRACTION = 0.05
    EXPIRED_AGE_FRACTION = 0.25

    def __post_init__(self) -> None:
        # Providers often express percentages as used/limit.  Normalizing only
        # binary floating-point dust (7.000000000000001 -> 7.0) keeps stable
        # equality/dedup keys without erasing meaningful provider precision.
        self.used_percent = round(float(self.used_percent), 12)
        self.window_minutes = max(0, int(self.window_minutes))

    @property
    def remaining_percent(self) -> float:
        return max(0.0, 100.0 - self.used_percent)

    def staleness(self, now: datetime) -> tuple[str, float]:
        age = max(0.0, (now - self.observed_at).total_seconds())
        window = self.window_minutes * 60.0
        if window <= 0:
            return ("live", age) if age <= 3600 else ("expired", age)
        if age <= window * self.LIVE_AGE_FRACTION:
            return "live", age
        if age <= window * self.EXPIRED_AGE_FRACTION:
            return "aging", age
        return "expired", age

    @staticmethod
    def label_for_minutes(minutes: int) -> str:
        fixed = {60: "1h", 300: "5h", 1440: "daily", 10080: "weekly", 43200: "monthly"}
        if minutes in fixed:
            return fixed[minutes]
        if minutes > 0 and minutes % 1440 == 0:
            return f"{minutes // 1440}d"
        if minutes > 0 and minutes % 60 == 0:
            return f"{minutes // 60}h"
        return f"{minutes}m"


@dataclass(slots=True)
class Checkpoint(Serializable):
    size: int
    offset: int
    state: str | None = None


@dataclass(slots=True)
class SyncSummary(Serializable):
    files_scanned: int = 0
    files_skipped_unchanged: int = 0
    files_failed: int = 0
    claude_events: int = 0
    codex_events: int = 0
    kimi_events: int = 0
    quota_snapshots: int = 0

    @property
    def events_written(self) -> int:
        return self.claude_events + self.codex_events + self.kimi_events


@dataclass(slots=True)
class ProviderTotals(Serializable):
    provider: str
    billable: int
    requests: int
    cost_usd: float | None
    sessions: int


@dataclass(slots=True)
class ModelTotals(Serializable):
    model: str
    provider: str
    billable: int
    requests: int
    cost_usd: float | None
    sessions: int


@dataclass(slots=True)
class TimelineEvent(Serializable):
    timestamp: datetime
    provider: str
    model: str | None
    billable: int
    project: str | None
    session_id: str | None


@dataclass(slots=True)
class ActivitySpan(Serializable):
    started_at: datetime
    ended_at: datetime
    provider: str
    model: str | None
    project: str | None
    session_id: str | None
    billable: int
    cost_usd: float | None
    events: int

    @property
    def duration_seconds(self) -> float:
        return max(0.0, (self.ended_at - self.started_at).total_seconds())


@dataclass(slots=True)
class LiveSession(Serializable):
    session_id: str
    provider: str
    model: str | None
    project: str | None
    billable: int
    recent_billable: int
    cost_usd: float | None
    tokens_per_minute: float | None
    started_at: datetime | None
    last_event_at: datetime
    clock_skew_seconds: float
    clock_disagrees: bool
    is_live: bool

    @property
    def id(self) -> str:
        return f"{self.provider}\x1f{self.session_id}"


@dataclass(slots=True)
class LiveCounters(Serializable):
    sessions: list[LiveSession] = field(default_factory=list)
    live_session_count: int = 0
    recent_billable: int = 0
    window_seconds: float = 300.0
    tokens_per_minute: float | None = None
    last_event_at: datetime | None = None
    # Stored fields, rather than properties, because the lightweight Tk adapter
    # uses dataclasses.asdict() and must retain these public interface values.
    is_live: bool = False
    hidden_sessions: int = 0
    active_session_billable: int = 0

    def __post_init__(self) -> None:
        self.finalize()

    def finalize(self) -> "LiveCounters":
        self.is_live = self.live_session_count > 0
        visible_live = sum(1 for session in self.sessions if session.is_live)
        self.hidden_sessions = max(0, self.live_session_count - visible_live)
        self.active_session_billable = self.sessions[0].billable if self.sessions else 0
        return self


@dataclass(slots=True)
class UsageShare(Serializable):
    provider: str
    billable: int
    fraction: float


@dataclass(slots=True)
class QuotaView(Serializable):
    provider: str
    window: QuotaWindow
    confirmed_at: datetime


@dataclass(slots=True)
class FlowPoint(Serializable):
    bucket: datetime
    billable: int


@dataclass(slots=True)
class DashboardData(Serializable):
    today_tokens: int
    today_active_minutes: int
    today_requests: int
    today_cost_usd: float | None
    usage_shares: list[UsageShare]
    quotas: list[QuotaView]
    flow: list[FlowPoint]
    flow_is_hourly: bool
    generated_at: datetime


@dataclass(slots=True)
class ProfileCardData(Serializable):
    provider: str
    total_billable: int
    peak_day: str | None
    peak_billable: int
    current_streak: int
    longest_streak: int
    days: list[tuple[str, int]]
