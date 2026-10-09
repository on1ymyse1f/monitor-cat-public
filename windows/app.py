"""Native-feeling, local-first Windows desktop UI for AI Monitor.

Tk ships with Python and is bundled by PyInstaller, so the release does not
require a runtime installation.  The data layer remains independent from the
UI; all filesystem and SQLite work happens on one background lane.
"""

from __future__ import annotations

import html
import os
import queue
import sys
import threading
import time
import tempfile
import webbrowser
from dataclasses import asdict, is_dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Iterable

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from aimonitor.i18n import resolve_language, text
from aimonitor.paths import default_db_path
from aimonitor import quota as quota_sources
from aimonitor.store import EventStore
from aimonitor.sync import SyncEngine

try:
    from PIL import Image, ImageDraw, ImageFont, ImageTk
except ImportError:  # Source runs stay useful before build dependencies exist.
    Image = ImageDraw = ImageFont = ImageTk = None


APP_NAME = "AI Monitor"
IDLE_SECONDS = 15
LIVE_SECONDS = 2


def resource_path(relative: str) -> Path:
    root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1]))
    candidate = root / relative
    if candidate.exists():
        return candidate
    bundled = root / "Resources" / Path(relative).name
    if bundled.exists():
        return bundled
    # Source checkout: the release bundles this folder as ``assets``.
    return Path(__file__).resolve().parents[2] / "Sources" / "aimonitor-app" / "Resources" / Path(relative).name


def _plain(value: Any) -> Any:
    adapter = getattr(value, "as_dict", None)
    if callable(adapter):
        return {key: _plain(item) for key, item in adapter().items()}
    if is_dataclass(value):
        return {key: _plain(item) for key, item in asdict(value).items()}
    if isinstance(value, dict):
        return {key: _plain(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(item) for item in value]
    return value


def _get(value: Any, *names: str, default: Any = None) -> Any:
    value = _plain(value)
    if not isinstance(value, dict):
        return default
    for name in names:
        if name in value:
            return value[name]
    return default


def _dashboard_visual(value: Any) -> Any:
    """Dashboard identity without non-rendered freshness metadata."""

    plain = _plain(value)
    if not isinstance(plain, dict):
        return plain
    visible = dict(plain)
    visible.pop("generated_at", None)
    visible.pop("generatedAt", None)
    sanitized_quotas = []
    for raw_quota in visible.get("quotas", []) or []:
        if not isinstance(raw_quota, dict):
            sanitized_quotas.append(raw_quota)
            continue
        quota = dict(raw_quota)
        quota.pop("confirmed_at", None)
        quota.pop("confirmedAt", None)
        raw_window = quota.get("window")
        if isinstance(raw_window, dict):
            window = dict(raw_window)
            window.pop("observed_at", None)
            window.pop("observedAt", None)
            quota["window"] = window
        sanitized_quotas.append(quota)
    if "quotas" in visible:
        visible["quotas"] = sanitized_quotas
    return visible


def _live_visual(value: Any) -> Any:
    """Fields actually rendered by the dashboard's live-session cards."""

    plain = _plain(value)
    if not isinstance(plain, dict):
        return plain
    sessions = []
    for raw in plain.get("sessions", []) or []:
        if not isinstance(raw, dict):
            continue
        sessions.append(
            {
                key: raw.get(key)
                for key in ("session_id", "provider", "model", "project", "billable", "is_live")
            }
        )
    return {
        "is_live": plain.get("is_live"),
        "live_session_count": plain.get("live_session_count"),
        "hidden_sessions": plain.get("hidden_sessions"),
        "sessions": sessions,
    }


def compact(number: Any) -> str:
    try:
        value = int(number or 0)
    except (TypeError, ValueError):
        return "0"
    sign = "-" if value < 0 else ""
    value = abs(value)
    if value >= 1_000_000_000:
        return f"{sign}{value / 1_000_000_000:.2f}B"
    if value >= 1_000_000:
        return f"{sign}{value / 1_000_000:.2f}M"
    if value >= 1_000:
        return f"{sign}{value / 1_000:.1f}K"
    return f"{sign}{value:,}"


def duration(minutes: Any) -> str:
    try:
        count = int(minutes or 0)
    except (TypeError, ValueError):
        count = 0
    if count < 60:
        return f"{count}m"
    return f"{count // 60}h {count % 60}m"


def money(value: Any) -> str:
    if value is None:
        return "n/a"
    try:
        return f"~${float(value):.2f}"
    except (TypeError, ValueError):
        return "n/a"


def parse_time(value: Any) -> datetime | None:
    if isinstance(value, datetime):
        return value
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(value).astimezone()
        except (OSError, OverflowError, ValueError):
            return None
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone()
        except ValueError:
            return None
    return None


def _system_dark() -> bool:
    if sys.platform != "win32":
        return False
    try:
        import winreg

        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
        ) as key:
            return winreg.QueryValueEx(key, "AppsUseLightTheme")[0] == 0
    except (OSError, ImportError):
        return False


THEMES = {
    "light": {
        "window": "#F4F0E6",
        "panel": "#FFFDF7",
        "ink": "#171717",
        "muted": "#6A6862",
        "track": "#D8D2C7",
        "critical": "#171717",
        "critical_text": "#FFFDF7",
    },
    "dark": {
        "window": "#171717",
        "panel": "#242321",
        "ink": "#F4F0E6",
        "muted": "#AAA69D",
        "track": "#46433E",
        "critical": "#F4F0E6",
        "critical_text": "#171717",
    },
}


class ScrollFrame(tk.Frame):
    def __init__(self, parent: tk.Misc, colors: dict[str, str]):
        super().__init__(parent, bg=colors["window"])
        self.canvas = tk.Canvas(
            self, bg=colors["window"], highlightthickness=0, bd=0
        )
        self.scrollbar = ttk.Scrollbar(self, orient="vertical", command=self.canvas.yview)
        self.body = tk.Frame(self.canvas, bg=colors["window"])
        self._window = self.canvas.create_window((0, 0), window=self.body, anchor="nw")
        self.canvas.configure(yscrollcommand=self.scrollbar.set)
        self.canvas.pack(side="left", fill="both", expand=True)
        self.scrollbar.pack(side="right", fill="y")
        self.body.bind(
            "<Configure>",
            lambda _event: self.canvas.configure(scrollregion=self.canvas.bbox("all")),
        )
        self.canvas.bind(
            "<Configure>",
            lambda event: self.canvas.itemconfigure(self._window, width=event.width),
        )
        # Keep the binding local.  ``bind_all`` survives destroyed page frames
        # and used to accumulate one callback after every refresh.
        self.canvas.bind("<MouseWheel>", self._wheel)
        self.body.bind("<MouseWheel>", self._wheel)

    def _wheel(self, event: tk.Event) -> None:
        if self.winfo_ismapped():
            self.canvas.yview_scroll(int(-event.delta / 120), "units")


