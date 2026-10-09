import Foundation

extension EventStore {
    // MARK: - Unpriced models

    /// Models with stored usage and no cost, straight from the store.
    ///
    /// Derived from `cost_usd IS NULL` rather than from a collector's own
    /// bookkeeping, so it covers every provider and all of history — including
    /// events synced by a build whose pricing table has since changed. The
    /// alternative, asking each collector what it failed to price, only ever
    /// sees the files that were parsed on this run.
    public func unpricedModels() throws -> [UnpricedModel] {
        let stmt = try db.prepare("""
            SELECT provider, model, SUM(billable), COUNT(*), MAX(ts)
            FROM events
            WHERE event_type = 'usage' AND cost_usd IS NULL
            GROUP BY provider, model
            ORDER BY SUM(billable) DESC
            """)
        var out: [UnpricedModel] = []
        while try stmt.step() {
            out.append(UnpricedModel(
                provider: stmt.str(0) ?? "?",
                model: stmt.str(1) ?? "",
                billable: stmt.int(2),
                requests: stmt.int(3),
                lastSeen: stmt.isNull(4) ? nil : Date(timeIntervalSince1970: stmt.double(4))
            ))
        }
        return out
    }

    public func unpricedScan(baseline: UnpricedBaseline = .load()) throws -> UnpricedScan {
        UnpricedScan(models: try unpricedModels(), baseline: baseline)
    }

    // MARK: - Recost

    /// What a recost did, in enough detail to tell a price change from a bug.
    public struct RecostSummary: Sendable, Equatable {
        public var rowsExamined = 0
        public var rowsChanged = 0
        /// Rows that had no cost and now have one — a model the table learned.
        public var nowPriced = 0
        /// Rows that had a cost and now have none — a model the table lost.
        /// Worth seeing: an override with `replace: true` and a typo in a model
        /// id looks exactly like this, and it silently deletes money.
        public var nowUnpriced = 0
        /// Rows written before the `speed` column existed whose model *has* a
        /// fast-mode rate, so whether they were billed at the premium cannot be
        /// recovered. They are recosted at the standard rate and counted here
        /// rather than quietly folded into the total.
        public var unvouchedSpeedRows = 0
        public var previousTotalUSD: Decimal = 0
        public var newTotalUSD: Decimal = 0

        public var deltaUSD: Decimal { newTotalUSD - previousTotalUSD }
    }

    /// Recomputes `cost_usd` for every stored usage event against the pricing
    /// catalog currently in force.
    ///
    /// Cost is calculated at sync time and persisted, which is the right call
    /// for a store that answers dashboard queries in milliseconds — but it
    /// means an edited rate table reaches only events synced *after* the edit.
    /// Without this, a user who corrects a price would watch the number not
    /// move, and a store would end up holding a mix of old-priced and
    /// new-priced rows summed together as if they were one figure.
    ///
    /// Each row is repriced against its **own** timestamp, so an intro rate
    /// that lapsed last month still applies to the events it covered.
    /// `onlyModels` restricts the update to exact stored model IDs. An empty
    /// set updates nothing; nil retains the explicit whole-store operation.
    public func recost(now: Date = Date(), onlyModels: Set<String>? = nil) throws -> RecostSummary {
        var summary = RecostSummary()
        let catalog = PricingCatalog.current

        struct Row {
            let id: String
            let ts: Date?
            let model: String?
            let speed: String?
            let tokens: TokenBreakdown
            /// The stored REAL, kept exactly as SQLite returned it.
            ///
            /// Not a `Decimal`: round-tripping the stored double through
            /// `Decimal` and back does not land on the same double, so
            /// comparing that against the freshly-computed value marked a
            /// fifth of the store as changed on a recost that changed nothing.
            /// The comparison has to happen in the type the column holds.
            let oldCost: Double?
        }

        var rows: [Row] = []
        let select = try db.prepare("""
            SELECT id, ts, model, speed,
                   uncached_input, cached_input, cache_write_5m, cache_write_1h,
                   cache_write_unspecified, output, reasoning, cost_usd
            FROM events WHERE event_type = 'usage'
            """)
        while try select.step() {
            if let onlyModels, !onlyModels.contains(select.str(2) ?? "") { continue }
            rows.append(Row(
                id: select.str(0) ?? "",
                ts: select.isNull(1) ? nil : Date(timeIntervalSince1970: select.double(1)),
                model: select.str(2),
                speed: select.str(3),
                tokens: TokenBreakdown(
                    uncachedInput: select.int(4), cachedInput: select.int(5),
                    cacheWrite5m: select.int(6), cacheWrite1h: select.int(7),
                    cacheWriteUnspecified: select.int(8),
                    output: select.int(9), reasoning: select.int(10)
                ),
                oldCost: select.isNull(11) ? nil : select.double(11)
            ))
        }

        try db.transaction {
            let update = try db.prepare("UPDATE events SET cost_usd = ?1 WHERE id = ?2")
            for row in rows {
                summary.rowsExamined += 1
                let model = row.model ?? ""
                let newCost = PricingTable.cost(
                    of: row.tokens, model: model, speed: row.speed, asOf: row.ts ?? now
                )

                if row.speed == nil, catalog.fastMode[model] != nil {
                    summary.unvouchedSpeedRows += 1
                }
                let newDouble = newCost.map { NSDecimalNumber(decimal: $0).doubleValue }
                // Both totals accumulate the value that is (or would be) *in
                // the column*, not the exact Decimal behind it. Mixing the two
                // left a recost that changed nothing reporting a delta of
                // "-<$0.01" — a rounding artefact that reads as a real move.
                summary.previousTotalUSD += row.oldCost.map { Decimal($0) } ?? 0
                summary.newTotalUSD += newDouble.map { Decimal($0) } ?? 0

                // Both sides in the column's own type, so a recost that changes
                // nothing reports nothing.
                guard row.oldCost != newDouble else { continue }

                summary.rowsChanged += 1
                if row.oldCost == nil, newCost != nil { summary.nowPriced += 1 }
                if row.oldCost != nil, newCost == nil { summary.nowUnpriced += 1 }

                update.reset()
                update.bind(newDouble, 1)
                update.bind(row.id, 2)
                _ = try update.step()
            }
        }
        return summary
    }

}
