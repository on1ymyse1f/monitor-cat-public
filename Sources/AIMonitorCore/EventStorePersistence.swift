import Foundation

extension EventStore {
    private static let quotaConfirmationPrefix = "quota_confirmed|"

    // MARK: - Checkpoints

    public struct Checkpoint: Equatable {
        public var size: Int
        public var offset: Int
        /// Provider-specific resume state, JSON. Codex stores its last
        /// cumulative snapshot here so deltas survive restarts.
        public var state: String?
    }

    public func checkpoint(for path: String) throws -> Checkpoint? {
        let stmt = try db.prepare("SELECT size, offset, state FROM checkpoints WHERE path=?1")
        stmt.bind(path, 1)
        guard try stmt.step() else { return nil }
        return Checkpoint(size: stmt.int(0), offset: stmt.int(1), state: stmt.str(2))
    }

    public func setCheckpoint(_ cp: Checkpoint, for path: String) throws {
        let stmt = try db.prepare("""
            INSERT INTO checkpoints(path,size,offset,state) VALUES(?1,?2,?3,?4)
            ON CONFLICT(path) DO UPDATE SET size=excluded.size, offset=excluded.offset, state=excluded.state
            """)
        stmt.bind(path, 1); stmt.bind(cp.size, 2); stmt.bind(cp.offset, 3); stmt.bind(cp.state, 4)
        _ = try stmt.step()
    }

    /// One-time correction for a collector whose accounting semantics changed.
    /// Only that provider and checkpoints under its exact source root are
    /// cleared; unrelated providers and user settings remain untouched.
    /// The next sync reconstructs the rows from the original logs.
    @discardableResult
    public func prepareCollectorVersion(
        settingKey: String, version: String, provider: String, checkpointRoot: String
    ) throws -> Bool {
        guard setting(settingKey) != version else { return false }
        try db.transaction {
            let events = try db.prepare("DELETE FROM events WHERE provider=?1")
            events.bind(provider, 1)
            _ = try events.step()

            let quotas = try db.prepare("DELETE FROM quota_snapshots WHERE provider=?1")
            quotas.bind(provider, 1)
            _ = try quotas.step()

            let confirmationPrefix = Self.quotaConfirmationPrefix + provider + "|"
            let confirmations = try db.prepare(
                "DELETE FROM settings WHERE substr(key,1,length(?1))=?1"
            )
            confirmations.bind(confirmationPrefix, 1)
            _ = try confirmations.step()

            let checkpoints = try db.prepare(
                "DELETE FROM checkpoints WHERE path=?1 OR substr(path,1,length(?2))=?2"
            )
            checkpoints.bind(checkpointRoot, 1)
            checkpoints.bind(checkpointRoot + "/", 2)
            _ = try checkpoints.step()
            try setSetting(settingKey, version)
        }
        return true
    }

    // MARK: - Quota snapshots

    private static func quotaConfirmationKey(provider: String, windowID: String) -> String {
        quotaConfirmationPrefix + provider + "|" + windowID
    }

