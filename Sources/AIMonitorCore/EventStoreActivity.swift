import Foundation

extension EventStore {
    // MARK: - Live counters

    /// One conversation that is writing right now, with its own numbers.
    ///
    /// Every figure on this row is measured over the same thing — this session.
    /// The original shape could not promise that: it carried one session's
    /// lifetime total *and* a machine-wide rate, so two tools running at once
    /// printed "693.7k this session · 614.6k/min" — a rate that would spend the
    /// whole session inside a minute. Both numbers were individually correct
    /// and the line they formed was false. Scope belongs to the row.
    public struct LiveSession: Sendable, Equatable, Identifiable {
        public var sessionId: String
        public var provider: String
        public var model: String?
        /// Directory slug, when the tool records one. Two conversations in the
        /// same tool are otherwise indistinguishable on screen.
        public var project: String?
        /// Everything this conversation has spent over its whole life, not
        /// only the part inside the burst window — "how much has this cost so
        /// far" is what a live counter is asked for.
        public var billable: Int
        /// What it spent inside the burst window: the numerator of the rate.
        public var recentBillable: Int
        /// Nil when nothing in the session priced — never a guessed zero.
        public var costUSD: Double?
        /// Tokens per minute for *this* session, over the span its own events
        /// actually cover. Nil when it wrote nothing in the window.
        public var tokensPerMinute: Double?
        public var startedAt: Date?
        public var lastEventAt: Date
        /// How far ahead of the local clock this session's newest record is
        /// stamped. Zero for everything written by this machine.
        ///
        /// Imported sessions and clock drift can make a record appear newer
        /// than the local clock. The dashboard exposes the skew so a clamped
        /// age is not mistaken for a fresh update.
        public var clockSkew: TimeInterval
        /// Kept separately from the rounded caption value. A timestamp 121
        /// seconds ahead rounds to "2m", but it is still outside the two-minute
        /// trust boundary and must not become live merely because of display
        /// quantization.
        public var clockDisagrees: Bool
        public var isLive: Bool

        /// Session ids are provider-local. Qualifying the row identity keeps a
        /// Claude conversation and a Codex conversation with the same raw id
        /// from collapsing into one SwiftUI row.
        public var id: String { provider + "\u{1F}" + sessionId }
    }

    /// What is happening right now, for the running counter on the dashboard.
    ///
    /// "Real time" here has a floor set by somebody else: a token is visible
    /// once the tool writes it to its log. Claude Code flushes per assistant
    /// message, Codex per `token_count` event. So this is a live read of a
    /// source that updates in bursts, and the honest presentation is a counter
    /// that steps when the log steps — not one that animates smoothly between
    /// values it has not been told about yet.
    public struct LiveCounters: Sendable, Equatable {
        /// The conversations still writing inside `liveWindow`, newest first,
        /// at most `limit` of them. When none is live, one last idle session is
        /// retained as context (unless `limit` is zero).
        ///
        /// One row per *session* rather than per tool. Per-tool was the first
        /// fix and it still lied by omission: three Claude Code windows open at
        /// once collapsed into one row whose "this session" total was one of
        /// the three, with a `×3` badge beside it that no arithmetic connected
        /// to the number it sat next to. A row that says "this session" has to
        /// be one session. The bounded list keeps concurrent sessions
        /// distinguishable without letting one provider hide the others.
        ///
        public var sessions: [LiveSession]
        /// How many sessions are actually live, including any the list was
        /// capped short of. The wider rate window does not inflate this count.
        public var liveSessionCount: Int
        /// Tokens in the burst window across every session.
        public var recentBillable: Int
        /// The window `recentBillable` was measured over.
        public var window: TimeInterval
        /// Machine-wide tokens per minute: the sum of what every tool is
        /// spending. It belongs to the machine, never to one row — presenting
        /// it beside a single session's total is the bug described above.
        public var tokensPerMinute: Double?
        public var lastEventAt: Date?

        /// A session is "live" while its last event is inside this. Two minutes
        /// rather than seconds because a turn spends most of its wall time
        /// waiting on the model, and a counter that drops to idle mid-thought
        /// is worse than one that lingers.
        public static let liveWindow: TimeInterval = 120

        /// How many recent sessions the dashboard asks for by default.
        public static let defaultLimit = 4

        /// Anything still writing, even when a caller requested zero rows.
        public var isLive: Bool { liveSessionCount > 0 }

