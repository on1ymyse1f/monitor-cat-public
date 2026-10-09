"""Read-only presentation interfaces shared by the Windows CLI and GUI."""

from __future__ import annotations

import html
import json
from datetime import date, datetime, timedelta, timezone
from typing import Any

from .models import DashboardData, LiveCounters, ModelTotals, ProfileCardData
from .store import EventStore


def dashboard_data(
    store: EventStore, flow_range: str = "today", now: datetime | None = None
) -> DashboardData:
    return store.dashboard(flow_range=flow_range, now=now)


def timeline_data(
    store: EventStore,
    *,
    provider: str | None = None,
    limit: int = 300,
    grouped: bool = False,
) -> list[Any]:
    if grouped:
        return store.recent_activity(limit=limit, provider=provider)
    return store.recent_events(limit=limit, provider=provider)


def models_data(store: EventStore, since: datetime | None = None) -> list[ModelTotals]:
    return store.totals_by_model(since=since)


def live_data(
    store: EventStore,
    *,
    now: datetime | None = None,
    window_seconds: float = 300,
    limit: int = EventStore.DEFAULT_LIVE_LIMIT,
) -> LiveCounters:
    return store.live_counters(now=now, window_seconds=window_seconds, limit=limit)


def profile_card_data(
    store: EventStore, provider: str, *, today: datetime | None = None
) -> ProfileCardData:
    days = store.daily_billable(provider)
    active = {date.fromisoformat(day) for day, billable in days if billable > 0}
    today_day = (today or datetime.now().astimezone()).astimezone().date()

    current = 0
    cursor = today_day
    while cursor in active:
        current += 1
        cursor -= timedelta(days=1)

    longest = 0
    run = 0
    previous: date | None = None
    for day in sorted(active):
        run = run + 1 if previous is not None and day == previous + timedelta(days=1) else 1
        longest = max(longest, run)
        previous = day

    peak_day: str | None = None
    peak_billable = 0
    for day, billable in days:
        if billable > peak_billable:
            peak_day, peak_billable = day, billable
    return ProfileCardData(
        provider=provider,
        total_billable=sum(billable for _, billable in days),
        peak_day=peak_day,
        peak_billable=peak_billable,
        current_streak=current,
        longest_streak=longest,
        days=days,
    )


def compact_tokens(value: int, language: str = "en") -> str:
    def trimmed(number: float) -> str:
        return f"{number:.1f}".removesuffix(".0")

    if language.lower().startswith("zh"):
        if value >= 100_000_000:
            return trimmed(value / 100_000_000) + "亿"
        if value >= 10_000:
            return trimmed(value / 10_000) + "万"
        return str(value)
    if value >= 1_000_000_000:
        return trimmed(value / 1_000_000_000) + "B"
    if value >= 1_000_000:
        return trimmed(value / 1_000_000) + "M"
    if value >= 1_000:
        return trimmed(value / 1_000) + "k"
    return str(value)


def profile_card_html(
    data: ProfileCardData,
    *,
    name: str = "AI Monitor",
    handle: str = "local",
    language: str = "en",
    weeks: int = 26,
    generated_at: datetime | None = None,
) -> str:
    """Render a self-contained offline HTML card from accounting-only data."""

    zh = language.lower().startswith("zh")
    today = (generated_at or datetime.now().astimezone()).astimezone().date()
    week_start = today - timedelta(days=today.weekday())
    first = week_start - timedelta(weeks=max(0, weeks - 1))
    daily = {date.fromisoformat(day): billable for day, billable in data.days}
    peak = max(data.peak_billable, 1)
    cells: list[str] = []
    for row in range(7):
        row_cells: list[str] = []
        for column in range(max(1, weeks)):
            day = first + timedelta(days=column * 7 + row)
            value = 0 if day > today else daily.get(day, 0)
            level = 0 if value == 0 else min(4, 1 + int(3 * value / peak))
            title = html.escape(f"{day.isoformat()} · {compact_tokens(value, language)}")
            row_cells.append(f'<span class="c l{level}" title="{title}"></span>')
        cells.append('<div class="row">' + "".join(row_cells) + "</div>")

    initials = "".join(part[:1] for part in name.split()).upper()[:2] or "AI"
    unit = " 天" if zh else " d"
    labels = (
        ("累计 Token", "峰值日", "当前连续天数", "最长连续使用")
        if zh
        else ("Total tokens", "Peak day", "Current streak", "Longest streak")
    )
    values = (
        compact_tokens(data.total_billable, language),
        compact_tokens(data.peak_billable, language),
        f"{data.current_streak}{unit}",
        f"{data.longest_streak}{unit}",
    )
    stats = "".join(
        f'<div class="stat"><div class="v">{html.escape(value)}</div>'
        f'<div class="k">{html.escape(label)}</div></div>'
        for value, label in zip(values, labels)
    )
    return f"""<!doctype html>
<html lang="{'zh-CN' if zh else 'en'}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(data.provider)} · AI Monitor</title>
<style>
body{{background:#1b1e2b;color:#e8eaf2;padding:40px;font:14px/1.5 "Segoe UI",sans-serif;max-width:1000px;margin:auto}}
header{{display:flex;align-items:center;gap:18px;margin-bottom:32px}}.avatar{{width:80px;height:80px;border-radius:50%;background:#35c08d;display:grid;place-items:center;font-size:28px;font-weight:700}}
.brand{{margin-left:auto;color:#8b91a7;font-size:22px}}.grid{{display:flex;flex-direction:column;gap:5px;overflow-x:auto;margin-bottom:34px}}.row{{display:flex;gap:5px}}
.c{{width:23px;height:23px;border-radius:5px;background:#262a3b;flex:none}}.l1{{background:#2d3a5c}}.l2{{background:#3b579a}}.l3{{background:#4a6fc5}}.l4{{background:#6e9bff}}
footer{{display:flex;gap:30px;border-top:1px solid #2e3347;padding-top:24px}}.stat{{flex:1}}.v{{font-size:28px;font-weight:700}}.k,p{{color:#8b91a7}}
</style></head><body><header><div class="avatar">{html.escape(initials)}</div>
<div><h1>{html.escape(name)}</h1><p>@{html.escape(handle)}</p></div>
<div class="brand">{html.escape(data.provider)}</div></header>
<div class="grid">{''.join(cells)}</div><footer>{stats}</footer></body></html>"""


def snapshot_json(
    store: EventStore, *, flow_range: str = "today", now: datetime | None = None
) -> str:
    """Stable JSON handoff for CLI diagnostics and golden fixtures."""

    payload = {
        "dashboard": dashboard_data(store, flow_range, now).as_dict(),
        "models": [item.as_dict() for item in models_data(store)],
        "timeline": [item.as_dict() for item in timeline_data(store)],
        "live": live_data(store, now=now).as_dict(),
        "settings": store.settings_snapshot(),
    }
    return json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)

