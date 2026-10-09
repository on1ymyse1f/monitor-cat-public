import Foundation

/// Claude subscription quota read from the desktop app's own local cache.
///
/// The Claude desktop app records the very numbers its usage popover shows —
/// 5-hour and weekly window percentages — into a plain JSON file it refreshes
/// on its own schedule:
///
///   ~/Library/Application Support/Claude/plan-usage-history.json
///
/// ```json
/// { "version": 2,
///   "samples": [ { "t": 1700000000000, "org": "…",
///                  "u": { "fh": 40, "sd": 20, "xu": 70.0 } }, … ] }
/// ```
///
/// **Why this exists alongside `ClaudeQuotaProvider`.** That provider reads an
/// OAuth token from the Keychain and calls Anthropic directly. It cannot work
/// for anyone signed in through an API key or a third-party gateway — there is
/// no `claudeAiOauth` token to find. This file is written by the desktop app
/// independently of the sign-in method. It is also **offline and
/// credential-free**: no token is read and no request is made. The app prefers
/// this source and only falls back to the opt-in Keychain endpoint when the
/// file is absent (for example, when the desktop app is not installed).
///
/// Fields:
///   * `fh` — five-hour window, percent used (0–100).
///   * `sd` — seven-day ("weekly · all models") window, percent used.
///   * `xu` — usage-credit spend percent. **Not a rate-limit window** (it is
///     the $-credit meter), so it is deliberately *not* emitted as a quota.
///
/// The file carries no reset timestamps, so `resetsAt` stays `nil` — this
/// project reports what it can prove and never manufactures a reset time.
public struct ClaudeDesktopQuota: Sendable {
    public static let providerName = ClaudeQuotaProvider.providerName   // "Claude"

    public enum ReadError: Error, Equatable {
        case fileAbsent
        case unreadable
        case noSamples
        case stale(Date)
    }

    public let fileURL: URL
    /// Hard ceiling on a sample's age, whatever window it describes.
    ///
    /// This is a backstop, not the real rule. The real rule is per window and
    /// lives in `QuotaWindow.staleness(now:)`, because how long a reading stays
    /// meaningful depends on the length of the window it is a percentage of.
    ///
    /// The previous default here was six hours — **longer than the five-hour
    /// window itself**. The desktop app's cache file survives the app quitting,
    /// so a machine with Claude closed since lunchtime kept showing lunchtime's
    /// percentage as the current one. That is the bug this pair of rules fixes.
    public let maxAge: TimeInterval

    public init(fileURL: URL? = nil, maxAge: TimeInterval = 24 * 3600) {
        self.fileURL = fileURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        self.maxAge = maxAge
    }

    /// Reads the newest sample and maps it onto quota windows. Synchronous and
    /// offline — a bounded local file read, safe to call off the main thread.
    public func read(now: Date = Date()) -> Result<[QuotaWindow], ReadError> {
        guard let data = try? Data(contentsOf: fileURL) else { return .failure(.fileAbsent) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]]
        else { return .failure(.unreadable) }

        // Newest by timestamp — the file appends, but sorting is cheap and makes
        // the read order-independent.
        guard let latest = samples.max(by: { ($0.double("t") ?? 0) < ($1.double("t") ?? 0) }),
              let ms = latest.double("t")
        else { return .failure(.noSamples) }

        let observedAt = Date(timeIntervalSince1970: ms / 1000)
        if now.timeIntervalSince(observedAt) > maxAge { return .failure(.stale(observedAt)) }

        guard let u = latest.dict("u") else { return .failure(.noSamples) }

        var windows: [QuotaWindow] = []
        if let fh = u.double("fh") {
            windows.append(QuotaWindow(
                id: "claude-desktop-fh", label: "5h", usedPercent: fh,
                windowMinutes: 300, resetsAt: nil, observedAt: observedAt, planType: "desktop"
            ))
        }
        if let sd = u.double("sd") {
            windows.append(QuotaWindow(
                id: "claude-desktop-weekly", label: "weekly", usedPercent: sd,
                windowMinutes: 10080, resetsAt: nil, observedAt: observedAt, planType: "desktop"
            ))
        }
        // Each window ages at its own speed. One sample can be perfectly good
        // as a weekly figure and already meaningless as a 5-hour one — after
        // three hours the weekly window has moved 1.8% and the 5-hour window
        // has turned over more than half. Dropping them together on one
        // threshold is what let a stale five-hour reading pose as current.
        let usable = windows.filter { $0.staleness(now: now) != .expired(now.timeIntervalSince(observedAt)) }
        return usable.isEmpty ? .failure(.stale(observedAt)) : .success(usable)
    }
}
