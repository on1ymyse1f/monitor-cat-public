import Foundation

/// Incremental log → store synchronization.
///
/// Restart-safety rules:
///   * Files are append-only. A checkpoint (size + offset + provider state) is
///     written per file **after** its events are committed, in one transaction
///     per file, so a crash mid-file re-parses that file and the dedup rules
///     (requestId keep-largest / positional INSERT OR IGNORE) make the replay
///     harmless.
///   * A file that shrank since its checkpoint was rotated or rewritten —
///     re-parse from zero; the same dedup rules keep events unique.
///   * Codex counters are cumulative per session; the last snapshot is stored
///     in the checkpoint so deltas stay correct across process restarts.
/// Remembers the size each file had when it was last found unchanged.
///
/// A memory-only size cache avoids querying SQLite for files that have not
/// changed. `stat` already determines whether a sync is needed; comparing each
/// result with its last known size skips unchanged-file checkpoint reads.
///
/// Deliberately not persisted: it is a cache, and a cold start that re-asks
/// SQLite once is fine. It never causes a file to be *skipped*
/// wrongly — a size change always falls through to the real checkpoint.
public final class FileSizeCache: @unchecked Sendable {
    private var sizes: [String: Int] = [:]
    private let lock = NSLock()

    public init() {}

    /// True when this path is known to be exactly this size already.
    public func isUnchanged(_ path: String, size: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sizes[path] == size
    }

    public func record(_ path: String, size: Int) {
        lock.lock(); defer { lock.unlock() }
        sizes[path] = size
    }
}

public struct SyncEngine: Sendable {
    public let store: EventStore
    /// Shared across syncs when the caller keeps one; nil means every file is
    /// checked against the store, which is what one-shot CLI runs want.
    public let fileSizes: FileSizeCache?
    public let claudeRoot: URL
    public let codexRoot: URL
    public let kimiRoots: [URL]

    public init(
        store: EventStore, claudeRoot: URL? = nil, codexRoot: URL? = nil,
        kimiRoots: [URL]? = nil, fileSizes: FileSizeCache? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.store = store
        self.fileSizes = fileSizes
        self.claudeRoot = claudeRoot ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
        self.codexRoot = codexRoot ?? home.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.kimiRoots = kimiRoots ?? KimiCollector().sessionsRoots
    }

    public struct SyncSummary: Equatable {
        public var filesScanned = 0
        public var filesSkippedUnchanged = 0
        public var filesFailed = 0
        public var claudeEvents = 0
        public var codexEvents = 0
        public var kimiEvents = 0
        public var quotaSnapshots = 0
    }

    /// Codex checkpoint state: the cumulative token snapshot plus the model
    /// last seen in a `turn_context` line. Older checkpoints hold the bare
    /// token map and are still accepted on read.
    struct CodexCheckpoint: Codable {
        var tokens: [String: Int]
        var model: String?
    }