class MonitorApp:
    def __init__(self, root: tk.Tk, *, enable_tray: bool = True, auto_refresh: bool = True):
        self.root = root
        self.store = EventStore(default_db_path())
        self.engine = SyncEngine(self.store)
        self.page = self._setting("last_tab", "today")
        if self.page not in {"today", "timeline", "models", "settings"}:
            self.page = "today"
        self.language = self._setting("language", "system")
        self.appearance = self._setting("appearance", "system")
        self.colors = self._colors()
        self.dashboard: dict[str, Any] = {}
        self.live: dict[str, Any] = {}
        self.timeline: list[dict[str, Any]] = []
        self.models: list[dict[str, Any]] = []
        self.timeline_provider: str | None = None
        self.flow_range = "today"
        self._refreshing = False
        self._refresh_again = False
        self._closing = False
        self._result_queue: queue.Queue = queue.Queue()
        # pystray invokes menu callbacks on its own worker. Tcl/Tk calls,
        # including ``root.after()``, are not thread-safe on Windows, so tray
        # actions cross one plain queue and are executed by the existing
        # 100 ms main-thread poller.
        self._ui_queue: queue.Queue[Callable[[], None]] = queue.Queue()
        self._tick_id: str | None = None
        self._poll_id: str | None = None
        self._tray = None
        self._tray_thread: threading.Thread | None = None
        self._thresholds: dict[str, int] = {}
        self._quota_last_fetch = {"Claude": 0.0, "Kimi Code": 0.0, "Cursor": 0.0}
        self._kimi_credential_stamp: float | None = None
        self.quota_health: dict[str, str] = {}
        self._images: list[Any] = []

        self.root.title(APP_NAME)
        self.root.geometry(self._setting("window_geometry", "780x720"))
        self.root.minsize(620, 520)
        self.root.protocol("WM_DELETE_WINDOW", self.hide_window)
        self.root.bind("<Configure>", self._remember_geometry, add="+")
        self.root.bind("<FocusIn>", lambda _event: self.request_refresh(), add="+")
        self._build_shell()
        if enable_tray:
            self._start_tray()
        if auto_refresh:
            self._poll_id = self.root.after(100, self._poll_results)
            self.request_refresh()

    # ------------------------------------------------------------------ state

    def _setting(self, key: str, default: str = "") -> str:
        getter = getattr(self.store, "get_setting", None) or getattr(self.store, "setting", None)
        try:
            value = getter(key) if getter else None
        except Exception:
            value = None
        return str(value) if value is not None else default

    def _set_setting(self, key: str, value: Any) -> None:
        setter = getattr(self.store, "set_setting", None)
        if setter:
            try:
                setter(key, str(value))
            except Exception:
                pass

    def _colors(self) -> dict[str, str]:
        mode = self.appearance
        if mode == "system":
            mode = "dark" if _system_dark() else "light"
        return THEMES.get(mode, THEMES["light"])

    @property
    def lang(self) -> str:
        return resolve_language(self.language)

    def t(self, key: str) -> str:
        return text(key, self.language)

    def _ready_status(self) -> str:
        quota_opted_in = any(
            self._setting(f"{provider}_quota_optin", "false").lower() == "true"
            for provider in ("claude", "kimi", "cursor")
        )
        return self.t("ready_network" if quota_opted_in else "ready")

    def _remember_geometry(self, _event: tk.Event) -> None:
        if self.root.state() == "normal":
            self._set_setting("window_geometry", self.root.geometry())

    # --------------------------------------------------------------- refresh

    def request_refresh(self, *_args: Any) -> None:
        if self._closing:
            return
        if self._tick_id is not None:
            self.root.after_cancel(self._tick_id)
            self._tick_id = None
        if self._refreshing:
            self._refresh_again = True
            return
        self._refreshing = True
        self.status_var.set(self.t("refreshing"))
        requested_page = self.page
        provider = self.timeline_provider
        flow_range = self.flow_range
        window_visible = self.root.state() == "normal"

        def work() -> None:
            result: dict[str, Any] = {"page": requested_page, "error": None}
            try:
                result["sync"] = _plain(self.engine.sync())
                result["quota_health"] = self._refresh_external_quotas()
                result["dashboard"] = self._dashboard(flow_range)
                result["live"] = _plain(self.store.live_counters())
                if window_visible and requested_page == "timeline":
                    result["timeline"] = _plain(self.store.recent_events(provider=provider))
                elif window_visible and requested_page == "models":
                    result["models"] = _plain(self.store.totals_by_model())
            except Exception as error:  # The tray must survive one malformed file.
                result["error"] = f"{type(error).__name__}: {error}"
            self._result_queue.put(result)

        threading.Thread(target=work, name="aimonitor-refresh", daemon=True).start()

    def _poll_results(self) -> None:
        if self._closing:
            return
        while True:
            try:
                action = self._ui_queue.get_nowait()
            except queue.Empty:
                break
            action()
        while True:
            try:
                result = self._result_queue.get_nowait()
            except queue.Empty:
                break
            self._apply_result(result)
        self._poll_id = self.root.after(100, self._poll_results)

    def _enqueue_ui(self, action: Callable[[], None]) -> None:
        """Hand a tray-thread action to Tk's main event loop."""

        if not self._closing:
            self._ui_queue.put(action)

    def _dashboard(self, flow_range: str) -> dict[str, Any]:
        try:
            return _plain(self.store.dashboard(flow_range=flow_range))
        except TypeError:
            try:
                return _plain(self.store.dashboard(flow_range))
            except TypeError:
                return _plain(self.store.dashboard())

    def _refresh_external_quotas(self) -> dict[str, str]:
        """Refresh credential-free/local data and opted-in network data."""
        health: dict[str, str] = {}
        local_claude = quota_sources.read_claude_desktop()
        if local_claude:
            for window in local_claude:
                self.store.insert_quota("Claude", window)
            health["Claude"] = "ok · desktop cache"
        elif self._setting("claude_quota_optin", "false").lower() == "true":
            elapsed = time.monotonic() - self._quota_last_fetch["Claude"]
            if elapsed >= quota_sources.MINIMUM_INTERVAL:
                self._quota_last_fetch["Claude"] = time.monotonic()
                windows, error = quota_sources.fetch_claude()
                for window in windows:
                    self.store.insert_quota("Claude", window)
                health["Claude"] = "ok" if windows else (error or "unavailable")
            else:
                health["Claude"] = self.quota_health.get("Claude", "waiting")
        else:
            health["Claude"] = "off"

        if self._setting("kimi_quota_optin", "false").lower() == "true":
            stamp = quota_sources.kimi_credential_stamp()
            elapsed = time.monotonic() - self._quota_last_fetch["Kimi Code"]
            fresh_credential = stamp is not None and stamp != self._kimi_credential_stamp
            if fresh_credential or elapsed >= quota_sources.MINIMUM_INTERVAL:
                self._kimi_credential_stamp = stamp
                self._quota_last_fetch["Kimi Code"] = time.monotonic()
                windows, error = quota_sources.fetch_kimi()
                for window in windows:
                    self.store.insert_quota("Kimi Code", window)
                health["Kimi Code"] = "ok" if windows else (error or "unavailable")
            else:
                health["Kimi Code"] = self.quota_health.get("Kimi Code", "waiting")
        else:
            health["Kimi Code"] = "off"

        if self._setting("cursor_quota_optin", "false").lower() == "true":
            elapsed = time.monotonic() - self._quota_last_fetch["Cursor"]
            if elapsed >= quota_sources.MINIMUM_INTERVAL:
                self._quota_last_fetch["Cursor"] = time.monotonic()
                windows, error = quota_sources.fetch_cursor()
                for window in windows:
                    self.store.insert_quota("Cursor", window)
                health["Cursor"] = "ok" if windows else (error or "unavailable")
            else:
                health["Cursor"] = self.quota_health.get("Cursor", "waiting")
        else:
            health["Cursor"] = "off"
        return health

    def _apply_result(self, result: dict[str, Any]) -> None:
        self._refreshing = False
        if result.get("error"):
            self.status_var.set(result["error"])
        else:
            next_dashboard = result.get("dashboard") or self.dashboard
            next_live = result.get("live") or {}
            next_health = result.get("quota_health") or self.quota_health
            result_matches_page = result.get("page") == self.page
            visual_changed = False
            if result_matches_page and self.page == "today":
                visual_changed = (
                    _dashboard_visual(next_dashboard) != _dashboard_visual(self.dashboard)
                    or _live_visual(next_live) != _live_visual(self.live)
                )
            elif result_matches_page and self.page == "settings":
                visual_changed = next_health != self.quota_health
            self.dashboard = next_dashboard
            self.live = next_live
            self.quota_health = next_health
            if result_matches_page:
                if "timeline" in result:
                    visual_changed = visual_changed or result["timeline"] != self.timeline
                    self.timeline = result["timeline"] or []
                if "models" in result:
                    visual_changed = visual_changed or result["models"] != self.models
                    self.models = result["models"] or []
            self.status_var.set(self._ready_status())
            if visual_changed and self.root.state() == "normal":
                self.render_page()
            self._update_tray()
            self._maybe_notify()
        if self._refresh_again:
            self._refresh_again = False
            self.root.after(50, self.request_refresh)
        else:
            interval = LIVE_SECONDS if self._is_live_and_visible() else IDLE_SECONDS
            self._tick_id = self.root.after(interval * 1000, self.request_refresh)

    def _is_live_and_visible(self) -> bool:
        return bool(_get(self.live, "is_live", "isLive", default=False)) and self.root.state() == "normal"

    # --------------------------------------------------------------- shell UI

    def _build_shell(self) -> None:
        for child in self.root.winfo_children():
            child.destroy()
        self.colors = self._colors()
        c = self.colors
        self.root.configure(bg=c["window"])
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure(
            "Monitor.Treeview",
            background=c["panel"],
            fieldbackground=c["panel"],
            foreground=c["ink"],
            rowheight=28,
            borderwidth=0,
        )
        style.configure(
            "Monitor.Treeview.Heading",
            background=c["window"],
            foreground=c["muted"],
            relief="flat",
            font=("Segoe UI", 9, "bold"),
        )
        style.map("Monitor.Treeview", background=[("selected", c["track"])])
        style.configure("TCombobox", fieldbackground=c["panel"], background=c["panel"])

        header = tk.Frame(self.root, bg=c["window"])
        header.pack(fill="x", padx=24, pady=(18, 8))
        tk.Label(
            header,
            text=self.t("app_title"),
            bg=c["window"],
            fg=c["ink"],
            font=("Segoe UI", 17, "bold"),
        ).pack(side="left")
        tk.Label(
            header,
            text=datetime.now().strftime("%a, %b %d"),
            bg=c["window"],
            fg=c["muted"],
            font=("Consolas", 9),
        ).pack(side="right")

        tabs = tk.Frame(self.root, bg=c["window"])
        tabs.pack(fill="x", padx=24, pady=(0, 8))
        for key in ("today", "timeline", "models", "settings"):
            selected = self.page == key
            button = tk.Button(
                tabs,
                text=self.t(key),
                command=lambda page=key: self.show_page(page),
                bg=c["window"],
                fg=c["ink"] if selected else c["muted"],
                activebackground=c["window"],
                activeforeground=c["ink"],
                relief="flat",
                bd=0,
                padx=0,
                pady=4,
                font=("Segoe UI", 9, "bold" if selected else "normal"),
                cursor="hand2",
            )
            button.pack(side="left", padx=(0, 24))
            if selected:
                tk.Frame(tabs, bg=c["ink"], width=max(44, len(button["text"]) * 8), height=3).place(
                    in_=button, relx=0.5, rely=1.0, anchor="s"
                )

        tk.Frame(self.root, bg=c["track"], height=1).pack(fill="x")
        self.content = tk.Frame(self.root, bg=c["window"])
        self.content.pack(fill="both", expand=True)
        self.status_var = tk.StringVar(value=self._ready_status())
        tk.Label(
            self.root,
            textvariable=self.status_var,
            bg=c["window"],
            fg=c["muted"],
            font=("Segoe UI", 8),
            anchor="w",
        ).pack(fill="x", padx=24, pady=(4, 8))
        self.render_page()

    def show_page(self, page: str) -> None:
        if page == self.page:
            return
        self.page = page
        self._set_setting("last_tab", page)
        self._build_shell()
        self.request_refresh()

    def render_page(self) -> None:
        if not hasattr(self, "content"):
            return
        for child in self.content.winfo_children():
            child.destroy()
        if self.page == "today":
            self._render_dashboard()
        elif self.page == "timeline":
            self._render_timeline()
        elif self.page == "models":
            self._render_models()
        else:
            self._render_settings()

    # ------------------------------------------------------------ dashboard

    def _render_dashboard(self) -> None:
        c = self.colors
        scroll = ScrollFrame(self.content, c)
        scroll.pack(fill="both", expand=True)
        body = scroll.body
        d = self.dashboard

        hero = self._panel(body, padx=18, pady=16)
        hero.pack(fill="x", padx=22, pady=(18, 10))
        top = tk.Frame(hero, bg=c["panel"])
        top.pack(fill="x")
        tk.Label(top, text=self.t("today"), **self._label(section=True)).pack(side="left")
        self._button(top, self.t("share"), self.share_today).pack(side="right")
        tk.Label(
            hero,
            text=compact(_get(d, "today_tokens", "todayTokens", default=0)),
            bg=c["panel"],
            fg=c["ink"],
            font=("Segoe UI", 34, "bold"),
            anchor="w",
        ).pack(fill="x", pady=(8, 0))
        tk.Label(hero, text=self.t("tokens_today"), **self._label(muted=True)).pack(anchor="w")
        stats = tk.Frame(hero, bg=c["panel"])
        stats.pack(fill="x", pady=(12, 0))
        self._stat(stats, duration(_get(d, "today_active_minutes", "todayActiveMinutes", default=0)), self.t("time"))
        self._stat(stats, money(_get(d, "today_cost_usd", "todayCostUSD")), self.t("cost"))
        self._stat(stats, str(_get(d, "today_requests", "todayRequests", default=0)), self.t("requests"))

        sessions = _get(self.live, "sessions", default=[]) or []
        running = [row for row in sessions if _get(row, "is_live", "isLive", default=False)]
        if running:
            self._section(body, self.t("live"))
            for row in running:
                panel = self._panel(body, padx=14, pady=10)
                panel.pack(fill="x", padx=22, pady=4)
                title = " · ".join(
                    str(value)
                    for value in (
                        _get(row, "provider"),
                        _get(row, "model"),
                        _get(row, "project"),
                    )
                    if value
                )
                tk.Label(panel, text="● " + title, **self._label()).pack(side="left")
                tk.Label(
                    panel,
                    text=compact(_get(row, "billable", default=0)),
                    bg=c["panel"], fg=c["ink"], font=("Consolas", 10, "bold"),
                ).pack(side="right")

        quotas = _get(d, "quotas", default=[]) or []
        self._section(body, self.t("quota"))
        if not quotas:
            self._empty(body, self.t("no_quota"))
        for quota in quotas:
            self._quota_card(body, quota)

        shares = _get(d, "usage_shares", "usageShares", default=[]) or []
        self._section(body, self.t("usage"))
        if not shares:
            self._empty(body, self.t("no_data"))
        for share in shares:
            self._progress_row(
                body,
                str(_get(share, "provider", default="?")),
                float(_get(share, "fraction", default=0) or 0),
                compact(_get(share, "billable", default=0)),
            )

        self._section(body, self.t("token_flow"))
        controls = tk.Frame(body, bg=c["window"])
        controls.pack(fill="x", padx=22, pady=(0, 6))
        for value, key in (("today", "today_range"), ("week", "week_range"), ("month", "month_range"), ("year", "year_range")):
            self._choice(controls, self.t(key), self.flow_range == value, lambda chosen=value: self._set_flow(chosen)).pack(side="left", padx=(0, 10))
        self._flow_chart(body, _get(d, "flow", default=[]) or [])
        tk.Frame(body, bg=c["window"], height=18).pack()

    def _set_flow(self, value: str) -> None:
        self.flow_range = value
        self.request_refresh()

    def _quota_card(self, parent: tk.Misc, quota: Any) -> None:
        c = self.colors
        window = _get(quota, "window", default=quota)
        used = float(_get(window, "used_percent", "usedPercent", default=0) or 0)
        remaining = max(0.0, 100.0 - used)
        critical = remaining < 10
        bg = c["critical"] if critical else c["panel"]
        fg = c["critical_text"] if critical else c["ink"]
        panel = tk.Frame(parent, bg=bg, highlightbackground=c["track"], highlightthickness=1)
        panel.pack(fill="x", padx=22, pady=4)
        title = f"{_get(quota, 'provider', default='?')} · {_get(window, 'label', default='window')}"
        tk.Label(panel, text=title, bg=bg, fg=fg, font=("Segoe UI", 9, "bold")).pack(anchor="w", padx=14, pady=(11, 2))
        tk.Label(panel, text=f"{remaining:.0f}% {self.t('remaining')}", bg=bg, fg=fg, font=("Segoe UI", 23, "bold")).pack(anchor="w", padx=14)
        canvas = tk.Canvas(panel, height=7, bg=bg, highlightthickness=0)
        canvas.pack(fill="x", padx=14, pady=(6, 12))
        canvas.bind("<Configure>", lambda event, fraction=remaining / 100, color=fg: self._draw_track(event.widget, fraction, color))

    def _draw_track(self, canvas: tk.Canvas, fraction: float, color: str) -> None:
        canvas.delete("all")
        width = max(1, canvas.winfo_width())
        canvas.create_rectangle(0, 1, width, 6, fill=self.colors["track"], outline="")
        canvas.create_rectangle(0, 1, width * max(0, min(1, fraction)), 6, fill=color, outline="")

    def _progress_row(self, parent: tk.Misc, label: str, fraction: float, tail: str) -> None:
        c = self.colors
        panel = self._panel(parent, padx=14, pady=10)
        panel.pack(fill="x", padx=22, pady=3)
        tk.Label(panel, text=label, **self._label()).pack(side="left")
        tk.Label(panel, text=tail, bg=c["panel"], fg=c["muted"], font=("Consolas", 9)).pack(side="right")
        bar = tk.Canvas(panel, height=7, width=280, bg=c["panel"], highlightthickness=0)
        bar.pack(side="right", fill="x", expand=True, padx=14)
        bar.bind("<Configure>", lambda event, f=fraction: self._draw_track(event.widget, f, c["ink"]))

    def _flow_chart(self, parent: tk.Misc, rows: list[Any]) -> None:
        c = self.colors
        panel = self._panel(parent, padx=12, pady=12)
        panel.pack(fill="x", padx=22, pady=3)
        canvas = tk.Canvas(panel, height=150, bg=c["panel"], highlightthickness=0)
        canvas.pack(fill="x")

        def draw(_event: tk.Event | None = None) -> None:
            canvas.delete("all")
            values = [int(_get(row, "billable", "value", default=(row[1] if isinstance(row, (list, tuple)) and len(row) > 1 else 0)) or 0) for row in rows]
            if not values:
                canvas.create_text(8, 70, text=self.t("no_data"), anchor="w", fill=c["muted"], font=("Segoe UI", 9))
                return
            width = max(canvas.winfo_width(), 100)
            highest = max(values) or 1
            gap = 3
            bar_width = max(2, (width - gap * (len(values) - 1)) / len(values))
            for index, value in enumerate(values):
                height = 120 * value / highest
                x = index * (bar_width + gap)
                canvas.create_rectangle(x, 135 - height, x + bar_width, 135, fill=c["ink"], outline="")
        canvas.bind("<Configure>", draw)

    # -------------------------------------------------------------- timeline

    def _render_timeline(self) -> None:
        c = self.colors
        controls = tk.Frame(self.content, bg=c["window"])
        controls.pack(fill="x", padx=22, pady=14)
        providers = sorted({str(_get(row, "provider", default="")) for row in self.timeline if _get(row, "provider")})
        values = [self.t("all_providers")] + providers
        selected = self.timeline_provider or self.t("all_providers")
        combo = ttk.Combobox(controls, values=values, state="readonly", width=24)
        combo.set(selected)
        combo.pack(side="left")

        def change(_event: tk.Event) -> None:
            value = combo.get()
            self.timeline_provider = None if value == self.t("all_providers") else value
            self.request_refresh()
        combo.bind("<<ComboboxSelected>>", change)
        tree = ttk.Treeview(
            self.content,
            columns=("when", "provider", "model", "project", "tokens"),
            show="headings",
            style="Monitor.Treeview",
        )
        for name, label, width, anchor in (
            ("when", self.t("when"), 130, "w"),
            ("provider", self.t("provider"), 125, "w"),
            ("model", self.t("model"), 170, "w"),
            ("project", self.t("project"), 150, "w"),
            ("tokens", self.t("tokens"), 90, "e"),
        ):
            tree.heading(name, text=label)
            tree.column(name, width=width, anchor=anchor)
        for row in self.timeline:
            stamp = parse_time(_get(row, "timestamp", "ts"))
            tree.insert("", "end", values=(
                stamp.strftime("%Y-%m-%d %H:%M") if stamp else "—",
                _get(row, "provider", default="?"),
                _get(row, "model", default="—") or "—",
                _get(row, "project", default="—") or "—",
                compact(_get(row, "billable", default=0)),
            ))
        tree.pack(fill="both", expand=True, padx=22, pady=(0, 18))
        if not self.timeline:
            self._empty(self.content, self.t("no_data"))

    # ---------------------------------------------------------------- models

    def _render_models(self) -> None:
        c = self.colors
        priced = [float(_get(row, "cost_usd", "costUSD", default=0) or 0) for row in self.models]
        summary = self._panel(self.content, padx=16, pady=12)
        summary.pack(fill="x", padx=22, pady=16)
        tk.Label(summary, text=self.t("cost"), **self._label(section=True)).pack(side="left")
        tk.Label(summary, text=money(sum(priced)) if priced else "n/a", bg=c["panel"], fg=c["ink"], font=("Segoe UI", 18, "bold")).pack(side="right")
        tree = ttk.Treeview(
            self.content,
            columns=("model", "provider", "tokens", "requests", "cost"),
            show="headings",
            style="Monitor.Treeview",
        )
        for name, label, width, anchor in (
            ("model", self.t("model"), 230, "w"),
            ("provider", self.t("provider"), 130, "w"),
            ("tokens", self.t("tokens"), 100, "e"),
            ("requests", self.t("requests"), 90, "e"),
            ("cost", self.t("cost"), 120, "e"),
        ):
            tree.heading(name, text=label)
            tree.column(name, width=width, anchor=anchor)
        for row in self.models:
            tree.insert("", "end", values=(
                _get(row, "model", default="unknown"),
                _get(row, "provider", default="?"),
                compact(_get(row, "billable", default=0)),
                _get(row, "requests", default=0),
                money(_get(row, "cost_usd", "costUSD")) if _get(row, "cost_usd", "costUSD") is not None else self.t("unpriced"),
            ))
        tree.pack(fill="both", expand=True, padx=22, pady=(0, 18))
        if not self.models:
            self._empty(self.content, self.t("no_data"))

    # --------------------------------------------------------------- settings

    def _render_settings(self) -> None:
        c = self.colors
        scroll = ScrollFrame(self.content, c)
        scroll.pack(fill="both", expand=True)
        body = scroll.body

        self._section(body, self.t("appearance"))
        row = tk.Frame(body, bg=c["window"])
        row.pack(fill="x", padx=22)
        for value, key in (("system", "system"), ("light", "light"), ("dark", "dark")):
            self._choice(row, self.t(key), self.appearance == value, lambda chosen=value: self._set_appearance(chosen)).pack(side="left", padx=(0, 12))

        self._section(body, self.t("language"))
        row = tk.Frame(body, bg=c["window"])
        row.pack(fill="x", padx=22)
        for value, label in (("system", self.t("system")), ("en", "English"), ("zh", "中文")):
            self._choice(row, label, self.language == value, lambda chosen=value: self._set_language(chosen)).pack(side="left", padx=(0, 12))

        self._section(body, self.t("quota"))
        self._check(body, self.t("claude_quota"), "claude_quota_optin")
        self._health_note(body, "Claude")
        self._check(body, self.t("kimi_quota"), "kimi_quota_optin")
        self._health_note(body, "Kimi Code")
        self._check(body, self.t("cursor_quota"), "cursor_quota_optin")
        self._health_note(body, "Cursor")
        tk.Label(body, text=self.t("quota_detail"), wraplength=690, justify="left", **self._label(muted=True, window=True)).pack(fill="x", padx=22, pady=(2, 0))

        self._section(body, self.t("export_card"))
        providers = sorted({str(_get(row, "provider", default="")) for row in self.models if _get(row, "provider")})
        if not providers:
            try:
                providers = list(self.store.providers_present())
            except Exception:
                providers = []
        row = tk.Frame(body, bg=c["window"])
        row.pack(fill="x", padx=22)
        for provider in providers:
            self._button(row, provider, lambda selected=provider: self.export_card(selected)).pack(side="left", padx=(0, 8))

        self._section(body, self.t("collectors"))
        tk.Label(body, text=self.t("collector_detail"), wraplength=690, justify="left", **self._label(muted=True, window=True)).pack(fill="x", padx=22)

        self._section(body, self.t("retention"))
        row = tk.Frame(body, bg=c["window"])
        row.pack(fill="x", padx=22)
        current = self._setting("retention_days", "90")
        for value in ("7", "30", "90", "365", "0"):
            label = self.t("forever") if value == "0" else f"{value} {self.t('days')}"
            self._choice(row, label, current == value, lambda chosen=value: self._set_retention(chosen)).pack(side="left", padx=(0, 12))

        self._section(body, self.t("notifications"))
        self._check(body, self.t("notifications"), "notifications_enabled")

        self._section(body, self.t("delete"))
        self._button(body, self.t("delete"), self.delete_history, danger=True).pack(anchor="w", padx=22, pady=(0, 20))

    def _set_appearance(self, value: str) -> None:
        self.appearance = value
        self._set_setting("appearance", value)
        self._build_shell()

    def _set_language(self, value: str) -> None:
        self.language = value
        self._set_setting("language", value)
        self._build_shell()
        self._update_tray()

    def _set_retention(self, value: str) -> None:
        self._set_setting("retention_days", value)
        try:
            self.store.apply_retention()
        except Exception as error:
            messagebox.showerror(APP_NAME, str(error), parent=self.root)
        self.render_page()

    def _check(self, parent: tk.Misc, label: str, setting: str) -> None:
        c = self.colors
        variable = tk.BooleanVar(value=self._setting(setting, "false").lower() == "true")

        def changed() -> None:
            self._set_setting(setting, "true" if variable.get() else "false")
            self.request_refresh()

        tk.Checkbutton(
            parent,
            text=label,
            variable=variable,
            command=changed,
            bg=c["window"],
            fg=c["ink"],
            activebackground=c["window"],
            activeforeground=c["ink"],
            selectcolor=c["panel"],
            font=("Segoe UI", 9),
            bd=0,
        ).pack(anchor="w", padx=22, pady=2)

    def _health_note(self, parent: tk.Misc, provider: str) -> None:
        status = self.quota_health.get(provider)
        if status and status != "off":
            tk.Label(
                parent,
                text=f"{provider}: {status}",
                bg=self.colors["window"],
                fg=self.colors["muted"],
                font=("Segoe UI", 8),
            ).pack(anchor="w", padx=42, pady=(0, 3))

    # --------------------------------------------------------- share/export

    def _font(self, size: int, bold: bool = False):
        if ImageFont is None:
            return None
        names = [
            Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts" / ("msyhbd.ttc" if bold else "msyh.ttc"),
            Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts" / ("segoeuib.ttf" if bold else "segoeui.ttf"),
        ]
        for path in names:
            try:
                return ImageFont.truetype(str(path), size=size)
            except OSError:
                continue
        return ImageFont.load_default()

    def share_today(self) -> None:
        if Image is None:
            messagebox.showerror(APP_NAME, "Pillow is required for image export.", parent=self.root)
            return
        desktop = Path.home() / "Desktop"
        desktop.mkdir(parents=True, exist_ok=True)
        target = desktop / f"aimonitor-today-{datetime.now():%Y-%m-%d}.png"
        image = Image.new("RGB", (1200, 675), "#F4F0E6")
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle((55, 55, 1145, 620), radius=26, fill="#FFFDF7", outline="#171717", width=4)
        draw.text((95, 90), self.t("app_title"), fill="#171717", font=self._font(32, True))
        draw.text((95, 176), compact(_get(self.dashboard, "today_tokens", "todayTokens", default=0)), fill="#171717", font=self._font(92, True))
        draw.text((100, 288), self.t("tokens_today"), fill="#6A6862", font=self._font(25))
        stats = (
            f"{duration(_get(self.dashboard, 'today_active_minutes', 'todayActiveMinutes', default=0))}  {self.t('time')}   ·   "
            f"{money(_get(self.dashboard, 'today_cost_usd', 'todayCostUSD'))}   ·   "
            f"{_get(self.dashboard, 'today_requests', 'todayRequests', default=0)}  {self.t('requests')}"
        )
        draw.text((100, 370), stats, fill="#171717", font=self._font(27))
        shares = _get(self.dashboard, "usage_shares", "usageShares", default=[]) or []
        y = 450
        for share in shares[:4]:
            provider = str(_get(share, "provider", default="?"))
            fraction = float(_get(share, "fraction", default=0) or 0)
            draw.text((100, y), f"{provider}  {fraction * 100:.0f}%", fill="#171717", font=self._font(22, True))
            draw.rectangle((360, y + 5, 960, y + 23), fill="#D8D2C7")
            draw.rectangle((360, y + 5, 360 + 600 * fraction, y + 23), fill="#171717")
            y += 42
        image.save(target, format="PNG", optimize=True)
        try:
            os.startfile(target)  # type: ignore[attr-defined]
        except (AttributeError, OSError):
            webbrowser.open(target.as_uri())
        self.status_var.set(f"{self.t('share_done')}: {target}")

    def export_card(self, provider: str) -> None:
        target = filedialog.asksaveasfilename(
            parent=self.root,
            title=self.t("save_card"),
            defaultextension=".html",
            initialfile=f"aimonitor-card-{provider.lower().replace(' ', '-')}.html",
            filetypes=[("HTML", "*.html")],
        )
        if not target:
            return
        try:
            data = _plain(self.store.profile_card_data(provider))
        except Exception:
            data = {"provider": provider}
        document = self._profile_html(data, provider)
        Path(target).write_text(document, encoding="utf-8")
        webbrowser.open(Path(target).resolve().as_uri())

    def _profile_html(self, data: Any, provider: str) -> str:
        values = data if isinstance(data, dict) else {}
        days = values.get("days") if isinstance(values.get("days"), list) else []
        normalized: list[tuple[str, int]] = []
        for row in days:
            if isinstance(row, (list, tuple)) and len(row) >= 2:
                try:
                    normalized.append((str(row[0]), int(row[1])))
                except (TypeError, ValueError):
                    continue
        peak = max((value for _, value in normalized), default=1)
        cells = []
        for day, value in normalized:
            ratio = value / peak if peak else 0
            level = 0 if value <= 0 else 4 if ratio >= 0.75 else 3 if ratio >= 0.45 else 2 if ratio >= 0.2 else 1
            cells.append(
                f'<i class="l{level}" title="{html.escape(day)} · {value:,} tokens"></i>'
            )
        total = compact(values.get("total_billable", 0))
        peak_day = html.escape(str(values.get("peak_day") or "n/a"))
        peak_billable = compact(values.get("peak_billable", 0))
        current = int(values.get("current_streak", 0) or 0)
        longest = int(values.get("longest_streak", 0) or 0)
        return f"""<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>AI Monitor · {html.escape(provider)}</title>
<style>*{{box-sizing:border-box}}body{{font:15px Segoe UI,sans-serif;background:#f4f0e6;color:#171717;padding:36px}}main{{max-width:900px;margin:auto;background:#fffdf7;border:3px solid;padding:32px;box-shadow:10px 10px 0 #171717}}h1{{letter-spacing:2px;margin:0}}.by{{color:#6a6862;margin:5px 0 28px}}.stats{{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}}.stat{{border:1px solid #171717;padding:14px}}.stat b{{display:block;font-size:22px}}.heat{{display:grid;grid-template-rows:repeat(7,11px);grid-auto-flow:column;grid-auto-columns:11px;gap:3px;overflow:auto;padding:18px 0}}.heat i{{display:block;background:#e4dfd5}}.heat .l1{{background:#bbb6ad}}.heat .l2{{background:#85817a}}.heat .l3{{background:#4e4b47}}.heat .l4{{background:#171717}}small{{color:#6a6862}}</style></head><body><main>
<h1>AI MONITOR · {html.escape(provider)}</h1>
<section class="stats"><div class="stat"><b>{total}</b>tokens</div><div class="stat"><b>{current}</b>current streak</div><div class="stat"><b>{longest}</b>longest streak</div><div class="stat"><b>{peak_billable}</b>peak · {peak_day}</div></section>
<h2>ACTIVITY</h2><div class="heat">{''.join(cells)}</div><small>Generated locally. API-equivalent cost is not an invoice.</small>
</main></body></html>"""

    def delete_history(self) -> None:
        if not messagebox.askyesno(APP_NAME, self.t("delete_confirm"), parent=self.root):
            return
        try:
            self.store.delete_all_data()
            self.dashboard = {}
            self.live = {}
            self.timeline = []
            self.models = []
            self.render_page()
            messagebox.showinfo(APP_NAME, self.t("delete_done"), parent=self.root)
        except Exception as error:
            messagebox.showerror(APP_NAME, str(error), parent=self.root)

    # -------------------------------------------------------------- tray

    def _start_tray(self) -> None:
        if Image is None:
            return
        try:
            import pystray
        except ImportError:
            return
        path = resource_path("assets/menubar-cat.png")
        try:
            icon_image = Image.open(path).convert("RGBA").resize((64, 64))
        except OSError:
            icon_image = Image.new("RGBA", (64, 64), "#171717")
        self._tray = pystray.Icon("AIMonitor", icon_image, APP_NAME, pystray.Menu(self._tray_items))
        self._tray_thread = threading.Thread(target=self._tray.run, name="aimonitor-tray", daemon=True)
        self._tray_thread.start()

    def _tray_items(self) -> Iterable[Any]:
        import pystray

        MenuItem = pystray.MenuItem
        items: list[Any] = [MenuItem("AI Monitor", None, enabled=False)]
        sessions = _get(self.live, "sessions", default=[]) or []
        for row in [entry for entry in sessions if _get(entry, "is_live", "isLive", default=False)][:4]:
            label = " · ".join(str(v) for v in (_get(row, "provider"), _get(row, "model"), compact(_get(row, "billable", default=0))) if v)
            items.append(MenuItem("● " + label, None, enabled=False))
        items.append(pystray.Menu.SEPARATOR)
        items.append(MenuItem(
            f"{self.t('today')}: {compact(_get(self.dashboard, 'today_tokens', 'todayTokens', default=0))} · "
            f"{duration(_get(self.dashboard, 'today_active_minutes', 'todayActiveMinutes', default=0))} · "
            f"{money(_get(self.dashboard, 'today_cost_usd', 'todayCostUSD'))}",
            None,
            enabled=False,
        ))
        for share in (_get(self.dashboard, "usage_shares", "usageShares", default=[]) or [])[:6]:
            items.append(MenuItem(
                f"{_get(share, 'provider', default='?')} — "
                f"{float(_get(share, 'fraction', default=0) or 0) * 100:.0f}% · "
                f"{compact(_get(share, 'billable', default=0))}",
                None,
                enabled=False,
            ))
        for quota in (_get(self.dashboard, "quotas", default=[]) or [])[:6]:
            window = _get(quota, "window", default=quota)
            items.append(MenuItem(
                f"{_get(quota, 'provider', default='?')} {_get(window, 'label', default='')} — "
                f"{float(_get(window, 'used_percent', 'usedPercent', default=0) or 0):.0f}%",
                None,
                enabled=False,
            ))
        items.extend([
            pystray.Menu.SEPARATOR,
            MenuItem(self.t("open_dashboard"), lambda _icon, _item: self._enqueue_ui(self.show_window), default=True),
            MenuItem(self.t("sync_now"), lambda _icon, _item: self._enqueue_ui(self.request_refresh)),
            pystray.Menu.SEPARATOR,
            MenuItem(self.t("quit"), lambda _icon, _item: self._enqueue_ui(self.quit)),
        ])
        return tuple(items)

    def _update_tray(self) -> None:
        if self._tray is None:
            return
        quotas = _get(self.dashboard, "quotas", default=[]) or []
        if quotas:
            first = quotas[0]
            window = _get(first, "window", default=first)
            self._tray.title = f"AI Monitor · {_get(first, 'provider', default='')} {float(_get(window, 'used_percent', 'usedPercent', default=0) or 0):.0f}%"
        else:
            self._tray.title = f"AI Monitor · {compact(_get(self.dashboard, 'today_tokens', 'todayTokens', default=0))}"
        try:
            self._tray.update_menu()
        except Exception:
            pass

    def _maybe_notify(self) -> None:
        if self._setting("notifications_enabled", "false").lower() != "true":
            return
        for quota in _get(self.dashboard, "quotas", default=[]) or []:
            window = _get(quota, "window", default=quota)
            used = float(_get(window, "used_percent", "usedPercent", default=0) or 0)
            key = f"{_get(quota, 'provider', default='?')}:{_get(window, 'id', default=_get(window, 'label', default='window'))}"
            threshold = 100 if used >= 100 else 90 if used >= 90 else 80 if used >= 80 else 0
            previous = self._thresholds.get(key, 0)
            if threshold == 0:
                self._thresholds.pop(key, None)
            elif threshold > previous:
                self._thresholds[key] = threshold
                if self._tray is not None:
                    try:
                        self._tray.notify(
                            f"{_get(quota, 'provider', default='?')} · {_get(window, 'label', default='')} — {used:.0f}% used",
                            APP_NAME,
                        )
                    except Exception:
                        pass

    def hide_window(self) -> None:
        if self._tray is not None:
            self.root.withdraw()
        else:
            self.root.iconify()

    def show_window(self) -> None:
        self.root.deiconify()
        self.root.state("normal")
        self.root.lift()
        self.root.focus_force()
        self.render_page()
        self.request_refresh()

    def quit(self) -> None:
        self._closing = True
        if self._tick_id is not None:
            self.root.after_cancel(self._tick_id)
        if self._poll_id is not None:
            self.root.after_cancel(self._poll_id)
        if self._tray is not None:
            try:
                self._tray.stop()
            except Exception:
                pass
        close = getattr(self.store, "close", None)
        if close:
            try:
                close()
            except Exception:
                pass
        try:
            self.root.destroy()
        except tk.TclError:
            pass

    # -------------------------------------------------------------- widgets

    def _panel(self, parent: tk.Misc, padx: int, pady: int) -> tk.Frame:
        return tk.Frame(
            parent,
            bg=self.colors["panel"],
            padx=padx,
            pady=pady,
            highlightbackground=self.colors["track"],
            highlightthickness=1,
        )

    def _label(self, muted: bool = False, section: bool = False, window: bool = False) -> dict[str, Any]:
        return {
            "bg": self.colors["window"] if window else self.colors["panel"],
            "fg": self.colors["muted"] if muted else self.colors["ink"],
            "font": ("Segoe UI", 8 if section else 9, "bold" if section else "normal"),
        }

    def _section(self, parent: tk.Misc, title: str) -> None:
        tk.Label(
            parent,
            text=title,
            bg=self.colors["window"],
            fg=self.colors["muted"],
            font=("Segoe UI", 8, "bold"),
            anchor="w",
        ).pack(fill="x", padx=22, pady=(18, 7))

    def _empty(self, parent: tk.Misc, label: str) -> None:
        panel = self._panel(parent, padx=14, pady=12)
        panel.pack(fill="x", padx=22, pady=3)
        tk.Label(panel, text=label, **self._label(muted=True)).pack(anchor="w")

    def _stat(self, parent: tk.Misc, value: str, label: str) -> None:
        c = self.colors
        block = tk.Frame(parent, bg=c["panel"])
        block.pack(side="left", padx=(0, 24))
        tk.Label(block, text=value, bg=c["panel"], fg=c["ink"], font=("Consolas", 10, "bold")).pack(side="left")
        tk.Label(block, text=" " + label, bg=c["panel"], fg=c["muted"], font=("Segoe UI", 8)).pack(side="left")

    def _button(self, parent: tk.Misc, label: str, action: Callable, danger: bool = False) -> tk.Button:
        c = self.colors
        return tk.Button(
            parent,
            text=label,
            command=action,
            bg=c["ink"] if not danger else c["critical"],
            fg=c["window"] if not danger else c["critical_text"],
            activebackground=c["muted"],
            activeforeground=c["window"],
            relief="flat",
            bd=0,
            padx=11,
            pady=6,
            font=("Segoe UI", 8, "bold"),
            cursor="hand2",
        )

    def _choice(self, parent: tk.Misc, label: str, selected: bool, action: Callable) -> tk.Button:
        c = self.colors
        return tk.Button(
            parent,
            text=label,
            command=action,
            bg=c["ink"] if selected else c["panel"],
            fg=c["window"] if selected else c["muted"],
            activebackground=c["ink"],
            activeforeground=c["window"],
            relief="flat",
            bd=0,
            padx=10,
            pady=5,
            font=("Segoe UI", 8, "bold" if selected else "normal"),
            cursor="hand2",
        )


