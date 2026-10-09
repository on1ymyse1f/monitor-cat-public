import Foundation

/// Reads Codex CLI usage and quota from its own rollout logs.
///
/// No credentials are touched. Codex embeds a `rate_limits` object inside the
/// `token_count` events it already writes to
/// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, so the headline quota numbers
/// are available without reading `auth.json`, refreshing an OAuth token, or
/// risking the user's live CLI session.
///
/// Two traps in this format, both verified against live logs and covered by
/// tests:
///
/// 1. `total_token_usage` is **cumulative per session**. Summing it across
///    events overcounts quadratically. This collector reads the final snapshot
///    (or sums per-event deltas when a time window is requested).
/// 2. `input_tokens` is **inclusive** of `cached_input_tokens`
///    (`input + output == total`). Normalizing subtracts the cached portion so
///    it is not counted twice against Claude Code's exclusive convention.
/// 3. A **forked or subagent thread inherits its parent's cumulative counter**,
///    so its first `total_token_usage` is history that another rollout already
///    accounted for — not consumption. See `SessionMeta.inheritsParentCounter`.
public struct CodexCollector: Sendable {
    public let sessionsRoot: URL

    public init(sessionsRoot: URL? = nil) {
        self.sessionsRoot = sessionsRoot ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public static let providerName = "Codex CLI"

    // MARK: - Session meta

    /// The facts the rollout's first line states about the thread it records.
    public struct SessionMeta: Sendable, Equatable {
        /// This rollout's own thread id (`payload.id`).
        public var threadId: String?
        /// The conversation the thread belongs to. For a fork or a subagent
        /// this is the **parent's** id, not this thread's.
        public var sessionId: String?
        public var cwd: String?
        /// Whether this rollout continues another thread's cumulative counters.
        ///
        /// Codex spawns subagents and forks as their own rollout files, and
        /// each one opens with the parent's running `total_token_usage` already
        /// in it. A reconstruction that measures deltas from zero therefore
        /// books that entire inherited history as this thread's first turn.
        ///
        /// Counting that inherited baseline as new usage can substantially
        /// overstate a fork's usage. The opening snapshot may also arrive before
        /// the subagent announces its model, so model attribution is completed
        /// later from the same rollout.
        ///
        /// Three independent fields mark it, and any one is sufficient:
        /// `forked_from_id`, `parent_thread_id`, `thread_source == "subagent"`.
        public var inheritsParentCounter: Bool

        public init(
            threadId: String? = nil, sessionId: String? = nil,
            cwd: String? = nil, inheritsParentCounter: Bool = false
        ) {
            self.threadId = threadId
            self.sessionId = sessionId
            self.cwd = cwd
            self.inheritsParentCounter = inheritsParentCounter
        }
    }

    /// Reads the rollout's `session_meta` line.
    ///
    /// One definition, used by both the full-scan collector and the incremental
    /// sync engine: the two paths are cross-checked against each other by test,
    /// so a rule that lived in only one of them would surface as a failure with
    /// no obvious cause.
    public static func sessionMeta(of file: URL) -> SessionMeta {
        guard let handle = try? FileHandle(forReadingFrom: file),
              let chunk = try? handle.read(upToCount: 1 << 16),
              let newline = chunk.firstIndex(of: 0x0A),
              let object = try? JSONSerialization.jsonObject(with: Data(chunk[..<newline])) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return SessionMeta() }
        try? handle.close()

        return SessionMeta(
            threadId: payload["id"] as? String,
            sessionId: payload["session_id"] as? String ?? payload["id"] as? String,
            cwd: payload["cwd"] as? String,
            inheritsParentCounter: payload["forked_from_id"] != nil
                || payload["parent_thread_id"] != nil
                || (payload["thread_source"] as? String) == "subagent"
        )
    }

