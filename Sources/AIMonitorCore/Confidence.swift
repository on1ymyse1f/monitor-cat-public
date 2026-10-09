import Foundation

/// How much weight a number deserves.
///
/// Every figure this tool reports carries one of these. The point is that a
/// missing number and a reconstructed number are different things, and neither
/// should be printed as if it were read off an invoice.
public enum Confidence: String, Codable, Sendable, CaseIterable {
    /// Read directly from the provider's own accounting, with no arithmetic
    /// that could drift and no records we had to guess a dedup key for.
    case exact

    /// Reconstructed from logs. The arithmetic is validated, but the source
    /// permits a class of error we cannot rule out — the note attached to the
    /// figure says which one.
    case estimated

    /// Not derivable from anything on this machine. Reported as absent, never
    /// as zero: a zero is a claim, and this is the absence of one.
    case unavailable

    /// Worst-wins. A total is only as trustworthy as its weakest input.
    public static func combine(_ values: [Confidence]) -> Confidence {
        if values.isEmpty { return .unavailable }
        if values.contains(.unavailable) { return .unavailable }
        if values.contains(.estimated) { return .estimated }
        return .exact
    }

    public var marker: String {
        switch self {
        case .exact: return "exact"
        case .estimated: return "est."
        case .unavailable: return "n/a"
        }
    }
}
