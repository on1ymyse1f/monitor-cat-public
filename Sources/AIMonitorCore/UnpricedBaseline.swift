import Foundation

/// Which models the pricing table does not cover, and which of those are news.
///
/// The list of unpriced models is already computed — a model absent from the
/// table produces no cost and lands in the report. The problem is that the list
/// is *always non-empty*: `<synthetic>`, `codex-auto-review`, and every model a
/// provider ships without publishing a rate sit in it permanently. A signal
/// that is always on is not a signal, so the one line that actually matters —
/// **a model started appearing in your logs and nothing prices it** — arrives
/// buried among entries the user already decided to ignore.
///
/// This is the baseline mechanism that lets detect-secrets run on a repository
/// with a thousand pre-existing findings: record the known set once, then
/// report only what is not in it. Here it doubles as a staleness alarm for the
/// pricing table, because "a new model is unpriced" and "the table needs
/// updating" are the same event.
///
/// The baseline is *acknowledgement*, never suppression of the number: an
/// acknowledged model's tokens are still counted, still excluded from cost, and
/// still listed under `--unpriced`. What the baseline changes is whether it is
/// reported as **new**.
public struct UnpricedBaseline: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    /// When the baseline was taken, for the report to say how old it is.
    public var recordedAt: Date
    /// `provider/model` keys. Provider-qualified because the same model id
    /// reaching the table through two providers is two facts, not one.
    public var acknowledged: Set<String>

    public static let supportedSchema = 1

    public init(recordedAt: Date = Date(), acknowledged: Set<String> = []) {
        self.schemaVersion = Self.supportedSchema
        self.recordedAt = recordedAt
        self.acknowledged = acknowledged
    }

    public static func key(provider: String, model: String) -> String { "\(provider)/\(model)" }

    /// `AIMONITOR_BASELINE=<path>` redirects the baseline, which is what makes
    /// this testable without writing into the running user's real config.
    public static var defaultURL: URL {
        if let explicit = ProcessInfo.processInfo.environment["AIMONITOR_BASELINE"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIMonitor/unpriced-baseline.json")
    }

    /// Reads the baseline, or an empty one. A missing file is the normal state
    /// for a user who has never taken a baseline, not an error — it just means
    /// everything currently unpriced counts as new.
    public static func load(from url: URL = defaultURL) -> UnpricedBaseline {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.iso8601.decode(UnpricedBaseline.self, from: data),
              decoded.schemaVersion <= supportedSchema
        else { return UnpricedBaseline(recordedAt: .distantPast) }
        return decoded
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// One model the store holds usage for and the table has no rate for.
public struct UnpricedModel: Sendable, Equatable {
    public var provider: String
    public var model: String
    public var billable: Int
    public var requests: Int
    public var lastSeen: Date?

    public var key: String { UnpricedBaseline.key(provider: provider, model: model) }

    /// Locally-generated ids are unpriced *by design* — there is no upstream
    /// rate to be missing. They are surfaced but never counted as news, so a
    /// user who has never taken a baseline is not greeted by a false alarm.
    public var isSyntheticByDesign: Bool { model.hasPrefix("<") || model.isEmpty }
}

public struct UnpricedScan: Sendable {
    public var models: [UnpricedModel]
    public var baseline: UnpricedBaseline

    /// Models that are unpriced, not acknowledged, and not synthetic. This is
    /// the only part anyone needs to read.
    public var newlyUnpriced: [UnpricedModel] {
        models.filter { !$0.isSyntheticByDesign && !baseline.acknowledged.contains($0.key) }
    }

    public var acknowledged: [UnpricedModel] {
        models.filter { $0.isSyntheticByDesign || baseline.acknowledged.contains($0.key) }
    }

    /// A baseline built from everything currently unpriced.
    public func asBaseline(now: Date = Date()) -> UnpricedBaseline {
        UnpricedBaseline(
            recordedAt: now,
            acknowledged: Set(models.filter { !$0.isSyntheticByDesign }.map(\.key))
        )
    }
}
