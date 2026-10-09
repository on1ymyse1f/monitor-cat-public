"""Windows quota sources matching the macOS app's privacy contract.

Local application state is opened read-only.  Opt-in HTTP paths use only an
already-current access token or plaintext app cookie, never follow redirects,
never refresh credentials, and never persist credential material.
"""

from __future__ import annotations

import base64
import json
import math
import os
import re
import sqlite3
import urllib.error
import urllib.request
from urllib.parse import quote
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .models import QuotaWindow


MINIMUM_INTERVAL = 15 * 60


class _RejectCredentialRedirects(urllib.request.HTTPRedirectHandler):
    """Turn every 30x into HTTPError so secrets cannot cross an origin."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001, ANN201
        return None


def _open_credential_request(request: urllib.request.Request):
    """Open one credential-bearing request without urllib's redirect policy."""

    opener = urllib.request.build_opener(_RejectCredentialRedirects())
    return opener.open(request, timeout=10)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_datetime(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def claude_desktop_candidates() -> list[Path]:
    home = Path.home()
    bases = [
        os.environ.get("APPDATA"),
        os.environ.get("LOCALAPPDATA"),
        str(home / "AppData" / "Roaming"),
    ]
    seen: set[str] = set()
    result: list[Path] = []
    for base in bases:
        if not base:
            continue
        path = Path(base) / "Claude" / "plan-usage-history.json"
        key = os.path.normcase(str(path))
        if key not in seen:
            seen.add(key)
            result.append(path)
    return result


def parse_claude_desktop(root: dict[str, Any], now: datetime | None = None) -> list[QuotaWindow]:
    now = now or _now()
    samples = root.get("samples")
    if not isinstance(samples, list):
        return []
    candidates = [sample for sample in samples if isinstance(sample, dict) and _number(sample.get("t")) is not None]
    if not candidates:
        return []
    latest = max(candidates, key=lambda sample: _number(sample.get("t")) or 0)
    observed = datetime.fromtimestamp((_number(latest.get("t")) or 0) / 1000, tz=timezone.utc)
    usage = latest.get("u")
    if not isinstance(usage, dict):
        return []
    windows: list[QuotaWindow] = []
    for field, identifier, label, minutes in (
        ("fh", "claude-desktop-fh", "5h", 300),
        ("sd", "claude-desktop-weekly", "weekly", 10080),
    ):
        percent = _number(usage.get(field))
        if percent is None:
            continue
        window = QuotaWindow(
            id=identifier,
            label=label,
            used_percent=max(0.0, min(100.0, percent)),
            window_minutes=minutes,
            observed_at=observed,
            plan_type="desktop",
        )
        if window.staleness(now)[0] != "expired":
            windows.append(window)
    return windows


def read_claude_desktop(now: datetime | None = None) -> list[QuotaWindow]:
    for path in claude_desktop_candidates():
        try:
            root = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            continue
        if isinstance(root, dict):
            windows = parse_claude_desktop(root, now)
            if windows:
                return windows
    return []


def claude_credentials_path() -> Path:
    configured = os.environ.get("CLAUDE_SECURESTORAGE_CONFIG_DIR")
    return Path(configured) / ".credentials.json" if configured else Path.home() / ".claude" / ".credentials.json"


def _claude_access_token(now: datetime) -> tuple[str | None, str | None]:
    try:
        root = json.loads(claude_credentials_path().read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None, "credentials unavailable"
    oauth = root.get("claudeAiOauth") if isinstance(root, dict) else None
    if not isinstance(oauth, dict):
        return None, "credentials unavailable"
    token = oauth.get("accessToken")
    if not isinstance(token, str) or not token:
        return None, "credentials unavailable"
    expiry = _number(oauth.get("expiresAt"))
    if expiry is not None and expiry > 0 and datetime.fromtimestamp(expiry / 1000, tz=timezone.utc) <= now:
        return None, "token expired"
    return token, None


def parse_claude_online(root: dict[str, Any], now: datetime | None = None) -> list[QuotaWindow]:
    now = now or _now()
    windows: list[QuotaWindow] = []
    for key, label, minutes in (
        ("five_hour", "5h", 300),
        ("seven_day", "weekly", 10080),
        ("seven_day_opus", "weekly · Opus", 10080),
        ("seven_day_sonnet", "weekly · Sonnet", 10080),
    ):
        raw = root.get(key)
        if not isinstance(raw, dict):
            continue
        utilization = _number(raw.get("utilization"))
        if utilization is None:
            continue
        windows.append(
            QuotaWindow(
                id=f"claude-{key}",
                label=label,
                used_percent=max(0.0, min(100.0, utilization)),
                window_minutes=minutes,
                observed_at=now,
                resets_at=_parse_datetime(raw.get("resets_at")),
                plan_type="oauth",
            )
        )
    return windows


def fetch_claude(now: datetime | None = None) -> tuple[list[QuotaWindow], str | None]:
    now = now or _now()
    token, error = _claude_access_token(now)
    if not token:
        return [], error
    request = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1",
        },
    )
    try:
        with _open_credential_request(request) as response:
            root = json.load(response)
    except urllib.error.HTTPError as exc:
        return [], f"HTTP {exc.code}"
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        return [], "unexpected response"
    if not isinstance(root, dict):
        return [], "unexpected response"
    windows = parse_claude_online(root, now)
    return (windows, None) if windows else ([], "unexpected response")