    /// Stat-only change detection over the files the collectors actually read.
    ///
    /// Summing every file size under the roots had two problems: an unrelated
    /// cache/readme could trigger a sync, while one log growing by N bytes as
    /// another shrank by N left the same total and skipped real work. Hashing
    /// each relevant file's path and size preserves the cheap polling model but
    /// gives file membership and per-file changes their own identity.
    public func logsFingerprint() -> Int {
        let files = (
            ClaudeCodeCollector.transcriptFiles(under: claudeRoot)
                + CodexCollector.rolloutFiles(under: codexRoot)
                + kimiRoots.flatMap { KimiCollector.wireFiles(under: $0) }
        ).sorted { $0.path < $1.path }

        var hasher = Hasher()
        hasher.combine(files.count)
        for url in files {
            hasher.combine(url.standardizedFileURL.path)
            hasher.combine((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return hasher.finalize()
    }

    public func sync() -> SyncSummary {
        var summary = SyncSummary()
        // v2 absorbs inherited parent/subagent baselines. Existing rows made
        // by v1 cannot be repaired arithmetically, so rebuild only Codex from
        // its source logs once; every other provider remains untouched.
        do {
            try store.prepareCollectorVersion(
                settingKey: "collector_version_codex", version: "2",
                provider: CodexCollector.providerName, checkpointRoot: codexRoot.path
            )
        } catch {
            summary.filesFailed += 1
            return summary
        }
        syncClaude(&summary)
        syncCodex(&summary)
        syncKimi(&summary)
        // Retention is deliberately NOT applied here: the sync engine's job is
        // to make the store faithful to the logs. Data lifecycle is a separate
        // decision, applied by the app layer via store.applyRetention().
        return summary
    }

    // MARK: - Claude Code

    private func syncClaude(_ summary: inout SyncSummary) {
        for file in ClaudeCodeCollector.transcriptFiles(under: claudeRoot) {
            do { try syncClaudeFile(file, &summary) } catch { summary.filesFailed += 1 }
        }
    }

    private func syncClaudeFile(_ file: URL, _ summary: inout SyncSummary) throws {
        let size = fileSize(file)
        let path = file.path
        // Cheapest possible skip: the size we already know, with no SQL at all.
        if fileSizes?.isUnchanged(path, size: size) == true {
            summary.filesSkippedUnchanged += 1
            return
        }
        let cp = try store.checkpoint(for: path)
        if let cp, cp.size == size {
            fileSizes?.record(path, size: size)
            summary.filesSkippedUnchanged += 1
            return
        }

        let offset = (cp != nil && cp!.offset <= size) ? cp!.offset : 0
        let project = Self.claudeProjectName(for: file, under: claudeRoot)
        var pending: [AIEvent] = []

        let end = try JSONL.forEachLine(at: file, from: UInt64(offset), needles: ["\"usage\""]) { object, lineStart, _ in
            guard let message = object.dict("message"),
                  let usage = message.dict("usage") else { return }
            if object.bool("isApiErrorMessage") == true { return }

            let timestamp = Timestamps.parse(object.str("timestamp"))
            let tokens = ClaudeCodeCollector.normalize(usage)
            let model = message.str("model") ?? "unknown"
            let speed = usage.str("speed")

            let id: String
            if let requestID = object.str("requestId"), !requestID.isEmpty {
                id = requestID
            } else if let messageID = message.str("id"), !messageID.isEmpty {
                id = "msg:" + messageID
            } else {
                // Positional id: byte offsets are stable because logs are append-only.
                id = "pos:\(file.lastPathComponent)@\(lineStart)"
            }

            let cost = PricingTable.cost(of: tokens, model: model, speed: speed, asOf: timestamp ?? Date())
            pending.append(AIEvent(
                id: id, timestamp: timestamp,
                provider: ClaudeCodeCollector.providerName,
                application: "Claude Code",
                model: model,
                sessionId: object.str("sessionId"),
                project: project,
                speed: speed,
                tokens: tokens, costUSD: cost, confidence: .estimated
            ))
        }

        try commitEvents(pending, keepLargest: true) { [store] in
            try store.setCheckpoint(.init(size: size, offset: Int(end), state: nil), for: path)
        }
        summary.filesScanned += 1
        summary.claudeEvents += pending.count
    }

    // MARK: - Codex

    private func syncCodex(_ summary: inout SyncSummary) {
        for file in CodexCollector.rolloutFiles(under: codexRoot) {
            do { try syncCodexFile(file, &summary) } catch { summary.filesFailed += 1 }
        }
    }

    private func syncCodexFile(_ file: URL, _ summary: inout SyncSummary) throws {
        let size = fileSize(file)
        let path = file.path
        // Cheapest possible skip: the size we already know, with no SQL at all.
        if fileSizes?.isUnchanged(path, size: size) == true {
            summary.filesSkippedUnchanged += 1
            return
        }
        let cp = try store.checkpoint(for: path)
        if let cp, cp.size == size {
            fileSizes?.record(path, size: size)
            summary.filesSkippedUnchanged += 1
            return
        }

        let offset = (cp != nil && cp!.offset <= size) ? cp!.offset : 0
        // The checkpoint restores the cumulative snapshot the next deltas are
        // measured from, plus the model last announced by a `turn_context`
        // line. The legacy state was the bare `[String: Int]` token map —
        // still decoded here so a mid-session upgrade doesn't resume from a
        // zero baseline and double-count the whole file.
        var previous = TokenBreakdown()
        var currentModel: String? = nil
        if let cp, offset > 0, let state = cp.state, let data = state.data(using: .utf8) {
            let decoder = JSONDecoder()
            let tokens = (try? decoder.decode(CodexCheckpoint.self, from: data)).map { ($0.tokens, $0.model) }
                ?? (try? decoder.decode([String: Int].self, from: data)).map { ($0, nil) }
            if let (dict, model) = tokens {
                previous = TokenBreakdown(
                    uncachedInput: dict["uncachedInput"] ?? 0, cachedInput: dict["cachedInput"] ?? 0,
                    cacheWrite5m: dict["cacheWrite5m"] ?? 0, cacheWrite1h: dict["cacheWrite1h"] ?? 0,
                    cacheWriteUnspecified: dict["cacheWriteUnspecified"] ?? 0,
                    output: dict["output"] ?? 0, reasoning: dict["reasoning"] ?? 0
                )
                currentModel = model
            }
        }

        // Session meta lives in the first line, which the needle filter would
        // skip; read it directly. Cheap even on huge files.
        let meta = CodexCollector.sessionMeta(of: file)
        let project = meta.cwd?.split(separator: "/").last.map(String.init)

        // A forked or subagent rollout opens with the parent's running total
        // already in it, so its first snapshot is a baseline, not a turn. Only
        // when starting at the top of the file: resuming from a checkpoint
        // already carries the correct baseline in `previous`.
        var pendingInheritedBaseline = meta.inheritsParentCounter && offset == 0

        // The first model this file ever names. A subagent rollout emits its
        // token_count events long before its first `turn_context`, so events
        // parsed ahead of that line have no model — and an event with no model
        // matches no rate and reports no cost. The name arrives later in the
        // same file, and it is the same thread, so it is applied backwards.
        var announcedModel: String? = currentModel

        var pending: [AIEvent] = []
        var quotas: [QuotaWindow] = []

        let end = try JSONL.forEachLine(at: file, from: UInt64(offset), needles: ["token_count", "rate_limits", "turn_context"]) { object, lineStart, _ in
            let payload = object.dict("payload") ?? object
            let eventDate = Timestamps.parse(object.str("timestamp"))

            // The model a turn runs on is announced in its own line type,
            // ahead of that turn's token_count updates — tracking it gives
            // per-turn attribution and survives mid-session model switches.
            if object.str("type") == "turn_context" {
                if let m = payload.str("model"), !m.isEmpty {
                    currentModel = m
                    if announcedModel == nil { announcedModel = m }
                }
                return
            }

            if let rateLimits = payload.dict("rate_limits"), let observedAt = eventDate {
                quotas.append(contentsOf: CodexCollector.quotaWindows(from: rateLimits, observedAt: observedAt))
            }

            guard let info = payload.dict("info"),
                  let cumulative = info.dict("total_token_usage") else { return }

            let snapshot = CodexCollector.normalize(cumulative)

            // Absorb the inherited baseline before the reset check sees it: a
            // jump from zero to the parent's total is indistinguishable from a
            // genuine first turn to everything downstream.
            if pendingInheritedBaseline {
                pendingInheritedBaseline = false
                previous = snapshot
                return
            }

            let delta: TokenBreakdown
            if snapshot.indicatesResetFrom(previous) {
                delta = snapshot   // counters restarted (resume/fork): fresh run
            } else {
                delta = snapshot.delta(from: previous)
            }
            previous = snapshot
            guard delta.billableEquivalent > 0 else { return }

            pending.append(AIEvent(
                id: "codex:\(file.lastPathComponent)@\(lineStart)",
                timestamp: eventDate,
                provider: CodexCollector.providerName,
                application: "Codex",
                model: currentModel,
                sessionId: meta.sessionId,
                project: project,
                tokens: delta,
                // List-price equivalent from the OpenAI card; nil for models
                // the card doesn't cover — still never guessed.
                costUSD: currentModel.flatMap {
                    PricingTable.cost(of: delta, model: $0, speed: nil, asOf: eventDate ?? Date())
                },
                confidence: .exact
            ))
        }

        let stateDict: [String: Int] = [
            "uncachedInput": previous.uncachedInput, "cachedInput": previous.cachedInput,
            "cacheWrite5m": previous.cacheWrite5m, "cacheWrite1h": previous.cacheWrite1h,
            "cacheWriteUnspecified": previous.cacheWriteUnspecified,
            "output": previous.output, "reasoning": previous.reasoning,
        ]
        let state = String(data: (try? JSONEncoder().encode(CodexCheckpoint(tokens: stateDict, model: currentModel))) ?? Data(), encoding: .utf8)

        // Back-fill within this batch first, then reprice: `costUSD` was
        // computed as nil for exactly these events.
        if let model = announcedModel {
            for i in pending.indices where pending[i].model == nil {
                pending[i].model = model
                pending[i].costUSD = PricingTable.cost(
                    of: pending[i].tokens, model: model, speed: pending[i].speed,
                    asOf: pending[i].timestamp ?? Date()
                )
            }
        }

        try commitEvents(pending, keepLargest: false) { [store] in
            for q in quotas { try store.insert(quota: q, provider: CodexCollector.providerName) }
            try store.setCheckpoint(.init(size: size, offset: Int(end), state: state), for: path)
        }

        // An incremental sync may have committed this file's earlier events in
        // a previous pass, before the model was announced. Those rows are in
        // the store, not in `pending`, so they are filled in separately.
        if let model = announcedModel {
            _ = try? store.attributeMissingModel(idPrefix: "codex:\(file.lastPathComponent)@", model: model)
        }
        summary.filesScanned += 1
        summary.codexEvents += pending.count
        summary.quotaSnapshots += quotas.count
    }

    // MARK: - Kimi Code

    private func syncKimi(_ summary: inout SyncSummary) {
        for root in kimiRoots {
            // One index lookup per root — it is a small file.
            let index = KimiCollector.sessionIndex(under: root)
            for file in KimiCollector.wireFiles(under: root) {
                do { try syncKimiFile(file, root: root, index: index, &summary) } catch { summary.filesFailed += 1 }
            }
        }
    }

    /// Kimi records are per-turn (not cumulative), so no provider state is
    /// needed in the checkpoint: offset resume plus positional-id dedup suffice.
    private func syncKimiFile(_ file: URL, root: URL, index: [String: String], _ summary: inout SyncSummary) throws {
        let size = fileSize(file)
        let path = file.path
        // Cheapest possible skip: the size we already know, with no SQL at all.
        if fileSizes?.isUnchanged(path, size: size) == true {
            summary.filesSkippedUnchanged += 1
            return
        }
        let cp = try store.checkpoint(for: path)
        if let cp, cp.size == size {
            fileSizes?.record(path, size: size)
            summary.filesSkippedUnchanged += 1
            return
        }

        let offset = (cp != nil && cp!.offset <= size) ? cp!.offset : 0
        let sessionId = KimiCollector.sessionId(for: file)
        let project = KimiCollector.projectName(for: file, under: root, index: index)
        var pending: [AIEvent] = []

        let end = try JSONL.forEachLine(at: file, from: UInt64(offset), needles: ["\"usage.record\""]) { object, lineStart, _ in
            guard let tokens = KimiCollector.tokens(from: object),
                  tokens.billableEquivalent > 0 else { return }

            pending.append(AIEvent(
                // Positional id. Kimi wire logs are all named wire.jsonl, so
                // the session component (unique per session) disambiguates.
                id: "kimi:\(sessionId ?? file.deletingLastPathComponent().lastPathComponent)@\(lineStart)",
                timestamp: KimiCollector.timestamp(of: object),
                provider: KimiCollector.providerName,
                application: "Kimi Code",
                model: object.str("model"),
                sessionId: sessionId,
                project: project,
                tokens: tokens,
                costUSD: nil,   // no verified Kimi rate card — never guessed
                confidence: .exact
            ))
        }

        try commitEvents(pending, keepLargest: false) { [store] in
            try store.setCheckpoint(.init(size: size, offset: Int(end), state: nil), for: path)
        }
        summary.filesScanned += 1
        summary.kimiEvents += pending.count
    }

    // MARK: - Helpers

    /// Events and checkpoint commit atomically: a crash between them would
    /// replay the file, and dedup makes replays harmless — but atomicity makes
    /// even that unnecessary.
    private func commitEvents(_ events: [AIEvent], keepLargest: Bool, and extra: () throws -> Void) throws {
        guard !events.isEmpty else { try extra(); return }
        try store.transaction { storeDB in
            for e in events { try storeDB.insert(usage: e, keepLargest: keepLargest) }
            try extra()
        }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Removes the encoded macOS account and home-directory prefixes from a
    /// Claude project slug, leaving the project path components.
    static func claudeProjectName(for file: URL, under root: URL) -> String? {
        let rel = file.path.dropFirst(root.path.count).split(separator: "/")
        guard var slug = rel.first.map(String.init) else { return nil }
        if slug.hasPrefix("-"), let range = slug.range(of: #"^-[^-]*-[^-]*-"#, options: .regularExpression) {
            slug.removeSubrange(range)
        }
        return slug.isEmpty ? nil : slug
    }

}