        /// Sessions the list is not carrying. Never left unsaid on screen —
        /// a silent cap reads as "this is all of it", which is the same
        /// omission this type was reshaped to stop making.
        public var hiddenSessions: Int {
            max(0, liveSessionCount - sessions.filter(\.isLive).count)
        }

        /// The conversation that wrote most recently. For the callers that
        /// genuinely want one — the terminal's single-line counter — rather
        /// than as the default way to read this.
        public var active: LiveSession? { sessions.first }
        public var activeSessionId: String? { active?.sessionId }
        public var activeProvider: String? { active?.provider }
        public var activeModel: String? { active?.model }
        public var activeSessionBillable: Int { active?.billable ?? 0 }
        public var activeSessionStartedAt: Date? { active?.startedAt }
    }

    public func liveCounters(
        now: Date = Date(),
        window: TimeInterval = 300,
        limit: Int = LiveCounters.defaultLimit
    ) throws -> LiveCounters {
        let windowStart = now.addingTimeInterval(-window)
        let liveStart = now.addingTimeInterval(-LiveCounters.liveWindow)
        let trustedEnd = now.addingTimeInterval(LiveCounters.liveWindow)
        let rowLimit = max(0, limit)
        var out = LiveCounters(sessions: [], liveSessionCount: 0, recentBillable: 0, window: window)

        // `lastEventAt` answers whether the store has history and how long the
        // whole machine has been idle. Restricting it to the rate window made a
        // day-old populated store indistinguishable from a first-run empty one.
        let latestEvent = try db.prepare("""
            SELECT ts FROM events
            WHERE event_type = 'usage' AND ts IS NOT NULL
            ORDER BY ts DESC LIMIT 1
            """)
        if try latestEvent.step() {
            out.lastEventAt = Date(timeIntervalSince1970: latestEvent.double(0))
        }

        // A modest future skew is tolerated; a record tens of minutes ahead is
        // not evidence about the last five minutes and cannot contribute to a
        // rate until the local clock catches up.
        let burst = try db.prepare("""
            SELECT COALESCE(SUM(billable), 0) FROM events
            WHERE event_type = 'usage' AND ts IS NOT NULL AND ts >= ?1 AND ts <= ?2
            """)
        burst.bind(windowStart.timeIntervalSince1970, 1)
        burst.bind(trustedEnd.timeIntervalSince1970, 2)
        if try burst.step() {
            out.recentBillable = burst.int(0)
        }
        if out.recentBillable > 0 {
            out.tokensPerMinute = Double(out.recentBillable) / (window / 60)
        }

        struct Head { let session: String; let provider: String; let project: String?; let last: Date }
        var heads: [Head] = []

        let liveCount = try db.prepare("""
            SELECT COUNT(*) FROM (
                SELECT provider, session_id FROM events
                WHERE event_type = 'usage' AND ts IS NOT NULL AND session_id IS NOT NULL
                  AND ts > ?1 AND ts <= ?2
                GROUP BY provider, session_id
            )
            """)
        liveCount.bind(liveStart.timeIntervalSince1970, 1)
        liveCount.bind(trustedEnd.timeIntervalSince1970, 2)
        if try liveCount.step() { out.liveSessionCount = liveCount.int(0) }

        if rowLimit > 0, out.liveSessionCount > 0 {
            let live = try db.prepare("""
                SELECT session_id, provider, project, MAX(ts) FROM events
                WHERE event_type = 'usage' AND ts IS NOT NULL AND session_id IS NOT NULL
                  AND ts > ?1 AND ts <= ?2
                GROUP BY provider, session_id ORDER BY MAX(ts) DESC LIMIT ?3
                """)
            live.bind(liveStart.timeIntervalSince1970, 1)
            live.bind(trustedEnd.timeIntervalSince1970, 2)
            live.bind(rowLimit, 3)
            while try live.step() {
                guard let session = live.str(0) else { continue }
                heads.append(Head(
                    session: session, provider: live.str(1) ?? "?", project: live.str(2),
                    last: Date(timeIntervalSince1970: live.double(3))
                ))
            }
        }

        // Nothing live: fall back to the last session the store saw.
        // An idle machine still has a last conversation, and its total is a
        // real answer to "what did that cost" — it just is not live, and it is
        // not counted as one either.
        if out.liveSessionCount == 0, rowLimit > 0 {
            let latest = try db.prepare("""
                SELECT session_id, provider, project, ts FROM events
                WHERE event_type = 'usage' AND ts IS NOT NULL AND session_id IS NOT NULL
                ORDER BY ts DESC LIMIT 1
                """)
            if try latest.step(), let session = latest.str(0) {
                heads.append(Head(
                    session: session, provider: latest.str(1) ?? "?", project: latest.str(2),
                    last: Date(timeIntervalSince1970: latest.double(3))
                ))
            }
        }

        let totals = try db.prepare("""
            SELECT COALESCE(SUM(billable), 0), MIN(ts), SUM(cost_usd),
                   COALESCE(SUM(CASE WHEN ts >= ?3 AND ts <= ?4 THEN billable ELSE 0 END), 0)
            FROM events
            WHERE event_type = 'usage' AND session_id = ?1 AND provider = ?2
            """)
        // The newest model that actually *billed*, not the newest model.
        //
        // Claude Code writes `<synthetic>` records — locally generated turns,
        // zero tokens, deliberately unpriced. There are seven in this store.
        // Whichever record happens to be last decides the label, so a session
        // that ended on one of those would have introduced itself as
        // "Claude Code · <synthetic>" while spending Opus money.
        let named = try db.prepare("""
            SELECT model FROM events
            WHERE event_type = 'usage' AND session_id = ?1 AND provider = ?2
              AND model IS NOT NULL AND billable > 0
            ORDER BY ts DESC LIMIT 1
            """)

        for head in heads {
            totals.reset()
            totals.bind(head.session, 1)
            totals.bind(head.provider, 2)
            totals.bind(windowStart.timeIntervalSince1970, 3)
            totals.bind(trustedEnd.timeIntervalSince1970, 4)
            guard try totals.step() else { continue }
            let billable = totals.int(0)
            let startedAt = totals.isNull(1) ? nil : Date(timeIntervalSince1970: totals.double(1))
            let cost = totals.isNull(2) ? nil : totals.double(2)
            let recent = totals.int(3)

            named.reset()
            named.bind(head.session, 1)
            named.bind(head.provider, 2)
            let model = (try named.step()) ? named.str(0) : nil

            let rawSkew = head.last.timeIntervalSince(now)
            let clockDisagrees = rawSkew > LiveCounters.liveWindow

            out.sessions.append(LiveSession(
                sessionId: head.session, provider: head.provider, model: model,
                project: head.project, billable: billable, recentBillable: recent,
                costUSD: cost,
                tokensPerMinute: Self.rate(recentBillable: recent, startedAt: startedAt,
                                           lastEventAt: head.last, windowStart: windowStart, now: now),
                startedAt: startedAt, lastEventAt: head.last,
                clockSkew: Self.quantizedSkew(of: head.last, now: now),
                clockDisagrees: clockDisagrees,
                isLive: !clockDisagrees
                    && StoreReport.age(of: head.last, now: now) < LiveCounters.liveWindow
            ))
        }
        return out
    }

