import Foundation

/// The normalized accounting record every collector emits.
///
/// Events carry accounting only — never prompt or response content. Identity
/// rules per provider:
///
///   * Claude Code: `requestId` (or `msg:<messageId>`, or `line:<file>#<n>`
///     when no provider identity exists). Progressive streaming snapshots share
///     an id; the store keeps the largest.
///   * Codex: `codex:<file>#<line>` — positional, but delta events are
///     idempotent because appending the same log replays the same ids.
public struct AIEvent: Sendable, Equatable {
    public var id: String
    public var timestamp: Date?
    /// `local_log` now; `api_proxy`, `browser`, `provider_usage`, `process`,
    /// `local_model` reserved for later collectors.
    public var source: String
    public var provider: String
    public var application: String?
    public var model: String?
    public var sessionId: String?
    public var project: String?
    public var eventType: String   // "usage" today; quota lives in its own table
    /// The provider's own speed tier for this request, when it reports one —
    /// Claude Code writes `usage.speed`, and `fast` prices at a premium.
    /// Persisted so a stored cost can be recomputed against an edited rate
    /// table without losing which tier it was billed at.
    public var speed: String?
    public var tokens: TokenBreakdown
    /// API-equivalent list cost, nil when the model is unpriced. Never a guess.
    public var costUSD: Decimal?
    public var confidence: Confidence

    public init(
        id: String,
        timestamp: Date?,
        source: String = "local_log",
        provider: String,
        application: String? = nil,
        model: String? = nil,
        sessionId: String? = nil,
        project: String? = nil,
        eventType: String = "usage",
        speed: String? = nil,
        tokens: TokenBreakdown,
        costUSD: Decimal?,
        confidence: Confidence
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.provider = provider
        self.application = application
        self.model = model
        self.sessionId = sessionId
        self.project = project
        self.eventType = eventType
        self.speed = speed
        self.tokens = tokens
        self.costUSD = costUSD
        self.confidence = confidence
    }
}
