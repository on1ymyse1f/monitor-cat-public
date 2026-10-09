"""Windows path policy, isolated from accounting and storage logic."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class AIMonitorPaths:
    """All mutable paths used by the Windows application.

    Provider roots remain overrideable so tests and portable installations do
    not need to alter a real user's logs.  Analytics live in ``LOCALAPPDATA``
    because they are private machine-local state, not roaming preferences.
    """

    data_dir: Path
    database: Path
    pricing_override: Path
    claude_root: Path
    codex_root: Path
    kimi_roots: tuple[Path, ...]

    @classmethod
    def defaults(cls, home: Path | None = None, env: dict[str, str] | None = None) -> "AIMonitorPaths":
        values = os.environ if env is None else env
        user_home = Path(home) if home is not None else Path.home()
        local_app_data = Path(
            values.get("LOCALAPPDATA") or user_home / "AppData" / "Local"
        )
        roaming_app_data = Path(
            values.get("APPDATA") or user_home / "AppData" / "Roaming"
        )
        data_dir = Path(values.get("AIMONITOR_DATA_DIR") or local_app_data / "AIMonitor")

        cli_kimi = Path(values.get("AIMONITOR_KIMI_ROOT") or user_home / ".kimi-code" / "sessions")
        # Kimi Desktop locations have changed across builds.  These are only
        # discovery candidates; collectors silently ignore absent directories.
        desktop_candidates = (
            roaming_app_data
            / "kimi-desktop"
            / "daimon-share"
            / "daimon"
            / "runtime"
            / "kimi-code"
            / "home"
            / "sessions",
            local_app_data
            / "kimi-desktop"
            / "daimon-share"
            / "daimon"
            / "runtime"
            / "kimi-code"
            / "home"
            / "sessions",
        )
        roots: list[Path] = [cli_kimi]
        roots.extend(path for path in desktop_candidates if path.exists() and path not in roots)

        return cls(
            data_dir=data_dir,
            database=Path(values.get("AIMONITOR_DB") or data_dir / "aimonitor.db"),
            pricing_override=Path(
                values.get("AIMONITOR_PRICING") or data_dir / "pricing.json"
            ),
            claude_root=Path(
                values.get("AIMONITOR_CLAUDE_ROOT") or user_home / ".claude" / "projects"
            ),
            codex_root=Path(
                values.get("AIMONITOR_CODEX_ROOT") or user_home / ".codex" / "sessions"
            ),
            kimi_roots=tuple(roots),
        )

    def ensure_private_data_dir(self) -> None:
        """Create the app directory without touching any provider log root."""

        self.data_dir.mkdir(parents=True, exist_ok=True)


def default_db_path() -> Path:
    """Compatibility entry point used by the thin desktop adapter."""

    paths = AIMonitorPaths.defaults()
    paths.ensure_private_data_dir()
    return paths.database
