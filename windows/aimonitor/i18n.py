"""Small, dependency-free English/Chinese localization table for the GUI."""

from __future__ import annotations

import locale
import os


_TEXT = {
    "app_title": ("AI MONITOR", "AI 监控站"),
    "today": ("TODAY", "今天"),
    "timeline": ("TIMELINE", "时间线"),
    "models": ("MODELS", "模型"),
    "settings": ("SETTINGS", "设置"),
    "tokens_today": ("tokens today", "今日 Token"),
    "time": ("time", "时间"),
    "cost": ("API-equivalent cost", "API 等价成本"),
    "requests": ("requests", "请求"),
    "quota": ("QUOTA", "额度"),
    "usage": ("USAGE", "使用占比"),
    "token_flow": ("TOKEN FLOW", "TOKEN 流量"),
    "no_data": ("No usage data yet.", "暂无使用数据。"),
    "no_quota": ("No current quota data.", "暂无可用额度数据。"),
    "remaining": ("remaining", "剩余"),
    "all_providers": ("All providers", "全部提供商"),
    "provider": ("Provider", "提供商"),
    "model": ("Model", "模型"),
    "project": ("Project", "项目"),
    "tokens": ("Tokens", "Token"),
    "when": ("When", "时间"),
    "appearance": ("APPEARANCE", "外观"),
    "system": ("System", "跟随系统"),
    "light": ("Light", "浅色"),
    "dark": ("Dark", "深色"),
    "language": ("LANGUAGE", "语言"),
    "claude_quota": ("Claude online quota (opt-in)", "Claude 在线额度（选择加入）"),
    "kimi_quota": ("Kimi online quota (opt-in)", "Kimi 在线额度（选择加入）"),
    "cursor_quota": ("Cursor account quota (opt-in)", "Cursor 账户额度（选择加入）"),
    "quota_detail": (
        "Quota requests are optional. Kimi may refresh when its credential changes.",
        "在线额度查询为可选；Kimi 凭据更新时可能立即刷新。",
    ),
    "export_card": ("EXPORT PROFILE CARD", "导出档案卡"),
    "collectors": ("COLLECTORS & STORAGE", "采集器与存储"),
    "collector_detail": (
        "Indexes selected accounting fields from Claude Code, Codex CLI and Kimi Code logs. "
        "Prompt and response text is not stored.",
        "仅索引 Claude Code、Codex CLI 与 Kimi Code 日志中的计量字段；提示词和回复不会入库。",
    ),
    "retention": ("RETENTION", "数据保留"),
    "days": ("days", "天"),
    "forever": ("Forever", "永久"),
    "notifications": ("Quota notifications", "额度通知"),
    "delete": ("DELETE LOCAL HISTORY", "删除本地历史"),
    "delete_confirm": ("Delete all locally indexed usage and quota history?", "删除全部本地索引的用量与额度历史？"),
    "delete_done": ("Local history deleted.", "本地历史已删除。"),
    "share": ("SHARE TODAY", "分享今日"),
    "share_done": ("Saved to Desktop", "已保存到桌面"),
    "open_dashboard": ("Open dashboard", "打开仪表盘"),
    "sync_now": ("Sync now", "立即同步"),
    "quit": ("Quit", "退出"),
    "live": ("LIVE", "实时"),
    "more_sessions": ("more sessions running", "个其他会话正在运行"),
    "unpriced": ("unpriced", "未定价"),
    "today_range": ("Today", "今天"),
    "week_range": ("7 days", "7 天"),
    "month_range": ("30 days", "30 天"),
    "year_range": ("1 year", "1 年"),
    "refreshing": ("Refreshing…", "刷新中…"),
    "ready": ("Local-only · ready", "仅本地 · 就绪"),
    "ready_network": ("Ready · online quota enabled", "就绪 · 已启用在线额度查询"),
    "unavailable": ("unavailable", "不可用"),
    "stale": ("stale", "已过期"),
    "save_card": ("Save profile card", "保存档案卡"),
    "saved": ("Saved", "已保存"),
}


def system_language() -> str:
    """Return ``zh`` or ``en`` without relying on deprecated locale APIs."""
    candidates = [
        os.environ.get("LANG", ""),
        os.environ.get("LC_ALL", ""),
        (locale.getlocale()[0] or ""),
    ]
    return "zh" if any(value.lower().startswith("zh") for value in candidates) else "en"


def resolve_language(value: str | None) -> str:
    return system_language() if value not in {"en", "zh"} else value


def text(key: str, language: str | None) -> str:
    pair = _TEXT.get(key)
    if pair is None:
        return key
    return pair[1] if resolve_language(language) == "zh" else pair[0]