def kimi_credentials_path() -> Path:
    return Path.home() / ".kimi-code" / "credentials" / "kimi-code.json"


def kimi_credential_stamp() -> float | None:
    try:
        return kimi_credentials_path().stat().st_mtime
    except OSError:
        return None


def _kimi_access_token(now: datetime) -> tuple[str | None, str | None]:
    try:
        root = json.loads(kimi_credentials_path().read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None, "credentials unavailable"
    if not isinstance(root, dict):
        return None, "credentials unavailable"
    token = root.get("access_token")
    if not isinstance(token, str) or not token:
        return None, "credentials unavailable"
    expiry = _number(root.get("expires_at"))
    if expiry is not None and datetime.fromtimestamp(expiry, tz=timezone.utc) <= now:
        return None, "token expired"
    return token, None


def _percent_used(detail: dict[str, Any]) -> float | None:
    limit = _number(detail.get("limit"))
    if limit is None or limit <= 0:
        return None
    used = _number(detail.get("used"))
    if used is not None and used >= 0:
        return max(0.0, min(100.0, used / limit * 100))
    remaining = _number(detail.get("remaining"))
    if remaining is not None and 0 <= remaining <= limit:
        return (limit - remaining) / limit * 100
    return None


def _window_minutes(window: dict[str, Any]) -> int | None:
    duration = _number(window.get("duration"))
    unit = window.get("timeUnit")
    if duration is None:
        return None
    multipliers = {
        "TIME_UNIT_SECOND": 1 / 60,
        "TIME_UNIT_MINUTE": 1,
        "TIME_UNIT_HOUR": 60,
        "TIME_UNIT_DAY": 1440,
    }
    return int(duration * multipliers[unit]) if unit in multipliers else None


def parse_kimi(root: dict[str, Any], now: datetime | None = None) -> list[QuotaWindow]:
    now = now or _now()
    container = root.get("data") if isinstance(root.get("data"), dict) else root
    windows: list[QuotaWindow] = []
    for entry in container.get("limits", []) if isinstance(container.get("limits"), list) else []:
        if not isinstance(entry, dict) or not isinstance(entry.get("detail"), dict):
            continue
        percent = _percent_used(entry["detail"])
        minutes = _window_minutes(entry.get("window", {})) if isinstance(entry.get("window"), dict) else None
        if percent is None:
            continue
        minutes = minutes or 0
        windows.append(
            QuotaWindow(
                id=f"kimi-window-{minutes}",
                label=QuotaWindow.label_for_minutes(minutes) if minutes else "window",
                used_percent=percent,
                window_minutes=minutes,
                observed_at=now,
                resets_at=_parse_datetime(entry["detail"].get("resetTime")),
                plan_type=container.get("subType"),
            )
        )
    usage = container.get("usage")
    if isinstance(usage, dict):
        percent = _percent_used(usage)
        if percent is not None:
            windows.append(
                QuotaWindow(
                    id="kimi-plan",
                    label="weekly",
                    used_percent=percent,
                    window_minutes=10080,
                    observed_at=now,
                    resets_at=_parse_datetime(usage.get("resetTime")),
                    plan_type=container.get("subType"),
                )
            )
    return windows


def fetch_kimi(now: datetime | None = None) -> tuple[list[QuotaWindow], str | None]:
    now = now or _now()
    token, error = _kimi_access_token(now)
    if not token:
        return [], error
    request = urllib.request.Request(
        "https://api.kimi.com/coding/v1/usages",
        headers={"Authorization": f"Bearer {token}", "User-Agent": "kimi-code"},
    )
    try:
        with _open_credential_request(request) as response:
            root = json.load(response)
    except urllib.error.HTTPError as exc:
        return [], f"HTTP {exc.code}"
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        return [], "unexpected response"
    if not isinstance(root, dict):
        return [], "unexpected response"
    windows = parse_kimi(root, now)
    return (windows, None) if windows else ([], "unexpected response")


# Cursor ---------------------------------------------------------------------

def cursor_state_candidates() -> list[Path]:
    """Return Cursor's VS Code-style state databases without creating them."""

    candidates: list[Path] = []
    for base in (os.environ.get("APPDATA"), os.environ.get("LOCALAPPDATA")):
        if base:
            candidates.append(Path(base) / "Cursor" / "User" / "globalStorage" / "state.vscdb")
    # Portable/test installations can point directly at the state database.
    configured = os.environ.get("AIMONITOR_CURSOR_STATE_DB")
    if configured:
        candidates.insert(0, Path(configured))
    seen: set[str] = set()
    result: list[Path] = []
    for path in candidates:
        key = os.path.normcase(str(path))
        if key not in seen:
            seen.add(key)
            result.append(path)
    return result


def _cursor_access_token(path: Path) -> tuple[str | None, str | None]:
    """Read Cursor's current session from SQLite in read-only mode."""

    if not path.is_file():
        return None, "database unavailable"
    # SQLite URI paths must escape spaces and percent signs; keep drive/UNC
    # separators intact so this works for normal and portable Windows installs.
    database = f"file:{quote(path.as_posix(), safe='/:')}?mode=ro"
    try:
        connection = sqlite3.connect(database, uri=True, timeout=2)
        try:
            row = connection.execute(
                "SELECT value FROM ItemTable WHERE key=?", ("cursorAuth/accessToken",)
            ).fetchone()
        finally:
            connection.close()
    except (OSError, sqlite3.Error):
        return None, "database unavailable"
    if not row or not isinstance(row[0], str):
        return None, "credentials unavailable"
    token = row[0].strip()
    # Some Cursor builds store JSON string values in ItemTable.
    try:
        decoded = json.loads(token)
        if isinstance(decoded, str):
            token = decoded.strip()
    except json.JSONDecodeError:
        pass
    return (token, None) if token else (None, "credentials unavailable")


def _jwt_payload(token: str) -> dict[str, Any] | None:
    parts = token.split(".")
    if len(parts) < 2:
        return None
    encoded = parts[1].replace("-", "+").replace("_", "/")
    encoded += "=" * ((4 - len(encoded) % 4) % 4)
    try:
        value = base64.b64decode(encoded, validate=True)
        payload = json.loads(value)
    except (ValueError, UnicodeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def _cursor_cookie(token: str, now: datetime) -> tuple[str | None, str | None]:
    payload = _jwt_payload(token)
    subject = payload.get("sub") if payload else None
    expiry = _number(payload.get("exp")) if payload else None
    if not isinstance(subject, str) or not subject or expiry is None:
        return None, "credentials malformed"
    user_id = subject.rsplit("|", 1)[-1]
    if not user_id or not re.fullmatch(r"[A-Za-z0-9._-]+", user_id):
        return None, "credentials malformed"
    try:
        expires = datetime.fromtimestamp(expiry, tz=timezone.utc)
    except (OSError, OverflowError, ValueError):
        return None, "credentials malformed"
    if expires <= now:
        return None, "token expired"
    return f"WorkosCursorSessionToken={user_id}%3A%3A{token}", None


def parse_cursor(root: dict[str, Any], now: datetime | None = None) -> list[QuotaWindow]:
    """Parse Cursor's account usage summary into comparable quota windows."""

    now = now or _now()
    start = _parse_datetime(root.get("billingCycleStart"))
    end = _parse_datetime(root.get("billingCycleEnd"))
    minutes = max(0, int((end - start).total_seconds() / 60)) if start and end else 0
    label = QuotaWindow.label_for_minutes(minutes) if minutes else "billing cycle"
    plan_type = root.get("membershipType") if isinstance(root.get("membershipType"), str) else None
    individual = root.get("individualUsage") if isinstance(root.get("individualUsage"), dict) else {}
    plan = individual.get("plan") if isinstance(individual.get("plan"), dict) else None
    overall = individual.get("overall") if isinstance(individual.get("overall"), dict) else None
    team = root.get("teamUsage") if isinstance(root.get("teamUsage"), dict) else {}
    pooled = team.get("pooled") if isinstance(team.get("pooled"), dict) else None

    def clamp(value: float | None) -> float | None:
        return max(0.0, min(100.0, value)) if value is not None and math.isfinite(value) else None

    def ratio(detail: dict[str, Any] | None) -> float | None:
        if not detail:
            return None
        used, limit = _number(detail.get("used")), _number(detail.get("limit"))
        return clamp(used / limit * 100) if used is not None and limit and limit > 0 else None

    total = clamp(_number(plan.get("totalPercentUsed"))) if plan else None
    if total is None:
        for candidate in (ratio(plan), ratio(overall), ratio(pooled)):
            if candidate is not None:
                total = candidate
                break
    auto = clamp(_number(plan.get("autoPercentUsed"))) if plan else None
    named = clamp(_number(plan.get("apiPercentUsed"))) if plan else None
    windows: list[QuotaWindow] = []
    if total is not None:
        windows.append(QuotaWindow("cursor-plan", label, total, minutes, now, end, plan_type))
    if auto is not None:
        windows.append(QuotaWindow("cursor-auto", "Auto / Composer", auto, minutes, now, end, plan_type))
    if named is not None:
        windows.append(QuotaWindow("cursor-api", "named models", named, minutes, now, end, plan_type))
    return windows


def fetch_cursor(now: datetime | None = None) -> tuple[list[QuotaWindow], str | None]:
    now = now or _now()
    token: str | None = None
    error = "database unavailable"
    for path in cursor_state_candidates():
        token, error = _cursor_access_token(path)
        if token:
            break
    if not token:
        return [], error
    cookie, error = _cursor_cookie(token, now)
    if not cookie:
        return [], error
    request = urllib.request.Request(
        "https://cursor.com/api/usage-summary",
        headers={"Accept": "application/json", "Cookie": cookie},
    )
    try:
        with _open_credential_request(request) as response:
            root = json.load(response)
    except urllib.error.HTTPError as exc:
        return [], f"HTTP {exc.code}"
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        return [], "unexpected response"
    if not isinstance(root, dict):
        return [], "unexpected response"
    windows = parse_cursor(root, now)
    return (windows, None) if windows else ([], "unexpected response")
