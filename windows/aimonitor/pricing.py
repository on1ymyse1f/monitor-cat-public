"""Exact-decimal API-equivalent pricing with an optional local override."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

from .models import TokenBreakdown


MILLION = Decimal(1_000_000)
CACHE_READ_MULTIPLIER = Decimal("0.1")
CACHE_WRITE_5M_MULTIPLIER = Decimal("1.25")
CACHE_WRITE_1H_MULTIPLIER = Decimal("2.0")


@dataclass(frozen=True, slots=True)
class ModelRate:
    input_per_mtok: Decimal
    output_per_mtok: Decimal
    intro_input_per_mtok: Decimal | None = None
    intro_output_per_mtok: Decimal | None = None
    intro_ends_before: datetime | None = None
    cached_input_per_mtok: Decimal | None = None

    def effective(self, at: datetime) -> tuple[Decimal, Decimal]:
        if (
            self.intro_ends_before is not None
            and self.intro_input_per_mtok is not None
            and self.intro_output_per_mtok is not None
            and at < self.intro_ends_before
        ):
            return self.intro_input_per_mtok, self.intro_output_per_mtok
        return self.input_per_mtok, self.output_per_mtok


def _utc(year: int, month: int, day: int) -> datetime:
    return datetime(year, month, day, tzinfo=timezone.utc)


BUILTIN_MODELS: dict[str, ModelRate] = {
    "claude-fable-5": ModelRate(Decimal("10"), Decimal("50")),
    "claude-mythos-5": ModelRate(Decimal("10"), Decimal("50")),
    "claude-opus-5": ModelRate(Decimal("5"), Decimal("25")),
    "claude-opus-4-8": ModelRate(Decimal("5"), Decimal("25")),
    "claude-opus-4-7": ModelRate(Decimal("5"), Decimal("25")),
    "claude-opus-4-6": ModelRate(Decimal("5"), Decimal("25")),
    "claude-sonnet-5": ModelRate(
        Decimal("3"),
        Decimal("15"),
        Decimal("2"),
        Decimal("10"),
        _utc(2026, 9, 1),
    ),
    "claude-sonnet-4-6": ModelRate(Decimal("3"), Decimal("15")),
    "claude-haiku-4-5": ModelRate(Decimal("1"), Decimal("5")),
    # Standard short-context API rates; GPT-6 Sol/Luna verified 2026-09-23.
    "gpt-6-astra": ModelRate(Decimal("10"), Decimal("50")),
    "gpt-6-sol": ModelRate(Decimal("2"), Decimal("10"), cached_input_per_mtok=Decimal("0.2")),
    "gpt-6-luna": ModelRate(Decimal("0.1"), Decimal("0.5"), cached_input_per_mtok=Decimal("0.01")),
    "gpt-5.4": ModelRate(Decimal("2.5"), Decimal("15")),
    "gpt-5.5": ModelRate(Decimal("5"), Decimal("30")),
    "gpt-5.6-sol": ModelRate(Decimal("5"), Decimal("30")),
    "gpt-5.6-terra": ModelRate(Decimal("2"), Decimal("12")),
    "gpt-5.6-luna": ModelRate(Decimal("0.2"), Decimal("1.2")),
    # OpenAI's Luna Reserve fallback is logged as gpt-reserve but runs Luna.
    "gpt-reserve": ModelRate(Decimal("0.2"), Decimal("1.2")),
    # Kimi Code and Kimi Work consume subscription credits; these are
    # comparable public API list-price estimates, not subscription invoices.
    "kimi-code/k3": ModelRate(Decimal("3"), Decimal("15"), cached_input_per_mtok=Decimal("0.30")),
    "k3-agent": ModelRate(Decimal("3"), Decimal("15"), cached_input_per_mtok=Decimal("0.30")),
    "k2d6-agent": ModelRate(Decimal("0.95"), Decimal("4"), cached_input_per_mtok=Decimal("0.16")),
    "kimi-code/kimi-for-coding": ModelRate(
        Decimal("0.95"), Decimal("4"), cached_input_per_mtok=Decimal("0.19")
    ),
}

BUILTIN_FAST_MODE: dict[str, ModelRate] = {
    "claude-opus-5": ModelRate(Decimal("10"), Decimal("50")),
    "claude-opus-4-8": ModelRate(Decimal("10"), Decimal("50")),
}


class PricingCatalog:
    """Verified defaults plus a fail-closed JSON overlay."""

    def __init__(
        self,
        models: dict[str, ModelRate] | None = None,
        fast_mode: dict[str, ModelRate] | None = None,
        *,
        source: str = "built-in",
        problems: list[str] | None = None,
    ) -> None:
        self.models = dict(BUILTIN_MODELS if models is None else models)
        self.fast_mode = dict(BUILTIN_FAST_MODE if fast_mode is None else fast_mode)
        self.source = source
        self.problems = list(problems or [])

    @classmethod
    def load(cls, path: Path | str | None) -> "PricingCatalog":
        base = cls()
        if path is None:
            return base
        file_path = Path(path)
        if not file_path.is_file():
            return base
        try:
            root = json.loads(file_path.read_text(encoding="utf-8"))
            if not isinstance(root, dict):
                raise ValueError("top level must be an object")
            replace = root.get("replace") is True
            models = {} if replace else dict(base.models)
            fast_mode = {} if replace else dict(base.fast_mode)
            problems: list[str] = []
            cls._merge_table(models, root.get("models"), "models", problems)
            cls._merge_table(fast_mode, root.get("fastMode"), "fastMode", problems)
            return cls(
                models,
                fast_mode,
                source=str(file_path),
                problems=problems,
            )
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
            base.problems.append(f"pricing override ignored: {file_path}: {exc}")
            return base

    @staticmethod
    def _merge_table(
        target: dict[str, ModelRate], value: Any, label: str, problems: list[str]
    ) -> None:
        if value is None:
            return
        if not isinstance(value, dict):
            problems.append(f"{label} must be an object")
            return
        for model, raw in value.items():
            try:
                if not isinstance(model, str) or not isinstance(raw, dict):
                    raise ValueError("entry must be an object")
                input_rate = Decimal(str(raw["input"]))
                output_rate = Decimal(str(raw["output"]))
                cached_input = Decimal(str(raw["cachedInput"])) if "cachedInput" in raw else None
                if input_rate < 0 or output_rate < 0:
                    raise ValueError("negative rate")
                intro_end = None
                intro_input = intro_output = None
                if "introEndsBefore" in raw:
                    intro_end = datetime.fromisoformat(str(raw["introEndsBefore"])).replace(
                        tzinfo=timezone.utc
                    )
                    intro_input = Decimal(str(raw["introInput"]))
                    intro_output = Decimal(str(raw["introOutput"]))
                target[model] = ModelRate(
                    input_rate,
                    output_rate,
                    intro_input,
                    intro_output,
                    intro_end,
                    cached_input,
                )
            except (KeyError, ValueError, TypeError, InvalidOperation) as exc:
                target.pop(str(model), None)
                problems.append(f"{label}.{model}: {exc}")

    def rate(self, model: str | None, speed: str | None = None) -> ModelRate | None:
        if not model or model.startswith("<"):
            return None
        normalized = model.removeprefix("anthropic.")
        if speed == "fast" and normalized in self.fast_mode:
            return self.fast_mode[normalized]
        if normalized in self.models:
            return self.models[normalized]
        candidates = [
            name for name in self.models
            if normalized.startswith(name)
            and (
                not name.startswith("gpt-")
                or re.fullmatch(r"-(?:[0-9]{8}|[0-9]{4}-[0-9]{2}-[0-9]{2})", normalized[len(name):])
            )
        ]
        if not candidates:
            return None
        alias = max(candidates, key=len)
        if speed == "fast" and alias in self.fast_mode:
            return self.fast_mode[alias]
        return self.models[alias]

    def cost(
        self,
        tokens: TokenBreakdown,
        model: str | None,
        speed: str | None = None,
        at: datetime | None = None,
    ) -> Decimal | None:
        rate = self.rate(model, speed)
        if rate is None:
            return None
        instant = at or datetime.now(timezone.utc)
        if instant.tzinfo is None:
            instant = instant.replace(tzinfo=timezone.utc)
        input_rate, output_rate = rate.effective(instant)
        cached_input_rate = rate.cached_input_per_mtok or input_rate * CACHE_READ_MULTIPLIER
        return (
            Decimal(tokens.uncached_input) * input_rate
            + Decimal(tokens.cached_input) * cached_input_rate
            + Decimal(tokens.cache_write_5m) * input_rate * CACHE_WRITE_5M_MULTIPLIER
            + Decimal(tokens.cache_write_1h) * input_rate * CACHE_WRITE_1H_MULTIPLIER
            + Decimal(tokens.cache_write_unspecified)
            * input_rate
            * CACHE_WRITE_5M_MULTIPLIER
            + Decimal(tokens.output) * output_rate
        ) / MILLION