    /// How far ahead of the local clock a record is stamped, rounded down to
    /// the minute the caption can actually show.
    ///
    /// The rounding is not cosmetic either. `LiveCounters` is `Equatable` so
    /// that an unchanged reading does not re-publish and redraw the page — the
    /// same care that took the idle cost from 14.5% of a core to 2.0%. A raw
    /// skew is `lastEvent - now`, which moves every time `now` does, so one
    /// future-stamped session would have made every tick look like new data
    /// for as long as it sat there. Quantized, it changes once a minute,
    /// which is exactly as often as the text does.
    /// Rounds to the nearest minute rather than down. Flooring looks like the
    /// conservative choice and is the brittle one: a timestamp exactly 58
    /// minutes ahead comes back from SQLite as 3479.9999999 seconds, which
    /// floors to 57 and makes the caption flicker between two values for the
    /// same instant. This test suite caught it as an intermittent failure.
    static func quantizedSkew(of date: Date, now: Date) -> TimeInterval {
        let raw = date.timeIntervalSince(now)
        guard raw >= 60 else { return 0 }
        return (raw / 60).rounded() * 60
    }

    /// Tokens per minute over the span the session's events actually cover.
    ///
    /// Dividing by the nominal window regardless is what the old code did, and
    /// it understates every young session: a conversation forty seconds old
    /// that has spent 400k reads as 80k/min, a fifth of what is happening. The
    /// span is therefore measured from whichever is later — the window's edge
    /// or the session's first event.
    ///
    /// The one-minute floor is not cosmetic. The divisor is wall time between
    /// two log writes, so a session whose entire visible life is one burst a
    /// few seconds wide would otherwise divide by that and report millions per
    /// minute. Below a minute of evidence, "tokens in the last minute" is the
    /// most the measurement supports, and that is what it says.
    static func rate(
        recentBillable: Int, startedAt: Date?, lastEventAt: Date,
        windowStart: Date, now: Date
    ) -> Double? {
        guard recentBillable > 0 else { return nil }
        let start = max(startedAt ?? windowStart, windowStart)
        // A log timestamp is not guaranteed to be behind this clock — see
        // `StoreReport.age` — and an end before the start would invert the rate.
        let end = max(now, lastEventAt)
        let span = max(60, end.timeIntervalSince(start))
        return Double(recentBillable) / (span / 60)
    }