    /// The newest time a live source successfully confirmed this window,
    /// independent of the deduplicated history point stored for charts.
    public func quotaConfirmedAt(provider: String, windowID: String) -> Date? {
        let key = Self.quotaConfirmationKey(provider: provider, windowID: windowID)
        guard let value = setting(key), let timestamp = TimeInterval(value) else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func recordQuotaConfirmation(_ q: QuotaWindow, provider: String) throws {
        let stmt = try db.prepare("""
            INSERT INTO settings(key,value) VALUES(?1,?2)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            WHERE CAST(excluded.value AS REAL) > CAST(settings.value AS REAL)
            """)
        stmt.bind(Self.quotaConfirmationKey(provider: provider, windowID: q.id), 1)
        stmt.bind(String(q.observedAt.timeIntervalSince1970), 2)
        _ = try stmt.step()
    }

    public func insert(quota q: QuotaWindow, provider: String) throws {
        // Skip consecutive duplicates: quota snapshots repeat on every event.
        //
        // "Consecutive" has to mean *chronologically previous*, not
        // *most-recently-stored*. Comparing against `MAX(observed_at)` looks
        // equivalent and is not: files are synced in directory order, not in
        // date order, so syncing an older rollout after a newer one compared
        // every one of its snapshots against a reading from the future, matched
        // none of them, and inserted duplicates. That made history depend on
        // the order files happened to be walked in, which the burn-rate engine
        // then read as a time series.
        //
        // Anchoring to the neighbour at or before this snapshot's own timestamp
        // makes the write order-independent: the same logs produce the same
        // history whichever way the walk goes.
        let previous = try db.prepare("""
            SELECT used_percent FROM quota_snapshots
            WHERE window_id=?1 AND observed_at <= ?2
            ORDER BY observed_at DESC, rowid DESC LIMIT 1
            """)
        previous.bind(q.id, 1)
        previous.bind(q.observedAt.timeIntervalSince1970, 2)
        if try previous.step(), abs(previous.double(0) - q.usedPercent) < 0.001 {
            try recordQuotaConfirmation(q, provider: provider)
            return
        }

        // A reading identical to the one that follows it is equally redundant,
        // and only a backfill can produce that ordering.
        let next = try db.prepare("""
            SELECT used_percent FROM quota_snapshots
            WHERE window_id=?1 AND observed_at >= ?2
            ORDER BY observed_at ASC, rowid ASC LIMIT 1
            """)
        next.bind(q.id, 1)
        next.bind(q.observedAt.timeIntervalSince1970, 2)
        if try next.step(), abs(next.double(0) - q.usedPercent) < 0.001 {
            try recordQuotaConfirmation(q, provider: provider)
            return
        }

        let stmt = try db.prepare("""
            INSERT INTO quota_snapshots(observed_at,provider,window_id,label,used_percent,window_minutes,resets_at,plan_type)
            VALUES(?1,?2,?3,?4,?5,?6,?7,?8)
            """)
        stmt.bind(q.observedAt.timeIntervalSince1970, 1)
        stmt.bind(provider, 2)
        stmt.bind(q.id, 3)
        stmt.bind(q.label, 4)
        stmt.bind(q.usedPercent, 5)
        stmt.bind(q.windowMinutes, 6)
        stmt.bind(q.resetsAt?.timeIntervalSince1970, 7)
        stmt.bind(q.planType, 8)
        _ = try stmt.step()
        try recordQuotaConfirmation(q, provider: provider)
    }

    public struct QuotaPoint: Equatable {
        public var observedAt: Date
        public var usedPercent: Double
        public var resetsAt: Date?
    }

    /// Newest snapshot per window.
    /// The current reading for each window — exactly one row per window.
    ///
    /// The `MAX(observed_at)` join is only single-valued if no two snapshots of
    /// a window share a timestamp, and they do: a provider that stamps several
    /// readings within the same second is normal, and before the snapshot dedup
    /// was fixed it was rampant. Every duplicate at the newest timestamp came
    /// back as its own row, so one window was reported two or three times — a
    /// repeated quota koma on the board, and a repeated block in `--verify`.
    ///
    /// Picking the highest `rowid` among the tied rows makes it the
    /// last-written one, which is the reading that arrived most recently.
    public func latestQuotas() throws -> [(window: QuotaWindow, provider: String)] {
        let stmt = try db.prepare("""
            SELECT q.provider, q.window_id, q.label, q.used_percent, q.window_minutes, q.resets_at, q.observed_at, q.plan_type
            FROM quota_snapshots q
            JOIN (
              SELECT window_id, MAX(rowid) r FROM quota_snapshots
              WHERE (window_id, observed_at) IN (
                SELECT window_id, MAX(observed_at) FROM quota_snapshots GROUP BY window_id
              )
              GROUP BY window_id
            ) t ON t.r = q.rowid
            """)
        var out: [(QuotaWindow, String)] = []
        while try stmt.step() {
            let w = QuotaWindow(
                id: stmt.str(1) ?? "?",
                label: stmt.str(2) ?? "?",
                usedPercent: stmt.double(3),
                windowMinutes: stmt.int(4),
                resetsAt: stmt.isNull(5) ? nil : Date(timeIntervalSince1970: stmt.double(5)),
                observedAt: Date(timeIntervalSince1970: stmt.double(6)),
                planType: stmt.str(7)
            )
            out.append((w, stmt.str(0) ?? "?"))
        }
        return out
    }

    /// History of one window, oldest first. Feeds the burn-rate engine.
    public func quotaHistory(windowId: String) throws -> [QuotaPoint] {
        let stmt = try db.prepare("""
            SELECT observed_at, used_percent, resets_at FROM quota_snapshots
            WHERE window_id=?1 ORDER BY observed_at
            """)
        stmt.bind(windowId, 1)
        var out: [QuotaPoint] = []
        while try stmt.step() {
            out.append(QuotaPoint(
                observedAt: Date(timeIntervalSince1970: stmt.double(0)),
                usedPercent: stmt.double(1),
                resetsAt: stmt.isNull(2) ? nil : Date(timeIntervalSince1970: stmt.double(2))
            ))
        }
        return out
    }

    // MARK: - Settings

    public func setting(_ key: String) -> String? {
        guard let stmt = try? db.prepare("SELECT value FROM settings WHERE key=?1") else { return nil }
        stmt.bind(key, 1)
        guard let row = try? stmt.step(), row else { return nil }
        return stmt.str(0)
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        let stmt = try db.prepare("""
            INSERT INTO settings(key,value) VALUES(?1,?2)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """)
        stmt.bind(key, 1); stmt.bind(value, 2)
        _ = try stmt.step()
    }

    /// Retention: delete events older than the configured window. Default 90 days;
    /// "forever" deletes nothing.
    public func applyRetention() throws {
        let days = Int(setting("retention_days") ?? "90") ?? 90
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        let stmt = try db.prepare("DELETE FROM events WHERE ts IS NOT NULL AND ts < ?1")
        stmt.bind(cutoff, 1)
        _ = try stmt.step()
    }

    /// One-click privacy: every stored byte of analytics, gone.
    public func deleteAllData() throws {
        try db.transaction {
            try db.exec("DELETE FROM events")
            try db.exec("DELETE FROM quota_snapshots")
            try db.exec("DELETE FROM checkpoints")
            let confirmations = try db.prepare(
                "DELETE FROM settings WHERE substr(key,1,length(?1))=?1"
            )
            confirmations.bind(Self.quotaConfirmationPrefix, 1)
            _ = try confirmations.step()
        }
    }

}
