import Foundation

/// The settlement slip: what one day, or the last seven, came to — itemised by
/// model the way a shop itemises a basket.
///
/// The page draws it as a printed receipt, but every number on it is one this
/// store already reports elsewhere, so the slip can never disagree with the
/// hero: the one-day total is `totals(since: startOfToday).costUSD` exactly.
///
/// **Priced and unpriced stay apart.** A model with no verified rate has no
/// price, and a receipt that printed it at $0.00 would understate the total by
/// a number nobody can see. Unpriced lines are listed with their tokens and no
/// price, counted in the token total, and left out of the money total — with
/// the receipt saying so.
public struct Receipt: Equatable, Sendable {
    public enum Span: Int, CaseIterable, Sendable {
        case day = 1, week = 7
    }

    /// One line in the basket: a model, what it consumed, and what that cost.
    public struct Item: Equatable, Sendable {
        public var model: String
        public var provider: String
        public var tokens: Int
        public var requests: Int
        /// Sum of the priced part. Nil when no event of this model was priced.
        public var costUSD: Double?
        /// Tokens of this model that carry no price. Non-zero with a non-nil
        /// cost means the line is only *partly* priced.
        public var unpricedTokens: Int
    }

    /// One calendar day of the span, in local time. Days with no events are
    /// present, at zero — a closed shop is part of a week's settlement.
    public struct Day: Equatable, Sendable {
        public var start: Date
        public var tokens: Int
        public var requests: Int
        public var costUSD: Double?
        public var unpricedTokens: Int
    }

    public var span: Span
    /// Midnight that begins the first day of the span.
    public var from: Date
    /// The moment the slip was settled, to the minute.
    public var issuedAt: Date
    /// Most expensive first; unpriced lines after the priced ones, by tokens.
    public var items: [Item]
    /// Oldest first; always `span.rawValue` entries.
    public var days: [Day]

    public var totalTokens: Int { items.reduce(0) { $0 + $1.tokens } }
    public var totalRequests: Int { items.reduce(0) { $0 + $1.requests } }
    /// Money total of the priced lines only. Nil when nothing was priced.
    public var pricedCostUSD: Double? {
        let priced = items.compactMap(\.costUSD)
        return priced.isEmpty ? nil : priced.reduce(0, +)
    }
    public var unpricedTokens: Int { items.reduce(0) { $0 + $1.unpricedTokens } }
    /// Lines that carry no price at all.
    public var unpricedItems: Int { items.filter { $0.costUSD == nil }.count }
    public var isEmpty: Bool { items.isEmpty }

    /// A receipt number that is the same for the same span on the same day, so
    /// re-printing does not pretend to be a different sale: `1003-07`.
    public var number: String {
        let c = Calendar.current.dateComponents([.month, .day], from: issuedAt)
        return String(format: "%02d%02d-%02d", c.month ?? 0, c.day ?? 0, span.rawValue)
    }
}

extension EventStore {
    /// Settles `span` days ending today, local time.
    ///
    /// Day boundaries come from `calendar`, not from SQLite's `localtime`, so a
    /// day that is 23 or 25 hours long across a clock change is still one day,
    /// and tests can pin the time zone. The last day has no upper bound — the
    /// same as the dashboard's "today", so the two agree to the cent even when
    /// a tool's clock runs ahead.
    public func receipt(_ span: Receipt.Span, now: Date = Date(),
                        calendar: Calendar = .current) throws -> Receipt {
        let today = calendar.startOfDay(for: now)
        let starts: [Date] = (0..<span.rawValue).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        let from = starts.first ?? today

        // Items: one row per model within the span. A model with no tokens is
        // not a line: Claude Code writes `<synthetic>` records — messages it
        // generates itself, at zero tokens. They should not print as an
        // unpriced purchase on the receipt.
        let items = try db.prepare("""
            SELECT model, provider, SUM(billable), COUNT(*), SUM(cost_usd),
                   SUM(CASE WHEN cost_usd IS NULL THEN billable ELSE 0 END)
            FROM events WHERE ts IS NOT NULL AND ts >= ?1
            GROUP BY model, provider
            HAVING SUM(billable) > 0
            """)
        items.bind(from.timeIntervalSince1970, 1)
        var lines: [Receipt.Item] = []
        while try items.step() {
            lines.append(Receipt.Item(
                model: items.str(0) ?? "unknown",
                provider: items.str(1) ?? "?",
                tokens: items.int(2),
                requests: items.int(3),
                costUSD: items.isNull(4) ? nil : items.double(4),
                unpricedTokens: items.int(5)
            ))
        }
        lines.sort { a, b in
            switch (a.costUSD, b.costUSD) {
            case let (x?, y?): return x != y ? x > y : a.tokens > b.tokens
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.tokens > b.tokens
            }
        }

        // Days: one bucket per calendar day, assigned by the latest boundary
        // the event is past. A single grouped scan of the indexed range.
        let cases = starts.indices.reversed()
            .map { "WHEN ts >= ?\($0 + 1) THEN \($0)" }
            .joined(separator: " ")
        let daily = try db.prepare("""
            SELECT bucket, SUM(billable), COUNT(*), SUM(cost_usd),
                   SUM(CASE WHEN cost_usd IS NULL THEN billable ELSE 0 END)
            FROM (SELECT billable, cost_usd, CASE \(cases) END AS bucket
                  FROM events WHERE ts IS NOT NULL AND ts >= ?1)
            GROUP BY bucket
            """)
        for (i, start) in starts.enumerated() { daily.bind(start.timeIntervalSince1970, Int32(i + 1)) }
        var days = starts.map { Receipt.Day(start: $0, tokens: 0, requests: 0, costUSD: nil, unpricedTokens: 0) }
        while try daily.step() {
            let i = daily.int(0)
            guard days.indices.contains(i) else { continue }
            days[i].tokens = daily.int(1)
            days[i].requests = daily.int(2)
            days[i].costUSD = daily.isNull(3) ? nil : daily.double(3)
            days[i].unpricedTokens = daily.int(4)
        }

        // Settled to the minute: a slip re-read within the same minute with no
        // new events is equal to the last one, and the page does not redraw.
        let minute = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        return Receipt(span: span, from: from, issuedAt: minute, items: lines, days: days)
    }
}