    public func collect(since: Date? = nil) -> ProviderReport {
        var stats = ScanStats()
        var total = TokenBreakdown()
        var latestQuota: (windows: [QuotaWindow], observedAt: Date)?
        var notes: [String] = []

        let files = Self.rolloutFiles(under: sessionsRoot)
        guard !files.isEmpty else {
            return ProviderReport(
                provider: Self.providerName,
                tokenConfidence: .unavailable,
                billedCostConfidence: .unavailable,
                quotaConfidence: .unavailable,
                stats: stats,
                notes: [
                    "No rollout logs found under \(sessionsRoot.path).",
                    "Reporting unavailable rather than zero — an empty scan is not a quiet day.",
                ]
            )
        }

        for file in files {
            var previous = TokenBreakdown()
            var sessionTotal = TokenBreakdown()
            var sawUsage = false
            var sessionHadReset = false
            // A forked or subagent rollout opens with the parent's running
            // total already in it. That first snapshot is the baseline the
            // thread's own deltas are measured from — never its first turn.
            var pendingInheritedBaseline = Self.sessionMeta(of: file).inheritsParentCounter

            do {
                // Accounting lives in token_count events (which also embed
                // rate_limits); all other rollout lines are content — skip them
                // before JSON parsing.
                try JSONL.forEachObject(at: file, needles: ["token_count", "rate_limits"]) { object in
                    let payload = object.dict("payload") ?? object
                    let eventDate = Timestamps.parse(object.str("timestamp"))

                    if let rateLimits = payload.dict("rate_limits"),
                       let observedAt = eventDate {
                        let windows = Self.quotaWindows(from: rateLimits, observedAt: observedAt)
                        if !windows.isEmpty {
                            if latestQuota == nil || observedAt > latestQuota!.observedAt {
                                latestQuota = (windows, observedAt)
                            }
                        }
                    }

                    guard let info = payload.dict("info"),
                          let cumulative = info.dict("total_token_usage") else { return }

                    let snapshot = Self.normalize(cumulative)
                    sawUsage = true
                    stats.recordsWithUsage += 1

                    // Absorb the inherited baseline before anything else looks
                    // at it: to the reset check below it is an enormous jump
                    // upward from zero, which is exactly what a genuine first
                    // turn looks like.
                    if pendingInheritedBaseline {
                        pendingInheritedBaseline = false
                        previous = snapshot
                        stats.inheritedBaselinesAbsorbed += 1
                        return
                    }

                    if snapshot.indicatesResetFrom(previous) {
                        stats.counterResetsObserved += 1
                        sessionHadReset = true
                        // A resume/fork restarted the counters. Everything counted
                        // so far stands; the new snapshot starts a fresh run.
                        sessionTotal += snapshot
                        previous = snapshot
                        return
                    }

                    let delta = snapshot.delta(from: previous)
                    previous = snapshot

                    if let since {
                        // Windowed: attribute each delta to its own event time.
                        // Deltas are immune to the duplicate `token_count` events
                        // this format emits, because a duplicate carries an
                        // identical cumulative value and so contributes zero.
                        if let eventDate, eventDate >= since { sessionTotal += delta }
                    } else {
                        sessionTotal += delta
                    }
                }
                stats.filesScanned += 1
            } catch {
                stats.filesFailed += 1
                continue
            }

            if sawUsage {
                total += sessionTotal
                if sessionHadReset {
                    notes.append(
                        "Session \(file.lastPathComponent) restarted its counters mid-file (resume or fork)."
                    )
                }
            }
        }

        // Deltas summed from a zero baseline equal the final cumulative snapshot
        // exactly when the counters are monotonic, so a clean scan is exact.
        let tokenConfidence: Confidence = stats.counterResetsObserved == 0 ? .exact : .estimated

        if total.cacheWriteUnspecified > 0 {
            notes.append(
                "Codex reports cache writes without a TTL; \(total.cacheWriteUnspecified.formatted()) tokens are recorded as TTL-unspecified."
            )
        }
        notes.append(
            "Quota is read from the `rate_limits` object Codex writes into its own logs — no credentials are read."
        )
        notes.append(
            "Cost is unavailable in this report: tokens are summed across models and list pricing differs per model. Per-model costs live in the persistent store — see the dashboard's Models page."
        )
        if since != nil {
            notes.append("Windowed totals differ per-event snapshots; whole-history totals read final snapshots.")
        }

        return ProviderReport(
            provider: Self.providerName,
            tokens: total,
            tokenConfidence: tokenConfidence,
            apiEquivalentCostUSD: nil,
            apiEquivalentCostConfidence: .unavailable,
            billedCostConfidence: .unavailable,
            quotas: latestQuota?.windows ?? [],
            quotaConfidence: latestQuota == nil ? .unavailable : .exact,
            stats: stats,
            notes: notes
        )
    }

    /// Maps Codex's usage shape onto the neutral breakdown.
    ///
    /// `input_tokens` includes `cached_input_tokens`, so the cached portion is
    /// subtracted out to yield genuinely fresh input.
    static func normalize(_ usage: [String: Any]) -> TokenBreakdown {
        let input = usage.int("input_tokens") ?? 0
        let cached = usage.int("cached_input_tokens") ?? 0
        return TokenBreakdown(
            uncachedInput: max(0, input - cached),
            cachedInput: cached,
            cacheWriteUnspecified: usage.int("cache_write_input_tokens") ?? 0,
            output: usage.int("output_tokens") ?? 0,
            reasoning: usage.int("reasoning_output_tokens") ?? 0
        )
    }

    /// Builds quota windows from `rate_limits`.
    ///
    /// The window label is derived from `window_minutes` rather than assuming
    /// primary means "5h" — the provider can assign different durations to
    /// either field, and the secondary window may be absent.
    static func quotaWindows(from rateLimits: [String: Any], observedAt: Date) -> [QuotaWindow] {
        let planType = rateLimits.str("plan_type")
        let limitID = rateLimits.str("limit_id") ?? "codex"
        var out: [QuotaWindow] = []

        for (slot, suffix) in [("primary", ""), ("secondary", "-secondary")] {
            guard let window = rateLimits.dict(slot),
                  let used = window.double("used_percent"),
                  let minutes = window.int("window_minutes") else { continue }
            // `resets_at` is an absolute epoch timestamp, not an offset —
            // verified: 1787196990 decodes to a plausible near-future date.
            let resets = window.int("resets_at").map { Date(timeIntervalSince1970: TimeInterval($0)) }
            // The secondary slot often has the same window size as primary;
            // without a distinct label the dashboard cannot tell them apart.
            let baseLabel = QuotaWindow.label(forWindowMinutes: minutes)
            out.append(
                QuotaWindow(
                    id: limitID + suffix,
                    label: slot == "secondary" ? "\(baseLabel) · secondary" : baseLabel,
                    usedPercent: used,
                    windowMinutes: minutes,
                    resetsAt: resets,
                    observedAt: observedAt,
                    planType: planType
                )
            )
        }
        return out
    }

    public static func rolloutFiles(under root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in e {
            let name = url.lastPathComponent
            if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }
}