    // MARK: - Activity timeline

    /// One stretch of continuous work, rather than one accounting record.
    public struct ActivitySpan: Sendable, Equatable {
        public var startedAt: Date
        public var endedAt: Date
        public var provider: String
        public var model: String?
        public var project: String?
        public var sessionId: String?
        public var billable: Int
        public var costUSD: Double?
        /// Accounting records folded into this span.
        public var events: Int

        public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    }

    /// The timeline, grouped into spans of continuous work.
    ///
    /// The raw event stream is the wrong unit for a timeline: Claude Code writes
    /// a record per assistant message and Codex writes one per `token_count`.
    /// Rendering every record as a row can obscure the stretches of work a user
    /// is trying to understand.
    ///
    /// A span breaks when the session changes, the model changes, or the work
    /// pauses for longer than `gap`. That is the same rule a person would use
    /// reading the log: same conversation, same model, no long silence.
    public func recentActivity(
        limit: Int = 60,
        provider: String? = nil,
        gap: TimeInterval = 300,
        scanLimit: Int = 4000
    ) throws -> [ActivitySpan] {
        let stmt = try db.prepare("""
            SELECT ts, provider, model, billable, project, session_id, cost_usd FROM events
            WHERE event_type = 'usage' AND ts IS NOT NULL \(provider != nil ? "AND provider = ?2" : "")
            ORDER BY ts DESC LIMIT ?1
            """)
        stmt.bind(scanLimit, 1)
        if let provider { stmt.bind(provider, 2) }

        // Grouped per (session, provider, model) rather than by walking the
        // stream in order. Two tools running at once interleave in `ts`, and a
        // single-pass walk breaks the span every time the other one writes —
        // which would otherwise split a session's span whenever another tool
        // writes an event.
        struct Key: Hashable { let session: String?; let provider: String; let model: String? }
        var byKey: [Key: [ActivitySpan]] = [:]

        while try stmt.step() {
            let ts = Date(timeIntervalSince1970: stmt.double(0))
            let key = Key(session: stmt.str(5), provider: stmt.str(1) ?? "?", model: stmt.str(2))
            let billable = stmt.int(3)
            let cost = stmt.isNull(6) ? nil : stmt.double(6)

            // Rows arrive newest-first, so the open span for this key is the
            // one whose start is closest to the row being folded in.
            if var open = byKey[key]?.last, open.startedAt.timeIntervalSince(ts) <= gap {
                open.startedAt = ts
                open.billable += billable
                open.events += 1
                if let cost { open.costUSD = (open.costUSD ?? 0) + cost }
                byKey[key]![byKey[key]!.count - 1] = open
            } else {
                byKey[key, default: []].append(ActivitySpan(
                    startedAt: ts, endedAt: ts, provider: key.provider, model: key.model,
                    project: stmt.str(4), sessionId: key.session, billable: billable,
                    costUSD: cost, events: 1
                ))
            }
        }

        return byKey.values.flatMap { $0 }
            .sorted { $0.endedAt > $1.endedAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Late model attribution

    /// Fills in the model for events from one file that were stored before the
    /// file said which model it was running, and reprices them.
    ///
    /// Codex announces the model in a `turn_context` line, and a **subagent
    /// rollout may not emit one until after its first turns. Events before that
    /// point can initially lack a model and therefore a matching price. The
    /// file's later model context lets the store fill in only missing labels.
    ///
    /// Only NULL models are touched. An event that already named a model keeps
    /// it, so a genuine mid-session model switch is never rewritten backwards.
    @discardableResult
    public func attributeMissingModel(idPrefix: String, model: String, now: Date = Date()) throws -> Int {
        let select = try db.prepare("""
            SELECT id, ts, speed, uncached_input, cached_input, cache_write_5m,
                   cache_write_1h, cache_write_unspecified, output, reasoning
            FROM events
            WHERE model IS NULL AND event_type = 'usage' AND id LIKE ?1 ESCAPE '\\'
            """)
        // The prefix is a filename, which may legitimately contain _ or %.
        let escaped = idPrefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        select.bind(escaped + "%", 1)

        struct Row { let id: String; let ts: Date?; let speed: String?; let tokens: TokenBreakdown }
        var rows: [Row] = []
        while try select.step() {
            rows.append(Row(
                id: select.str(0) ?? "",
                ts: select.isNull(1) ? nil : Date(timeIntervalSince1970: select.double(1)),
                speed: select.str(2),
                tokens: TokenBreakdown(
                    uncachedInput: select.int(3), cachedInput: select.int(4),
                    cacheWrite5m: select.int(5), cacheWrite1h: select.int(6),
                    cacheWriteUnspecified: select.int(7),
                    output: select.int(8), reasoning: select.int(9)
                )
            ))
        }
        guard !rows.isEmpty else { return 0 }

        try db.transaction {
            let update = try db.prepare("UPDATE events SET model = ?1, cost_usd = ?2 WHERE id = ?3")
            for row in rows {
                let cost = PricingTable.cost(of: row.tokens, model: model, speed: row.speed, asOf: row.ts ?? now)
                update.reset()
                update.bind(model, 1)
                update.bind(cost.map { NSDecimalNumber(decimal: $0).doubleValue }, 2)
                update.bind(row.id, 3)
                _ = try update.step()
            }
        }
        return rows.count
    }

    // MARK: - Interval sums

    /// Billable tokens for one provider in `[from, to)`, with the model that
    /// contributed most of them and its share.
    ///
    /// The dominant model matters because quota is not consumed at one rate per
    /// token: an Opus request and a Haiku request move the same window by
    /// different amounts. An interval where one model did nearly all the work
    /// is comparable to another such interval; a mixed one is not comparable to
    /// anything, and gets dropped rather than averaged.
    public func billableInterval(
        provider: String, from: Date, to: Date
    ) throws -> (billable: Int, dominantModel: String?, dominantShare: Double) {
        let stmt = try db.prepare("""
            SELECT model, SUM(billable) FROM events
            WHERE provider = ?1 AND event_type = 'usage'
              AND ts IS NOT NULL AND ts >= ?2 AND ts < ?3
            GROUP BY model ORDER BY SUM(billable) DESC
            """)
        stmt.bind(provider, 1)
        stmt.bind(from.timeIntervalSince1970, 2)
        stmt.bind(to.timeIntervalSince1970, 3)

        var total = 0
        var top: (String?, Int)?
        while try stmt.step() {
            let n = stmt.int(1)
            total += n
            if top == nil { top = (stmt.str(0), n) }
        }
        guard total > 0, let top else { return (0, nil, 0) }
        return (total, top.0, Double(top.1) / Double(total))
    }

}

// MARK: - Self-audit support

extension EventStore {
    /// Shape of every text column, for the privacy self-check.
    ///
    /// Deliberately measures *shape* — longest value, how many contain
    /// whitespace — rather than scanning for keywords. Prose is recognisable by
    /// being long and containing spaces; a keyword scan would only ever find
    /// the words somebody thought to look for.
    public func textColumnShape() throws -> [ColumnShape] {
        var out: [ColumnShape] = []
        for column in ["id", "source", "provider", "application", "model", "session_id", "project", "confidence", "speed"] {
            // Column names are from this fixed list, never from input.
            let stmt = try db.prepare("""
                SELECT COALESCE(MAX(LENGTH(\(column))), 0),
                       COUNT(DISTINCT \(column)),
                       COALESCE(SUM(CASE WHEN LENGTH(\(column)) > 120 AND \(column) LIKE '% % %' THEN 1 ELSE 0 END), 0)
                FROM events
                """)
            if try stmt.step() {
                out.append(ColumnShape(
                    column: column, longest: stmt.int(0),
                    distinctValues: stmt.int(1), proseShaped: stmt.int(2)
                ))
            }
        }
        return out
    }

    public struct ColumnShape: Sendable, Equatable {
        public var column: String
        public var longest: Int
        /// How many different values the column ever holds.
        ///
        /// This is what separates a vocabulary from free text. `provider` holds
        /// three values — "Claude Code", "Codex CLI", "Kimi Code" — and all of
        /// them contain a space, which is why a naive "does it contain a space"
        /// test flagged ordinary provider labels as prose. A fixed label is
        /// not a sentence no matter how many words it has.
        public var distinctValues: Int
        /// Values long enough *and* multi-word enough to be a sentence.
        public var proseShaped: Int

        /// Fewer than this many distinct values means the column is a label
        /// set, not free text.
        public var isVocabulary: Bool { distinctValues <= 32 }
    }
}
