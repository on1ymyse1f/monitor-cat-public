"""Streaming, content-blind parsers for Claude Code, Codex and Kimi logs."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

from .models import AIEvent, Confidence, QuotaWindow, TokenBreakdown
from .pricing import PricingCatalog


CLAUDE_PROVIDER = "Claude Code"
CODEX_PROVIDER = "Codex CLI"
KIMI_PROVIDER = "Kimi Code"


def _mapping(value: Any) -> dict[str, Any] | None:
    return value if isinstance(value, dict) else None


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError, OverflowError):
        return None


def _integer(value: Any) -> int | None:
    number = _number(value)
    return int(number) if number is not None else None


def parse_timestamp(value: Any) -> datetime | None:
    """Parse RFC3339, epoch seconds or epoch milliseconds as aware UTC."""

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        seconds = float(value)
        if abs(seconds) > 100_000_000_000:
            seconds /= 1000.0
        try:
            return datetime.fromtimestamp(seconds, tz=timezone.utc)
        except (OSError, OverflowError, ValueError):
            return None
    if not isinstance(value, str) or not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def scan_jsonl(
    path: Path,
    *,
    start: int = 0,
    stop: int | None = None,
    needles: Iterable[bytes] = (),
    handler: Callable[[dict[str, Any], int, int], None],
) -> int:
    """Stream a JSONL byte range and return a safe checkpoint boundary.

    Malformed complete lines are ignored.  A malformed unterminated tail is
    *not* checkpointed so that the provider can finish writing it later.
    """

    byte_needles = tuple(needles)
    with path.open("rb") as handle:
        handle.seek(max(0, start))
        boundary = handle.tell()
        file_stop = path.stat().st_size if stop is None else max(0, stop)
        while handle.tell() < file_stop:
            line_start = handle.tell()
            raw = handle.readline(file_stop - line_start)
            if not raw:
                break
            line_end = handle.tell()
            complete = raw.endswith(b"\n")
            content = raw[:-1] if complete else raw
            if content.endswith(b"\r"):
                content = content[:-1]
            selected = not byte_needles or any(needle in content for needle in byte_needles)
            parsed: dict[str, Any] | None = None
            # Complete non-accounting lines can take the cheap needle path.
            # An unterminated tail must still be decoded before checkpointing:
            # a line which does not contain the needle *yet* may acquire it
            # when the provider finishes the same JSON object on the next sync.
            if content and (selected or not complete):
                try:
                    candidate = json.loads(content)
                    if isinstance(candidate, dict):
                        parsed = candidate
                except (UnicodeDecodeError, json.JSONDecodeError):
                    parsed = None
            if parsed is not None and selected:
                handler(parsed, line_start, line_end)
            if complete or parsed is not None:
                boundary = line_end
            else:
                # Incomplete JSON tail.  Resume at its first byte after append.
                boundary = line_start
                break
        return boundary


def claude_tokens(usage: dict[str, Any]) -> TokenBreakdown:
    tokens = TokenBreakdown(
        uncached_input=_integer(usage.get("input_tokens")) or 0,
        cached_input=_integer(usage.get("cache_read_input_tokens")) or 0,
        output=_integer(usage.get("output_tokens")) or 0,
        reasoning=_integer((_mapping(usage.get("output_tokens_details")) or {}).get("thinking_tokens"))
        or 0,
    )
    creation = _mapping(usage.get("cache_creation"))
    flat = _integer(usage.get("cache_creation_input_tokens")) or 0
    if creation is not None:
        tokens.cache_write_1h = _integer(creation.get("ephemeral_1h_input_tokens")) or 0
        tokens.cache_write_5m = _integer(creation.get("ephemeral_5m_input_tokens")) or 0
        split = tokens.cache_write_1h + tokens.cache_write_5m
        tokens.cache_write_unspecified = max(0, flat - split)
    else:
        tokens.cache_write_unspecified = flat
    return tokens


def claude_project_name(path: Path, root: Path) -> str | None:
    try:
        slug = path.relative_to(root).parts[0]
    except (ValueError, IndexError):
        return None
    slug = re.sub(r"^-[^-]*-[^-]*-", "", slug)
    return slug or None


def parse_claude_event(
    obj: dict[str, Any],
    *,
    path: Path,
    line_start: int,
    root: Path,
    pricing: PricingCatalog,
) -> AIEvent | None:
    message = _mapping(obj.get("message"))
    usage = _mapping(message.get("usage")) if message else None
    if message is None or usage is None or obj.get("isApiErrorMessage") is True:
        return None
    tokens = claude_tokens(usage)
    request_id = _string(obj.get("requestId"))
    message_id = _string(message.get("id"))
    identity = request_id or (f"msg:{message_id}" if message_id else f"pos:{path.name}@{line_start}")
    timestamp = parse_timestamp(obj.get("timestamp"))
    model = _string(message.get("model")) or "unknown"
    speed = _string(usage.get("speed"))
    return AIEvent(
        id=f"claude:{identity}",
        timestamp=timestamp,
        provider=CLAUDE_PROVIDER,
        application="Claude Code",
        model=model,
        session_id=_string(obj.get("sessionId")),
        project=claude_project_name(path, root),
        speed=speed,
        tokens=tokens,
        cost_usd=pricing.cost(tokens, model, speed, timestamp),
        confidence=Confidence.ESTIMATED,
    )


def codex_tokens(usage: dict[str, Any]) -> TokenBreakdown:
    inclusive_input = _integer(usage.get("input_tokens")) or 0
    cached = _integer(usage.get("cached_input_tokens")) or 0
    return TokenBreakdown(
        uncached_input=max(0, inclusive_input - cached),
        cached_input=cached,
        cache_write_unspecified=_integer(usage.get("cache_write_input_tokens")) or 0,
        output=_integer(usage.get("output_tokens")) or 0,
        reasoning=_integer(usage.get("reasoning_output_tokens")) or 0,
    )


@dataclass(frozen=True, slots=True)
class CodexSessionMeta:
    thread_id: str | None = None
    session_id: str | None = None
    cwd: str | None = None
    inherits_parent_counter: bool = False


def codex_session_meta(path: Path) -> CodexSessionMeta:
    try:
        with path.open("rb") as handle:
            first = handle.readline(1 << 16)
        root = json.loads(first)
        payload = _mapping(root.get("payload")) or {}
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, AttributeError):
        return CodexSessionMeta()
    thread_id = _string(payload.get("id"))
    return CodexSessionMeta(
        thread_id=thread_id,
        session_id=_string(payload.get("session_id")) or thread_id,
        cwd=_string(payload.get("cwd")),
        inherits_parent_counter=(
            payload.get("forked_from_id") is not None
            or payload.get("parent_thread_id") is not None
            or payload.get("thread_source") == "subagent"
        ),
    )


def parse_codex_quota_windows(
    rate_limits: dict[str, Any], observed_at: datetime
) -> list[QuotaWindow]:
    plan_type = _string(rate_limits.get("plan_type"))
    limit_id = _string(rate_limits.get("limit_id")) or "codex"
    output: list[QuotaWindow] = []
    for slot, suffix in (("primary", ""), ("secondary", "-secondary")):
        window = _mapping(rate_limits.get(slot))
        if window is None:
            continue
        used = _number(window.get("used_percent"))
        minutes = _integer(window.get("window_minutes"))
        if used is None or minutes is None:
            continue
        reset_epoch = _number(window.get("resets_at"))
        reset = parse_timestamp(reset_epoch) if reset_epoch is not None else None
        label = QuotaWindow.label_for_minutes(minutes)
        if slot == "secondary":
            label += " · secondary"
        output.append(
            QuotaWindow(
                id=limit_id + suffix,
                label=label,
                used_percent=used,
                window_minutes=minutes,
                resets_at=reset,
                observed_at=observed_at,
                plan_type=plan_type,
            )
        )
    return output


def kimi_tokens(obj: dict[str, Any]) -> TokenBreakdown | None:
    scope = _string(obj.get("usageScope"))
    if scope is not None and scope != "turn":
        return None
    usage = _mapping(obj.get("usage"))
    if usage is None:
        return None
    return TokenBreakdown(
        uncached_input=_integer(usage.get("inputOther")) or 0,
        cached_input=_integer(usage.get("inputCacheRead")) or 0,
        cache_write_unspecified=_integer(usage.get("inputCacheCreation")) or 0,
        output=_integer(usage.get("output")) or 0,
    )


def kimi_session_id(path: Path) -> str | None:
    return next(
        (
            part
            for part in reversed(path.parts)
            if part.startswith(("session_", "conv-", "ctitle-"))
        ),
        None,
    )


def kimi_session_index(root: Path) -> dict[str, str]:
    index_path = root.parent / "session_index.jsonl"
    result: dict[str, str] = {}
    if not index_path.is_file():
        return result

    def accept(obj: dict[str, Any], _start: int, _end: int) -> None:
        session_id = _string(obj.get("sessionId"))
        work_dir = _string(obj.get("workDir"))
        if session_id and work_dir:
            result[session_id] = work_dir

    scan_jsonl(index_path, handler=accept)
    return result


def kimi_project_name(path: Path, root: Path, index: dict[str, str]) -> str | None:
    session_id = kimi_session_id(path)
    if session_id and session_id in index:
        normalized = index[session_id].replace("\\", "/").rstrip("/")
        return normalized.rsplit("/", 1)[-1] or None
    try:
        slug = path.relative_to(root).parts[0]
    except (ValueError, IndexError):
        return None
    slug = slug.removeprefix("wd_")
    slug = re.sub(r"_[0-9a-f]{6,}$", "", slug)
    return slug or None


def parse_kimi_event(
    obj: dict[str, Any], *, path: Path, line_start: int, root: Path, index: dict[str, str]
) -> AIEvent | None:
    if obj.get("type") != "usage.record":
        return None
    tokens = kimi_tokens(obj)
    if tokens is None or tokens.billable <= 0:
        return None
    session_id = kimi_session_id(path)
    identity = session_id or path.parent.name
    return AIEvent(
        id=f"kimi:{identity}@{line_start}",
        timestamp=parse_timestamp(obj.get("time")),
        provider=KIMI_PROVIDER,
        application="Kimi Code",
        model=_string(obj.get("model")),
        session_id=session_id,
        project=kimi_project_name(path, root, index),
        tokens=tokens,
        cost_usd=None,
        confidence=Confidence.EXACT,
    )


def parse_claude_quota_windows(
    root: dict[str, Any], observed_at: datetime
) -> list[QuotaWindow]:
    output: list[QuotaWindow] = []
    shapes = (
        ("five_hour", "5h", 300),
        ("seven_day", "weekly", 10080),
        ("seven_day_opus", "weekly · Opus", 10080),
        ("seven_day_sonnet", "weekly · Sonnet", 10080),
    )
    for key, label, minutes in shapes:
        window = _mapping(root.get(key))
        utilization = _number(window.get("utilization")) if window else None
        if window is None or utilization is None:
            continue
        output.append(
            QuotaWindow(
                id=f"claude-{key}",
                label=label,
                used_percent=utilization,
                window_minutes=minutes,
                resets_at=parse_timestamp(window.get("resets_at")),
                observed_at=observed_at,
                plan_type="oauth",
            )
        )
    return output


def _kimi_percent(detail: dict[str, Any]) -> float | None:
    limit = _number(detail.get("limit"))
    if limit is None or limit <= 0:
        return None
    used = _number(detail.get("used"))
    if used is not None and used >= 0:
        return min(100.0, max(0.0, used / limit * 100.0))
    remaining = _number(detail.get("remaining"))
    if remaining is not None and 0 <= remaining <= limit:
        return (limit - remaining) / limit * 100.0
    return None


def _kimi_window_minutes(window: dict[str, Any]) -> int | None:
    duration = _integer(window.get("duration"))
    if duration is None:
        return None
    unit = window.get("timeUnit")
    if unit == "TIME_UNIT_MINUTE":
        return duration
    if unit == "TIME_UNIT_HOUR":
        return duration * 60
    if unit == "TIME_UNIT_DAY":
        return duration * 1440
    if unit == "TIME_UNIT_SECOND":
        return duration // 60
    return None


def normalize_kimi_web_quota(root: dict[str, Any]) -> dict[str, Any]:
    usages = root.get("usages")
    if not isinstance(usages, list):
        return root
    coding = next(
        (item for item in usages if isinstance(item, dict) and item.get("scope") == "FEATURE_CODING"),
        None,
    )
    if not isinstance(coding, dict) or not isinstance(coding.get("detail"), dict):
        return root
    normalized: dict[str, Any] = {"usage": coding["detail"]}
    if isinstance(coding.get("limits"), list):
        normalized["limits"] = coding["limits"]
    return normalized


def parse_kimi_quota_windows(
    root: dict[str, Any], observed_at: datetime
) -> list[QuotaWindow]:
    container = _mapping(root.get("data")) or root
    plan_type = _string(container.get("subType"))
    output: list[QuotaWindow] = []
    limits = container.get("limits")
    if isinstance(limits, list):
        for entry in limits:
            if not isinstance(entry, dict):
                continue
            detail = _mapping(entry.get("detail"))
            percent = _kimi_percent(detail) if detail else None
            if detail is None or percent is None:
                continue
            window = _mapping(entry.get("window")) or {}
            minutes = _kimi_window_minutes(window) or 0
            output.append(
                QuotaWindow(
                    id=f"kimi-window-{minutes}",
                    label=QuotaWindow.label_for_minutes(minutes) if minutes else "window",
                    used_percent=percent,
                    window_minutes=minutes,
                    resets_at=parse_timestamp(detail.get("resetTime")),
                    observed_at=observed_at,
                    plan_type=plan_type,
                )
            )
    usage = _mapping(container.get("usage"))
    plan_percent = _kimi_percent(usage) if usage else None
    if usage is not None and plan_percent is not None:
        output.append(
            QuotaWindow(
                id="kimi-plan",
                label="weekly",
                used_percent=plan_percent,
                window_minutes=10080,
                resets_at=parse_timestamp(usage.get("resetTime")),
                observed_at=observed_at,
                plan_type=plan_type,
            )
        )
    return output


def claude_files(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("*.jsonl") if path.is_file()) if root.is_dir() else []


def codex_files(root: Path) -> list[Path]:
    return (
        sorted(path for path in root.rglob("rollout-*.jsonl") if path.is_file())
        if root.is_dir()
        else []
    )


def kimi_files(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("wire.jsonl") if path.is_file()) if root.is_dir() else []
