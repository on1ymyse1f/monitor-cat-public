import Foundation

/// A provider-neutral token breakdown.
///
/// The two providers disagree about what "input tokens" means, and this struct
/// exists to absorb that disagreement in exactly one place:
///
///   * Codex reports `input_tokens` **inclusive** of `cached_input_tokens`
///     (verified: `input + output == total`, and `cached <= input`).
///   * Claude Code reports `input_tokens` **exclusive** of cache reads —
///     cache reads live in `cache_read_input_tokens`.
///
/// Summing the two providers' raw `input_tokens` fields would therefore add a
/// number that includes cache reads to one that excludes them. Both collectors
/// normalize into the fields below, where `uncachedInput` never includes cache
/// reads for either provider.
public struct TokenBreakdown: Sendable, Equatable, Codable {
    /// Fresh input tokens, billed at full rate. Never includes cache reads.
    public var uncachedInput: Int
    /// Input served from cache, billed at a large discount.
    public var cachedInput: Int
    /// Tokens written into a 5-minute-TTL cache.
    public var cacheWrite5m: Int
    /// Tokens written into a 1-hour-TTL cache. Priced higher than 5m — keeping
    /// these separate is the difference between a right and a wrong cost.
    public var cacheWrite1h: Int
    /// Cache writes whose TTL the source does not disclose.
    ///
    /// Codex reports a bare `cache_write_input_tokens` with no TTL. Rather than
    /// quietly filing those under 5m and pricing them at 1.25x, they land here
    /// and any cost derived from them is flagged as resting on an assumption.
    public var cacheWriteUnspecified: Int
    /// Output tokens. Includes reasoning/thinking tokens.
    public var output: Int
    /// Reasoning (Codex) / thinking (Claude Code) tokens. A **subset** of
    /// `output`, carried for visibility and deliberately excluded from all sums.
    public var reasoning: Int

    public init(
        uncachedInput: Int = 0,
        cachedInput: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        cacheWriteUnspecified: Int = 0,
        output: Int = 0,
        reasoning: Int = 0
    ) {
        self.uncachedInput = uncachedInput
        self.cachedInput = cachedInput
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheWriteUnspecified = cacheWriteUnspecified
        self.output = output
        self.reasoning = reasoning
    }

    public var cacheWriteTotal: Int { cacheWrite5m + cacheWrite1h + cacheWriteUnspecified }

    /// Everything that would appear on a bill. `reasoning` is excluded because
    /// it is already counted inside `output`.
    public var billableEquivalent: Int {
        uncachedInput + cachedInput + cacheWriteTotal + output
    }

    public static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            uncachedInput: lhs.uncachedInput + rhs.uncachedInput,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            cacheWriteUnspecified: lhs.cacheWriteUnspecified + rhs.cacheWriteUnspecified,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    public static func += (lhs: inout TokenBreakdown, rhs: TokenBreakdown) {
        lhs = lhs + rhs
    }

    /// Component-wise difference, floored at zero.
    ///
    /// Used to turn Codex's cumulative-per-session counters into per-event
    /// deltas. The floor handles a counter reset (resume/fork restarting the
    /// count mid-file), where a naive subtraction would go negative.
    public func delta(from previous: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            uncachedInput: max(0, uncachedInput - previous.uncachedInput),
            cachedInput: max(0, cachedInput - previous.cachedInput),
            cacheWrite5m: max(0, cacheWrite5m - previous.cacheWrite5m),
            cacheWrite1h: max(0, cacheWrite1h - previous.cacheWrite1h),
            cacheWriteUnspecified: max(0, cacheWriteUnspecified - previous.cacheWriteUnspecified),
            output: max(0, output - previous.output),
            reasoning: max(0, reasoning - previous.reasoning)
        )
    }

    /// True when any component moved backwards — the signature of a session
    /// resume or fork restarting the cumulative counters.
    public func indicatesResetFrom(_ previous: TokenBreakdown) -> Bool {
        uncachedInput < previous.uncachedInput
            || cachedInput < previous.cachedInput
            || output < previous.output
    }
}

/// A quota window as the provider itself reports it.
public struct QuotaWindow: Sendable, Equatable, Codable {
    /// Provider's own identifier, e.g. `codex` or `premium`.
    public var id: String
    /// Human label derived from `windowMinutes` — never hardcoded, because the
    /// window size is a property of the plan, not of the tool.
    public var label: String
    public var usedPercent: Double
    public var windowMinutes: Int
    /// Absolute reset time. Codex reports this as an epoch timestamp, not an
    /// offset — verified against live logs.
    public var resetsAt: Date?
    /// When this snapshot was written. Quota read from a log is as fresh as the
    /// last time the tool ran, and stale quota is misleading without this.
    public var observedAt: Date
    public var planType: String?

