import Foundation

extension EventStore {
    // MARK: - Analytics

    public struct ProviderTotals: Equatable {
        public var provider: String
        public var billable: Int
        public var requests: Int
        public var costUSD: Double?
        public var sessions: Int
    }

    /// Totals per provider. `since`/`until` are inclusive lower / exclusive upper bounds.
    public func totalsByProvider(since: Date? = nil, until: Date? = nil) throws -> [ProviderTotals] {
        var whereClauses: [String] = []
        if since != nil { whereClauses.append("ts >= ?1") }
        if until != nil { whereClauses.append("ts < ?2") }
        let whereSQL = whereClauses.isEmpty ? "" : "WHERE ts IS NOT NULL AND " + whereClauses.joined(separator: " AND ")
        let stmt = try db.prepare("""
            SELECT provider, SUM(billable), COUNT(*), SUM(cost_usd), COUNT(DISTINCT session_id)
            FROM events \(whereSQL) GROUP BY provider ORDER BY SUM(billable) DESC
            """)
        if let since { stmt.bind(since.timeIntervalSince1970, 1) }
        if let until { stmt.bind(until.timeIntervalSince1970, 2) }
        var out: [ProviderTotals] = []
        while try stmt.step() {
            out.append(ProviderTotals(
                provider: stmt.str(0) ?? "?",
                billable: stmt.int(1),
                requests: stmt.int(2),
                costUSD: stmt.isNull(3) ? nil : stmt.double(3),
                sessions: stmt.int(4)
            ))
        }
        return out
    }

    public struct ModelTotals: Equatable {
        public var model: String
        public var provider: String
        public var billable: Int
        public var requests: Int
        public var costUSD: Double?
        public var sessions: Int
    }

    public func totalsByModel(since: Date? = nil) throws -> [ModelTotals] {
        let stmt = try db.prepare("""
            SELECT model, provider, SUM(billable), COUNT(*), SUM(cost_usd), COUNT(DISTINCT session_id)
            FROM events WHERE ts IS NOT NULL \(since != nil ? "AND ts >= ?1" : "")
            GROUP BY model, provider ORDER BY SUM(billable) DESC
            """)
        if let since { stmt.bind(since.timeIntervalSince1970, 1) }
        var out: [ModelTotals] = []
        while try stmt.step() {
            out.append(ModelTotals(
                model: stmt.str(0) ?? "unknown",
                provider: stmt.str(1) ?? "?",
                billable: stmt.int(2),
                requests: stmt.int(3),
                costUSD: stmt.isNull(4) ? nil : stmt.double(4),
                sessions: stmt.int(5)
            ))
        }
        return out
    }

    public struct ProjectTotals: Equatable {
        public var project: String
        public var provider: String
        public var billable: Int
        public var requests: Int
    }

    public func totalsByProject(since: Date? = nil) throws -> [ProjectTotals] {
        let stmt = try db.prepare("""
            SELECT project, provider, SUM(billable), COUNT(*)
            FROM events WHERE ts IS NOT NULL AND project IS NOT NULL
            \(since != nil ? "AND ts >= ?1" : "")
            GROUP BY project, provider ORDER BY SUM(billable) DESC
            """)
        if let since { stmt.bind(since.timeIntervalSince1970, 1) }
        var out: [ProjectTotals] = []
        while try stmt.step() {
            out.append(ProjectTotals(
                project: stmt.str(0) ?? "?",
                provider: stmt.str(1) ?? "?",
                billable: stmt.int(2),
                requests: stmt.int(3)
            ))
        }
        return out
    }

    /// Token flow buckets: per hour for a 1-day range, per day otherwise.
    /// Returns (bucketStart, billable) ascending.
    public func tokenFlow(since: Date, until: Date? = nil) throws -> [(Date, Int)] {
        let hourly = (until ?? Date()).timeIntervalSince(since) <= 36 * 3600
        let expr = hourly
            ? "strftime('%Y-%m-%d %H:00:00', ts, 'unixepoch', 'localtime')"
            : "date(ts, 'unixepoch', 'localtime')"
        let stmt = try db.prepare("""
            SELECT \(expr) b, SUM(billable) FROM events
            WHERE ts IS NOT NULL AND ts >= ?1 \(until != nil ? "AND ts < ?2" : "")
            GROUP BY b ORDER BY b
            """)
        stmt.bind(since.timeIntervalSince1970, 1)
        if let until { stmt.bind(until.timeIntervalSince1970, 2) }
        let fmt = DateFormatter()
        // POSIX, or `HH` follows the user's 12/24-hour preference: on a Mac
        // set to 12-hour time "15:00:00" fails to parse, every hourly bucket
        // is dropped, and the dashboard's "today" flow is always empty.
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = hourly ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        var out: [(Date, Int)] = []
        while try stmt.step() {
            if let s = stmt.str(0), let d = fmt.parse(s) {
                out.append((d, stmt.int(1)))
            }
        }
        return out
    }

    /// Distinct minutes containing at least one event — the honest version of
    /// "AI active time" derivable from logs: activity corroborated by requests.
    public func activeMinutes(since: Date, until: Date? = nil) throws -> Int {
        let stmt = try db.prepare("""
            SELECT COUNT(DISTINCT strftime('%Y-%m-%d %H:%M', ts, 'unixepoch', 'localtime'))
            FROM events WHERE ts IS NOT NULL AND ts >= ?1 \(until != nil ? "AND ts < ?2" : "")
            """)
        stmt.bind(since.timeIntervalSince1970, 1)
        if let until { stmt.bind(until.timeIntervalSince1970, 2) }
        guard try stmt.step() else { return 0 }
        return stmt.int(0)
    }

