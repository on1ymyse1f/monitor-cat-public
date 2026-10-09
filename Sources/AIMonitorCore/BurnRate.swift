import Foundation

/// Projects when a quota window will be exhausted, from observed quota
/// snapshots. Conservative by design:
///
///   * needs at least two observations inside the **current** window
///   * observations must span a minimum duration — a two-minute spread says
///     nothing about a weekly budget
///   * a decreasing usage reading means a reset happened; history before it is
///     discarded
///   * no prediction when the observed burn rate is zero
public enum BurnRate {
    public struct Projection: Equatable {
        /// Observed burn, in percentage points per hour.
        public var percentPerHour: Double
        /// Projected exhaustion time. Nil when already past resetsAt.
        public var exhaustedAt: Date
        public var observationSpan: TimeInterval
    }

    /// Minimum spread between first and last observation before any projection
    /// is made. Scaled to the window: 10 minutes for a 5h window, longer for a
    /// weekly one, capped at 6h.
    public static func minimumSpan(windowMinutes: Int) -> TimeInterval {
        min(6 * 3600, max(600, Double(windowMinutes) * 60 * 0.02))
    }

    public static func project(
        history: [EventStore.QuotaPoint],
        windowMinutes: Int,
        resetsAt: Date?,
        now: Date = Date()
    ) -> Projection? {
        guard let resetsAt else { return nil }

        // Current window only: drop anything at/before the window's start.
        let windowStart = resetsAt.addingTimeInterval(-Double(windowMinutes) * 60)
        let points = history.filter { $0.observedAt > windowStart }
        guard points.count >= 2 else { return nil }

        // Discard history before the last decrease (a reset mid-history).
        var usable: [EventStore.QuotaPoint] = [points[points.count - 1]]
        for i in stride(from: points.count - 2, through: 0, by: -1) {
            if points[i].usedPercent > usable.last!.usedPercent { break }
            usable.append(points[i])
        }
        usable.reverse()
        guard usable.count >= 2, let first = usable.first, let last = usable.last else { return nil }

        let span = last.observedAt.timeIntervalSince(first.observedAt)
        guard span >= minimumSpan(windowMinutes: windowMinutes) else { return nil }

        let gained = last.usedPercent - first.usedPercent
        guard gained > 0.01 else { return nil }   // no observable burn — no prediction

        let rate = gained / (span / 3600)         // percent per hour
        let remaining = 100 - last.usedPercent
        let hoursLeft = remaining / rate
        let exhaustedAt = last.observedAt.addingTimeInterval(hoursLeft * 3600)

        // If the projection lands after the reset, the quota survives the window.
        guard exhaustedAt < resetsAt, exhaustedAt > now else { return nil }
        return Projection(percentPerHour: rate, exhaustedAt: exhaustedAt, observationSpan: span)
    }
}