    public init(
        id: String,
        label: String,
        usedPercent: Double,
        windowMinutes: Int,
        resetsAt: Date?,
        observedAt: Date,
        planType: String? = nil
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.planType = planType
    }

    /// How much a reading can still be trusted, given how long ago it was taken
    /// **and how long the window it describes is**.
    ///
    /// A quota reading is not a fact with a shelf life of its own: it is a
    /// percentage of a *rolling* window. Once `age` has elapsed, up to
    /// `age / window` of that window has rolled off the back, and unseen usage
    /// may have gone on the front. So the error a stale reading can carry is
    /// bounded by `age / window` — which makes a single flat threshold the
    /// wrong shape for the question.
    ///
    /// The old rule used a flat 24 hours before it would even mention the
    /// reading's age, and the desktop-cache reader accepted anything under six.
    /// Six hours is *longer than the five-hour window itself*: a reading that
    /// old describes a window that has completely turned over. That is the
    /// mechanism behind "AI Monitor shows Claude's limit when Claude is not
    /// running" — the desktop app's cache file stays on disk after it quits,
    /// and the last sample in it was being presented as the current number.
    public enum Staleness: Sendable, Equatable {
        /// Fresh enough that the reading is worth printing as the current one.
        case live
        /// Old enough to state when it was taken, alongside the number.
        case aging(TimeInterval)
        /// So old the window has substantially rolled. No number is shown.
        case expired(TimeInterval)

        public var age: TimeInterval? {
            switch self {
            case .live: return nil
            case .aging(let a), .expired(let a): return a
            }
        }
    }

    /// Fraction of the window an observation may age before it stops being
    /// presentable as current. At 5% the reading can be off by at most ~5
    /// percentage points: 15 minutes on a 5-hour window, ~8 hours on a weekly.
    public static let liveAgeFraction: Double = 0.05
    /// Beyond this fraction the reading is not shown as a number at all.
    public static let expiredAgeFraction: Double = 0.25

    public func staleness(now: Date = Date()) -> Staleness {
        Self.staleness(ofAge: now.timeIntervalSince(observedAt), windowMinutes: windowMinutes)
    }

    /// The same rule against a timestamp the caller supplies.
    ///
    /// The dashboard needs this because the row's own `observedAt` is not
    /// always the right clock. Quota snapshots are deduplicated — a reading
    /// identical to its neighbour is not stored — so a source that keeps
    /// confirming the *same* percentage leaves the stored `observedAt` sitting
    /// still while the reading is in fact being refreshed every cycle. The
    /// store records those confirmations separately (`quotaConfirmedAt`), and
    /// that is the age this rule should be applied to.
    public static func staleness(ofAge age: TimeInterval, windowMinutes: Int) -> Staleness {
        guard age > 0 else { return .live }
        let window = Double(windowMinutes) * 60
        guard window > 0 else { return age > 3600 ? .expired(age) : .live }

        if age <= window * liveAgeFraction { return .live }
        if age <= window * expiredAgeFraction { return .aging(age) }
        return .expired(age)
    }

    /// Derives a label from the window size. `window_minutes` in live data has
    /// been observed at 10080 (weekly); 300 (5h) is the other documented shape.
    public static func label(forWindowMinutes minutes: Int) -> String {
        switch minutes {
        case 60: return "1h"
        case 300: return "5h"
        case 1440: return "daily"
        case 10080: return "weekly"
        case 43200: return "monthly"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
            if minutes % 60 == 0 { return "\(minutes / 60)h" }
            return "\(minutes)m"
        }
    }
}

/// What one provider contributes to the report.
public struct ProviderReport: Sendable, Codable {
    public var provider: String
    public var tokens: TokenBreakdown?
    public var tokenConfidence: Confidence
    /// List-price cost of equivalent API usage. **Not** what the user was
    /// charged: a subscription plan does not bill per token, so this is a
    /// comparison figure, never an invoice.
    public var apiEquivalentCostUSD: Decimal?
    public var apiEquivalentCostConfidence: Confidence
    /// What the user was actually billed. Never derivable from local logs.
    public var billedCostConfidence: Confidence
    public var quotas: [QuotaWindow]
    public var quotaConfidence: Confidence
    public var perModel: [ModelUsage]
    public var stats: ScanStats
    public var notes: [String]