    public struct DayTotals: Equatable {
        public var billable: Int
        public var requests: Int
        public var costUSD: Double?
        public var sessions: Int
    }

    public func totals(since: Date, until: Date? = nil) throws -> DayTotals {
        let stmt = try db.prepare("""
            SELECT SUM(billable), COUNT(*), SUM(cost_usd), COUNT(DISTINCT session_id)
            FROM events WHERE ts IS NOT NULL AND ts >= ?1 \(until != nil ? "AND ts < ?2" : "")
            """)
        stmt.bind(since.timeIntervalSince1970, 1)
        if let until { stmt.bind(until.timeIntervalSince1970, 2) }
        guard try stmt.step() else { return DayTotals(billable: 0, requests: 0, costUSD: nil, sessions: 0) }
        return DayTotals(
            billable: stmt.isNull(0) ? 0 : stmt.int(0),
            requests: stmt.int(1),
            costUSD: stmt.isNull(2) ? nil : stmt.double(2),
            sessions: stmt.int(3)
        )
    }

    /// Whole-store token total used to calculate live CLI deltas.
    ///
    /// A delta must not be derived from the dashboard's capped, newest-first
    /// session rows: membership changes when a fifth session becomes recent,
    /// and subtracting those two different sets can turn one new token into a
    /// six-figure jump. This aggregate has one stable scope across ticks;
    /// retention or an explicit deletion may legitimately make it decrease.
    public func cumulativeBillable() throws -> Int {
        let stmt = try db.prepare("""
            SELECT COALESCE(SUM(billable), 0) FROM events
            WHERE event_type = 'usage'
            """)
        guard try stmt.step() else { return 0 }
        return stmt.int(0)
    }

    public struct TimelineEvent: Equatable {
        public var timestamp: Date
        public var provider: String
        public var model: String?
        public var billable: Int
        public var project: String?
        public var sessionId: String?
    }

    /// Chronological event feed for the timeline page. No prompt content exists
    /// in this table — the schema never stores it.
    public func recentEvents(limit: Int = 300, provider: String? = nil) throws -> [TimelineEvent] {
        let stmt = try db.prepare("""
            SELECT ts, provider, model, billable, project, session_id FROM events
            WHERE ts IS NOT NULL \(provider != nil ? "AND provider = ?2" : "")
            ORDER BY ts DESC LIMIT ?1
            """)
        stmt.bind(limit, 1)
        if let provider { stmt.bind(provider, 2) }
        var out: [TimelineEvent] = []
        while try stmt.step() {
            out.append(TimelineEvent(
                timestamp: Date(timeIntervalSince1970: stmt.double(0)),
                provider: stmt.str(1) ?? "?",
                model: stmt.str(2),
                billable: stmt.int(3),
                project: stmt.str(4),
                sessionId: stmt.str(5)
            ))
        }
        return out
    }

    /// Per-day billable for one provider, ascending, only days with usage.
    /// Feeds the profile card's heatmap and streak math. Local-time days.
    public func dailyBillable(provider: String) throws -> [(day: Date, billable: Int)] {
        let stmt = try db.prepare("""
            SELECT date(ts, 'unixepoch', 'localtime') d, SUM(billable) FROM events
            WHERE ts IS NOT NULL AND provider=?1 GROUP BY d ORDER BY d
            """)
        stmt.bind(provider, 1)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        var out: [(Date, Int)] = []
        while try stmt.step() {
            if let s = stmt.str(0), let d = fmt.parse(s) {
                out.append((d, stmt.int(1)))
            }
        }
        return out
    }

    /// Distinct providers present in the store, most usage first — the set of
    /// cards `aimonitor card` can offer.
    public func providersPresent() throws -> [String] {
        let stmt = try db.prepare("""
            SELECT provider, SUM(billable) b FROM events GROUP BY provider ORDER BY b DESC
            """)
        var out: [String] = []
        while try stmt.step() {
            if let p = stmt.str(0) { out.append(p) }
        }
        return out
    }

    /// Whole-history token breakdown per provider — the number the CLI report
    /// cross-checks against. SUM of billable components, not just billable.
    public func tokenBreakdown(provider: String) throws -> TokenBreakdown? {
        let stmt = try db.prepare("""
            SELECT SUM(uncached_input), SUM(cached_input), SUM(cache_write_5m), SUM(cache_write_1h),
                   SUM(cache_write_unspecified), SUM(output), SUM(reasoning)
            FROM events WHERE provider=?1
            """)
        stmt.bind(provider, 1)
        guard try stmt.step(), !stmt.isNull(0) else { return nil }
        return TokenBreakdown(
            uncachedInput: stmt.int(0), cachedInput: stmt.int(1),
            cacheWrite5m: stmt.int(2), cacheWrite1h: stmt.int(3),
            cacheWriteUnspecified: stmt.int(4),
            output: stmt.int(5), reasoning: stmt.int(6)
        )
    }

    public func eventCount(provider: String) throws -> Int {
        let stmt = try db.prepare("SELECT COUNT(*) FROM events WHERE provider=?1")
        stmt.bind(provider, 1)
        guard try stmt.step() else { return 0 }
        return stmt.int(0)
    }
}

private extension DateFormatter {
    func parse(_ s: String) -> Date? { date(from: s) }
}
