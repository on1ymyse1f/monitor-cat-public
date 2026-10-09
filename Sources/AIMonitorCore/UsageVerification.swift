import Foundation

/// Measures how well the log-derived token accounting agrees with the
/// provider's own independent accounting of the same consumption.
///
/// **Why this exists.** Every figure in this tool carries a confidence marker,
/// and `estimated` is currently an *assertion*: the collector declares it
/// because the source permits a class of error. That is honest but it is not a
/// measurement, and it leaves the tool's central caveat — Claude Code's
/// `input_tokens` dispute — as a permanent shrug.
///
/// The move borrowed here is the one that separates a secret scanner that
/// *finds candidates* from one that *verifies them*: do not stop at declaring a
/// confidence, go and check it against something you did not derive yourself.
///
/// **What is checked against what.** Two numbers in the logs come from
/// different places. Token counts are reconstructed here, by this code, out of
/// per-event deltas. Quota utilisation is written by the provider, already
/// reduced to a percentage of the plan — nothing in this codebase computes it.
/// So for any interval, `tokens consumed` and `quota percentage consumed` are
/// an independent pair, and their ratio should be stable. Where it is stable,
/// the reconstruction tracks the provider's own books. Where it scatters,
/// something in the reconstruction is missing events or double-counting them.
///
/// **This needs no network.** Both series are already in the store. The check
/// is arithmetic over data collected during normal syncs, so it does not touch
/// SECURITY.md's "zero network requests by default".
public enum UsageVerification {

    /// One usable stretch of quota history: a run between resets over which
    /// utilisation only increased.
    public struct Segment: Sendable, Equatable {
        public var from: Date
        public var to: Date
        public var percentConsumed: Double
        public var billable: Int
        public var dominantModel: String?
        public var dominantShare: Double

        /// Tokens the logs say were spent per point of quota the provider says
        /// was spent.
        public var tokensPerPercent: Double { Double(billable) / percentConsumed }
    }

    public struct WindowResult: Sendable {
        public var provider: String
        public var windowId: String
        public var label: String
        /// Segments found before the quality filters.
        public var segmentsFound: Int
        public var segments: [Segment]
        /// Reasons segments were dropped, counted. Printed so a thin result is
        /// explained rather than just small.
        public var rejected: [String: Int]

        public var median: Double? { UsageVerification.median(segments.map(\.tokensPerPercent)) }

        /// Spread as a fraction of the median, from the median absolute
        /// deviation. MAD rather than standard deviation because a single
        /// mis-attributed segment should not be allowed to set the error bar.
        public var relativeSpread: Double? {
            guard let m = median, m > 0, segments.count >= 3 else { return nil }
            let deviations = segments.map { abs($0.tokensPerPercent - m) }
            guard let mad = UsageVerification.median(deviations) else { return nil }
            return mad / m
        }

        /// The sentence the report prints. Deliberately refuses to produce a
        /// number when the evidence is thin — a ±x% derived from two segments
        /// would be a decoration, not a measurement.
        public var verdict: String {
            guard segments.count >= 3 else {
                return "not enough clean segments to measure (\(segments.count) of \(segmentsFound) usable; need 3)"
            }
            guard let spread = relativeSpread, let m = median else {
                return "no spread derivable from \(segments.count) segment(s)"
            }
            let pct = spread * 100
            let quality = pct < 10 ? "tracks" : pct < 25 ? "broadly tracks" : "does NOT track"
            return String(
                format: "%@ the provider's own accounting — ±%.1f%% across %d segments (median %@ tokens per quota point)",
                quality, pct, segments.count, compact(m)
            )
        }
    }

    // MARK: - Filters
    //
    // Each of these exists because the raw history contains a shape that would
    // otherwise be read as consumption when it is not.

    /// Utilisation is reported in whole percentage points, so a segment
    /// spanning a handful of them carries a rounding error of the same order as
    /// the thing being measured. Requiring a long run pushes the quantisation
    /// error down to roughly 1/N.
    public static let minimumPercentSpan: Double = 15
    /// A segment covering no wall-clock time is a replayed log, not elapsed
    /// usage. These were abundant before the snapshot dedup was fixed.
    public static let minimumWallClock: TimeInterval = 300
    /// Quota is consumed at a different rate per token by different models, so
    /// only a segment one model clearly dominates is comparable to another.
    public static let minimumDominantShare: Double = 0.9

    public static func verify(
        store: EventStore,
        provider: String,
        windowId: String,
        label: String
    ) throws -> WindowResult {
        let history = try store.quotaHistory(windowId: windowId)
        var rejected: [String: Int] = [:]
        var segments: [Segment] = []
        var found = 0

        // Split on any decrease: that is the window resetting.
        var runs: [[EventStore.QuotaPoint]] = []
        var current: [EventStore.QuotaPoint] = []
        for point in history {
            if let last = current.last, point.usedPercent < last.usedPercent {
                runs.append(current)
                current = [point]
            } else {
                current.append(point)
            }
        }
        if !current.isEmpty { runs.append(current) }

        for run in runs {
            guard let first = run.first, let last = run.last, run.count >= 2 else { continue }
            found += 1

            let percent = last.usedPercent - first.usedPercent
            guard percent >= minimumPercentSpan else {
                rejected["span under \(Int(minimumPercentSpan)) quota points", default: 0] += 1
                continue
            }
            let elapsed = last.observedAt.timeIntervalSince(first.observedAt)
            guard elapsed >= minimumWallClock else {
                rejected["no elapsed time (replayed log)", default: 0] += 1
                continue
            }

            let usage = try store.billableInterval(provider: provider, from: first.observedAt, to: last.observedAt)
            guard usage.billable > 0 else {
                rejected["quota moved but no events in the interval", default: 0] += 1
                continue
            }
            guard usage.dominantShare >= minimumDominantShare else {
                rejected["mixed models (no single model above \(Int(minimumDominantShare * 100))%)", default: 0] += 1
                continue
            }

            segments.append(Segment(
                from: first.observedAt, to: last.observedAt,
                percentConsumed: percent, billable: usage.billable,
                dominantModel: usage.dominantModel, dominantShare: usage.dominantShare
            ))
        }

        return WindowResult(
            provider: provider, windowId: windowId, label: label,
            segmentsFound: found, segments: segments, rejected: rejected
        )
    }

    /// Runs the check over every window the store has history for.
    public static func verifyAll(store: EventStore) throws -> [WindowResult] {
        var out: [WindowResult] = []
        for (window, provider) in try store.latestQuotas() {
            out.append(try verify(store: store, provider: provider, windowId: window.id, label: window.label))
        }
        return out
    }

    // MARK: - Helpers

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func compact(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "%.2fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.2fM", value / 1_000_000)
        case 1_000...: return String(format: "%.1fK", value / 1_000)
        default: return String(format: "%.0f", value)
        }
    }
}
