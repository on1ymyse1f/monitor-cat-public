import Foundation

/// Cursor is out of scope, and no longer shown.
///
/// It was reported as a row that always read `unavailable`, in every surface —
/// dashboard card, settings toggle, probe, and the text report. A permanent
/// "no data" row is not a disclosure, it is furniture: the reader learns to
/// skip that part of the page, which is the opposite of what a confidence
/// marker is for. The collector stays here, unreferenced by the report, so the
/// reasoning below is not lost if a local source ever appears.
///
/// Original note:
/// Cursor is deliberately out of scope for this phase.
///
/// Cursor does not write per-request token accounting locally in a form
/// comparable to Codex's and Claude Code's; its usage data sits behind a
/// team-oriented admin API, and the local store holds a session token rather
/// than per-request counts. A Cursor row built from a different kind of number
/// would sit next to its neighbours implying comparability it does not have, so
/// this reports `unavailable` with the reason instead.
public struct CursorCollector: Sendable {
    public init() {}
    public static let providerName = "Cursor"

    public func collect(since: Date? = nil) -> ProviderReport {
        ProviderReport(
            provider: Self.providerName,
            tokenConfidence: .unavailable,
            billedCostConfidence: .unavailable,
            quotaConfidence: .unavailable,
            notes: [
                "No local per-request token accounting comparable to the other providers.",
                "Cursor's usage history is exposed through a team admin API, not the local store; a row here would not mean what its neighbours mean.",
            ]
        )
    }
}

public struct Aggregator: Sendable {
    public let codex: CodexCollector
    public let claudeCode: ClaudeCodeCollector
    public let kimi: KimiCollector
    public let cursor: CursorCollector

    public init(
        codex: CodexCollector = CodexCollector(),
        claudeCode: ClaudeCodeCollector = ClaudeCodeCollector(),
        kimi: KimiCollector = KimiCollector(),
        cursor: CursorCollector = CursorCollector()
    ) {
        self.codex = codex
        self.claudeCode = claudeCode
        self.kimi = kimi
        self.cursor = cursor
    }

    public func report(since: Date? = nil, now: Date = Date()) -> UsageReport {
        let catalog = PricingCatalog.current
        var notes: [String] = []
        // Only says anything when the run is *not* on the verified defaults —
        // a line on every report that reads "nothing unusual" trains the eye
        // to skip the place where the unusual would appear.
        if let source = catalog.sourceNote { notes.append(source) }
        notes.append(contentsOf: catalog.problems)

        return UsageReport(
            generatedAt: now,
            since: since,
            providers: [
                claudeCode.collect(since: since),
                codex.collect(since: since),
                kimi.collect(since: since),
            ],
            notes: notes
        )
    }
}