    public init(
        provider: String,
        tokens: TokenBreakdown? = nil,
        tokenConfidence: Confidence = .unavailable,
        apiEquivalentCostUSD: Decimal? = nil,
        apiEquivalentCostConfidence: Confidence = .unavailable,
        billedCostConfidence: Confidence = .unavailable,
        quotas: [QuotaWindow] = [],
        quotaConfidence: Confidence = .unavailable,
        perModel: [ModelUsage] = [],
        stats: ScanStats = ScanStats(),
        notes: [String] = []
    ) {
        self.provider = provider
        self.tokens = tokens
        self.tokenConfidence = tokenConfidence
        self.apiEquivalentCostUSD = apiEquivalentCostUSD
        self.apiEquivalentCostConfidence = apiEquivalentCostConfidence
        self.billedCostConfidence = billedCostConfidence
        self.quotas = quotas
        self.quotaConfidence = quotaConfidence
        self.perModel = perModel
        self.stats = stats
        self.notes = notes
    }
}

public struct ModelUsage: Sendable, Codable {
    public var model: String
    public var speed: String?
    public var tokens: TokenBreakdown
    public var costUSD: Decimal?
    public var requests: Int

    public init(model: String, speed: String? = nil, tokens: TokenBreakdown, costUSD: Decimal?, requests: Int) {
        self.model = model
        self.speed = speed
        self.tokens = tokens
        self.costUSD = costUSD
        self.requests = requests
    }
}

/// Scan bookkeeping. This exists so that "zero" is legible.
///
/// A parser that finds nothing reports zero tokens, which looks exactly like a
/// quiet day. `filesScanned == 0` is the tell that the format drifted or the
/// path is wrong, and the report prints it for that reason.
public struct ScanStats: Sendable, Codable {
    public var filesScanned: Int = 0
    public var filesFailed: Int = 0
    public var recordsWithUsage: Int = 0
    public var duplicatesDropped: Int = 0
    /// Records that had no stable provider-assigned identity, so we keyed them
    /// by file+line. A duplicate among these can survive dedup — the reason
    /// token confidence degrades to `.estimated` when this is non-zero.
    public var syntheticallyKeyed: Int = 0
    public var counterResetsObserved: Int = 0
    /// Forked / subagent rollouts whose inherited opening counter was absorbed
    /// as a baseline rather than booked as consumption. Disclosed because it is
    /// the difference between this build's Codex total and every earlier one.
    public var inheritedBaselinesAbsorbed: Int = 0
    public var unpricedModels: Set<String> = []
    /// Server-side tool invocations (web search / web fetch) seen in the logs.
    ///
    /// These bill per request rather than per token, and no verified per-request
    /// rate ships with this build — so they are counted and disclosed, but
    /// deliberately excluded from the cost figure rather than priced on a guess.
    public var webSearchRequests: Int = 0
    public var webFetchRequests: Int = 0

    public init() {}

    public static func + (lhs: ScanStats, rhs: ScanStats) -> ScanStats {
        var out = ScanStats()
        out.filesScanned = lhs.filesScanned + rhs.filesScanned
        out.filesFailed = lhs.filesFailed + rhs.filesFailed
        out.recordsWithUsage = lhs.recordsWithUsage + rhs.recordsWithUsage
        out.duplicatesDropped = lhs.duplicatesDropped + rhs.duplicatesDropped
        out.syntheticallyKeyed = lhs.syntheticallyKeyed + rhs.syntheticallyKeyed
        out.counterResetsObserved = lhs.counterResetsObserved + rhs.counterResetsObserved
        out.inheritedBaselinesAbsorbed = lhs.inheritedBaselinesAbsorbed + rhs.inheritedBaselinesAbsorbed
        out.unpricedModels = lhs.unpricedModels.union(rhs.unpricedModels)
        out.webSearchRequests = lhs.webSearchRequests + rhs.webSearchRequests
        out.webFetchRequests = lhs.webFetchRequests + rhs.webFetchRequests
        return out
    }
}

public struct UsageReport: Sendable, Codable {
    public var generatedAt: Date
    public var since: Date?
    public var providers: [ProviderReport]
    /// Disclosures that belong to the run rather than to one provider — which
    /// pricing table was in force, which override entries failed to parse.
    ///
    /// A cost computed from an edited rate table is not the same claim as one
    /// computed from the verified defaults, and the report has to say which it
    /// is. Decoded with a default so an older JSON payload still reads.
    public var notes: [String]

    public init(generatedAt: Date, since: Date?, providers: [ProviderReport], notes: [String] = []) {
        self.generatedAt = generatedAt
        self.since = since
        self.providers = providers
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        since = try c.decodeIfPresent(Date.self, forKey: .since)
        providers = try c.decode([ProviderReport].self, forKey: .providers)
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}