def run() -> int:
    root = tk.Tk()
    app = MonitorApp(root)
    try:
        root.mainloop()
    finally:
        if not app._closing:
            app.quit()
    return 0


def run_ui_smoke() -> bool:
    """Construct and lay out every page without touching the real user store."""
    try:
        with tempfile.TemporaryDirectory(prefix="aimonitor-ui-smoke-") as temporary:
            root_dir = Path(temporary)
            old = {
                name: os.environ.get(name)
                for name in (
                    "AIMONITOR_DATA_DIR",
                    "AIMONITOR_CLAUDE_ROOT",
                    "AIMONITOR_CODEX_ROOT",
                    "AIMONITOR_KIMI_ROOT",
                )
            }
            os.environ["AIMONITOR_DATA_DIR"] = str(root_dir / "data")
            os.environ["AIMONITOR_CLAUDE_ROOT"] = str(root_dir / "claude")
            os.environ["AIMONITOR_CODEX_ROOT"] = str(root_dir / "codex")
            os.environ["AIMONITOR_KIMI_ROOT"] = str(root_dir / "kimi")
            root = tk.Tk()
            root.withdraw()
            app = MonitorApp(root, enable_tray=False, auto_refresh=False)
            for page in ("today", "timeline", "models", "settings"):
                app.page = page
                app._build_shell()
                root.update_idletasks()
            app.quit()
            for name, value in old.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value
        return True
    except Exception:
        return False
