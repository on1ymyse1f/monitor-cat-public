"""Incremental sync coordinator for the Windows AIMonitor core."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .collectors import (
    CLAUDE_PROVIDER,
    CODEX_PROVIDER,
    KIMI_PROVIDER,
    claude_files,
    codex_files,
    codex_session_meta,
    codex_tokens,
    kimi_files,
    kimi_session_index,
    parse_claude_event,
    parse_codex_quota_windows,
    parse_kimi_event,
    parse_timestamp,
    scan_jsonl,
)
from .models import AIEvent, Checkpoint, Confidence, QuotaWindow, SyncSummary, TokenBreakdown
from .paths import AIMonitorPaths
from .pricing import PricingCatalog
from .store import EventStore


def _token_state(tokens: TokenBreakdown) -> dict[str, int]:
    return {
        "uncached_input": tokens.uncached_input,
        "cached_input": tokens.cached_input,
        "cache_write_5m": tokens.cache_write_5m,
        "cache_write_1h": tokens.cache_write_1h,
        "cache_write_unspecified": tokens.cache_write_unspecified,
        "output": tokens.output,
        "reasoning": tokens.reasoning,
    }


def _tokens_from_state(value: Any) -> TokenBreakdown:
    if not isinstance(value, dict):
        return TokenBreakdown()

    def integer(*keys: str) -> int:
        for key in keys:
            try:
                if key in value:
                    return max(0, int(value[key]))
            except (TypeError, ValueError):
                return 0
        return 0

    return TokenBreakdown(
        uncached_input=integer("uncached_input", "uncachedInput"),
        cached_input=integer("cached_input", "cachedInput"),
        cache_write_5m=integer("cache_write_5m", "cacheWrite5m"),
        cache_write_1h=integer("cache_write_1h", "cacheWrite1h"),
        cache_write_unspecified=integer(
            "cache_write_unspecified", "cacheWriteUnspecified"
        ),
        output=integer("output"),
        reasoning=integer("reasoning"),
    )


class SyncEngine:
    """Single-writer incremental importer.

    File parsing happens without holding the store lock.  The resulting rows,
    quota confirmations and resume checkpoint are then committed in one store
    transaction, so a crash cannot advance the checkpoint past missing rows.
    """

    def __init__(
        self,
        store: EventStore,
        paths: AIMonitorPaths | None = None,
        *,
        claude_root: Path | str | None = None,
        codex_root: Path | str | None = None,
        kimi_roots: list[Path | str] | tuple[Path | str, ...] | None = None,
        pricing: PricingCatalog | None = None,
    ) -> None:
        defaults = paths or AIMonitorPaths.defaults()
        self.store = store
        self.claude_root = Path(claude_root) if claude_root is not None else defaults.claude_root
        self.codex_root = Path(codex_root) if codex_root is not None else defaults.codex_root
        roots = kimi_roots if kimi_roots is not None else defaults.kimi_roots
        self.kimi_roots = tuple(Path(root) for root in roots)
        self.pricing = pricing or PricingCatalog.load(defaults.pricing_override)

    def sync(self, *, apply_retention: bool = False) -> SyncSummary:
        summary = SyncSummary()
        for path in claude_files(self.claude_root):
            self._attempt(lambda path=path: self._sync_claude(path, summary), summary)
        for path in codex_files(self.codex_root):
            self._attempt(lambda path=path: self._sync_codex(path, summary), summary)
        for root in self.kimi_roots:
            index = kimi_session_index(root)
            for path in kimi_files(root):
                self._attempt(
                    lambda path=path, root=root, index=index: self._sync_kimi(
                        path, root, index, summary
                    ),
                    summary,
                )
        if apply_retention:
            self.store.apply_retention()
        return summary

    @staticmethod
    def _attempt(action: Any, summary: SyncSummary) -> None:
        try:
            action()
        except Exception:
            summary.files_failed += 1

    def _resume(self, path: Path, size: int) -> tuple[Checkpoint | None, int, bool]:
        checkpoint = self.store.checkpoint(path)
        if checkpoint is not None and checkpoint.size == size and checkpoint.offset <= size:
            return checkpoint, checkpoint.offset, True
        if checkpoint is None or checkpoint.size > size or checkpoint.offset > size:
            return checkpoint, 0, False
        return checkpoint, checkpoint.offset, False

    def _sync_claude(self, path: Path, summary: SyncSummary) -> None:
        size = path.stat().st_size
        _checkpoint, offset, unchanged = self._resume(path, size)
        if unchanged:
            summary.files_skipped_unchanged += 1
            return
        pending: list[AIEvent] = []

        def accept(obj: dict[str, Any], line_start: int, _line_end: int) -> None:
            event = parse_claude_event(
                obj,
                path=path,
                line_start=line_start,
                root=self.claude_root,
                pricing=self.pricing,
            )
            if event is not None:
                pending.append(event)

        end = scan_jsonl(
            path,
            start=offset,
            stop=size,
            needles=(b'"usage"',),
            handler=accept,
        )
        written = 0
        with self.store.transaction():
            for event in pending:
                written += int(self.store.insert_event(event, keep_largest=True))
            self.store.set_checkpoint(path, Checkpoint(size=size, offset=end))
        summary.files_scanned += 1
        summary.claude_events += written

    def _sync_codex(self, path: Path, summary: SyncSummary) -> None:
        size = path.stat().st_size
        checkpoint, offset, unchanged = self._resume(path, size)
        if unchanged:
            summary.files_skipped_unchanged += 1
            return

        previous = TokenBreakdown()
        current_model: str | None = None
        if checkpoint is not None and offset > 0 and checkpoint.state:
            try:
                raw_state = json.loads(checkpoint.state)
                if isinstance(raw_state, dict) and isinstance(raw_state.get("tokens"), dict):
                    previous = _tokens_from_state(raw_state["tokens"])
                    current_model = raw_state.get("model") if isinstance(raw_state.get("model"), str) else None
                else:
                    previous = _tokens_from_state(raw_state)
            except (TypeError, json.JSONDecodeError):
                previous = TokenBreakdown()

        meta = codex_session_meta(path)
        pending_inherited_baseline = meta.inherits_parent_counter and offset == 0
        project: str | None = None
        if meta.cwd:
            project = meta.cwd.replace("\\", "/").rstrip("/").rsplit("/", 1)[-1] or None
        pending: list[AIEvent] = []
        quotas: list[QuotaWindow] = []
        announced_model = current_model

        def accept(obj: dict[str, Any], line_start: int, _line_end: int) -> None:
            nonlocal previous, current_model, announced_model, pending_inherited_baseline
            payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else obj
            event_date = parse_timestamp(obj.get("timestamp"))
            if obj.get("type") == "turn_context":
                model = payload.get("model")
                if isinstance(model, str) and model:
                    current_model = model
                    if announced_model is None:
                        announced_model = model
                return
            rate_limits = payload.get("rate_limits")
            if isinstance(rate_limits, dict) and event_date is not None:
                quotas.extend(parse_codex_quota_windows(rate_limits, event_date))
            info = payload.get("info")
            cumulative = info.get("total_token_usage") if isinstance(info, dict) else None
            if not isinstance(cumulative, dict):
                return
            snapshot = codex_tokens(cumulative)
            if pending_inherited_baseline:
                pending_inherited_baseline = False
                previous = snapshot
                return
            delta = snapshot if snapshot.indicates_reset_from(previous) else snapshot.delta_from(previous)
            previous = snapshot
            if delta.billable <= 0:
                return
            pending.append(
                AIEvent(
                    id=f"codex:{path}@{line_start}",
                    timestamp=event_date,
                    provider=CODEX_PROVIDER,
                    application="Codex",
                    model=current_model,
                    session_id=meta.session_id,
                    project=project,
                    tokens=delta,
                    cost_usd=self.pricing.cost(delta, current_model, None, event_date),
                    confidence=Confidence.EXACT,
                )
            )

        end = scan_jsonl(
            path,
            start=offset,
            stop=size,
            needles=(b"token_count", b"rate_limits", b"turn_context"),
            handler=accept,
        )
        if announced_model:
            for event in pending:
                if event.model is None:
                    event.model = announced_model
                    event.cost_usd = self.pricing.cost(
                        event.tokens, announced_model, event.speed, event.timestamp
                    )
        state = json.dumps(
            {"tokens": _token_state(previous), "model": current_model},
            ensure_ascii=False,
            separators=(",", ":"),
        )
        written = 0
        inserted_quotas = 0
        with self.store.transaction():
            for event in pending:
                written += int(self.store.insert_event(event))
            for quota in quotas:
                inserted_quotas += int(self.store.insert_quota(CODEX_PROVIDER, quota))
            self.store.set_checkpoint(path, Checkpoint(size=size, offset=end, state=state))
            if announced_model:
                self.store.attribute_missing_model(f"codex:{path}@", announced_model, self.pricing)
        summary.files_scanned += 1
        summary.codex_events += written
        summary.quota_snapshots += inserted_quotas

    def _sync_kimi(
        self,
        path: Path,
        root: Path,
        index: dict[str, str],
        summary: SyncSummary,
    ) -> None:
        size = path.stat().st_size
        _checkpoint, offset, unchanged = self._resume(path, size)
        if unchanged:
            summary.files_skipped_unchanged += 1
            return
        pending: list[AIEvent] = []

        def accept(obj: dict[str, Any], line_start: int, _line_end: int) -> None:
            event = parse_kimi_event(
                obj, path=path, line_start=line_start, root=root, index=index
            )
            if event is not None:
                pending.append(event)

        end = scan_jsonl(
            path,
            start=offset,
            stop=size,
            needles=(b'"usage.record"',),
            handler=accept,
        )
        written = 0
        with self.store.transaction():
            for event in pending:
                written += int(self.store.insert_event(event))
            self.store.set_checkpoint(path, Checkpoint(size=size, offset=end))
        summary.files_scanned += 1
        summary.kimi_events += written
