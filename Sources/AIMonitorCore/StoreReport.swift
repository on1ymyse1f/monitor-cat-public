import Foundation

/// Assembles everything the menu bar and the dashboard show, from the store.
/// Read-only; the SyncEngine owns writes.
public enum StoreReport {

    public struct QuotaView: Equatable {
        public var window: QuotaWindow
        public var provider: String
        public var projection: BurnRate.Projection?
    }

    public struct Dashboard {
        public var todayTokens: Int
        public var todayCostUSD: Double?     // nil = unpriced, not zero
        public var todayActiveMinutes: Int
        public var todayRequests: Int
        public var usageShares: [(provider: String, billable: Int, fraction: Double)]
        public var flow: [(bucket: Date, billable: Int)]
        public var flowIsHourly: Bool
        public var quotas: [QuotaView]
        public var generatedAt: Date
    }

    public enum FlowRange: String, CaseIterable, Sendable {
        case today = "Today", week = "7D", month = "30D", all = "All"

        public var since: Date {
            let cal = Calendar.current
            switch self {
            case .today: return cal.startOfDay(for: Date())
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())!
            case .month: return cal.date(byAdding: .day, value: -30, to: Date())!
            case .all: return Date(timeIntervalSince1970: 0)
            }
        }
    }

    /// A quota is a live account reading, not historical analytics: once no
    /// source has refreshed it for long enough, hiding it is more honest than
    /// presenting an old percentage as current.
    ///
    /// **How long is "long enough" depends on the window.** A flat threshold
    /// was the first answer here and it is the wrong shape: a quota figure is a
    /// percentage of a *rolling* window, so after `age` has passed, up to
    /// `age / window` of it has rolled off and the error the reading can carry
    /// is bounded by that ratio. Thirty minutes is aggressive for a 5-hour
    /// window and absurd for a weekly one — it threw away a perfectly good
    /// weekly figure three quarters of an hour after it was taken, which is one
    /// of the reasons quota cards kept vanishing.
    ///
    /// `QuotaWindow.staleness` carries the proportional rule; this constant
    /// survives only as the ceiling for a window that declares no length.
    public static let quotaMaximumAge: TimeInterval = 30 * 60

    public static func dashboard(
        from store: EventStore, flowRange: FlowRange = .today, now: Date = Date()
    ) throws -> Dashboard {
        let dayStart = Calendar.current.startOfDay(for: now)
        let today = try store.totals(since: dayStart)
        let minutes = try store.activeMinutes(since: dayStart)

        let providerTotals = try store.totalsByProvider(since: dayStart)
        let totalBillable = providerTotals.reduce(0) { $0 + $1.billable }
        let shares = providerTotals.map {
            ($0.provider, $0.billable, totalBillable > 0 ? Double($0.billable) / Double(totalBillable) : 0)
        }

        let flow = try store.tokenFlow(since: flowRange.since)
        let hourly = flowRange == .today

        var quotas: [QuotaView] = []
        for (window, provider) in try store.latestQuotas() {
            let history = try store.quotaHistory(windowId: window.id)
            let projection = BurnRate.project(
                history: history, windowMinutes: window.windowMinutes, resetsAt: window.resetsAt
            )
            quotas.append(QuotaView(window: window, provider: provider, projection: projection))
        }
        // Providers have been seen rotating window ids across releases while
        // keeping the same label — one card per (provider, label), keeping the
        // freshest observation. Windows past their reset with no newer snapshot
        // are stale: the number no longer means anything.
        var freshest: [String: (quota: QuotaView, confirmedAt: Date)] = [:]
        for q in quotas {
            let confirmedAt = store.quotaConfirmedAt(
                provider: q.provider, windowID: q.window.id
            ) ?? q.window.observedAt
            // Age measured from the last live confirmation, not from the
            // stored point: identical readings are deduplicated out of the
            // history, so `observedAt` stands still while a source keeps
            // confirming the same percentage every cycle.
            let age = now.timeIntervalSince(confirmedAt)
            let staleness = q.window.windowMinutes > 0
                ? QuotaWindow.staleness(ofAge: age, windowMinutes: q.window.windowMinutes)
                : (age <= quotaMaximumAge ? .live : .expired(age))
            // Two different things were being collapsed into one hide/show
            // decision here, and it cost the user the card entirely.
            //
            //   * The **reading** can go meaningless — the window rolls out
            //     from under it. That is `staleness`, and it does hide the card.
            //   * The **source** can go quiet — nothing has confirmed it
            //     lately. Hiding for that reason throws away a number that is
            //     still accurate: Kimi's token dies after fifteen minutes, so
            //     confirmations stop while the weekly figure stays perfectly
            //     good, and the card vanished within the half hour.
            //
            // A quiet source is disclosed, not hidden. The card carries its own
            // age (see `QuotaCard.staleNote`), so it never claims to be current.
            guard staleness != .expired(age),
                  q.window.resetsAt == nil || q.window.resetsAt! > now else { continue }
            let key = "\(q.provider)|\(q.window.label)"
            if let old = freshest[key],
               old.confirmedAt > confirmedAt
                || (old.confirmedAt == confirmedAt
                    && old.quota.window.observedAt >= q.window.observedAt) { continue }
            freshest[key] = (q, confirmedAt)
        }
        quotas = freshest.values.map(\.quota).sorted {
            $0.window.usedPercent > $1.window.usedPercent
        }

        return Dashboard(
            todayTokens: today.billable,
            todayCostUSD: today.costUSD,
            todayActiveMinutes: minutes,
            todayRequests: today.requests,
            usageShares: shares,
            flow: flow,
            flowIsHourly: hourly,
            quotas: quotas,
            generatedAt: now
        )
    }

    /// Tightest quota across providers — the menu bar's headline number.
    public static func tightestQuota(_ quotas: [QuotaView]) -> QuotaView? {
        quotas.max { $0.window.usedPercent < $1.window.usedPercent }
    }

    // MARK: - Formatting shared by menu bar and dashboard

    /// The project slug to put on a live row, or nil when it would be noise.
    ///
    /// Two conversations in the same tool are otherwise identical on screen —
    /// same provider, same model, two unrelated numbers — and the reader has no
    /// way to tell which window is which. The directory is what distinguishes
    /// them and the only thing worth the width. When a tool has a single row,
    /// the provider already names it and the slug is clutter, so it is dropped.
    public static func liveRowProject(
        of session: EventStore.LiveSession, among sessions: [EventStore.LiveSession]
    ) -> String? {
        let shared = sessions.contains {
            $0.sessionId != session.sessionId && $0.provider == session.provider
        }
        return shared ? session.project : nil
    }

    /// How long ago something was recorded, floored at zero.
    ///
    /// Log timestamps can be ahead of the local clock because of clock drift,
    /// server-side timestamps, or sessions synced from another machine.
    ///
    /// Subtracting without a floor is how the dashboard came to print an age of
    /// `-422s`. Negative age is never a fact about usage; it is a fact about
    /// two clocks disagreeing, and the reader is owed the first, not the second.
    public static func age(of date: Date, now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(date))
    }

    /// "12s" / "4m" / "1h 20m" — the age of a reading, never negative.
    public static func ageText(of date: Date, now: Date = Date()) -> String {
        shortDuration(age(of: date, now: now))
    }

    /// "12s" / "4m" / "1h 20m". Negative intervals read as zero.
    public static func shortDuration(_ interval: TimeInterval) -> String {
        let s = Int(max(0, interval))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    /// 4.81M / 182k / 940
    public static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.2fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    /// 3h 42m / 41m
    public static func duration(minutes: Int) -> String {
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    /// "resets in 2h 14m" / "resets Fri" — localized.
    public static func resetDescription(_ date: Date?, lang: Language = .en) -> String {
        let zh = lang.resolved == .zh
        guard let date else { return zh ? "重置时间未知" : "reset unknown" }
        let interval = date.timeIntervalSinceNow
        if interval < 0 { return zh ? "已到重置时间" : "reset due" }
        if interval < 24 * 3600 {
            let h = Int(interval) / 3600, m = (Int(interval) % 3600) / 60
            let t = h > 0 ? "\(h)h \(m)m" : "\(m)m"
            return zh ? "\(t)后重置" : "resets in \(t)"
        }
        let fmt = DateFormatter()
        fmt.locale = zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        fmt.dateFormat = "EEE"
        return zh ? "\(fmt.string(from: date))重置" : "resets \(fmt.string(from: date))"
    }
}
