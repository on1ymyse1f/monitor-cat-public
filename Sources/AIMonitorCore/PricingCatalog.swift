import Foundation

/// Where the rates in `PricingTable` actually come from.
///
/// The rates used to live only in Swift, which meant a list-price change
/// upstream could only reach a user through a rebuild. That is a real expiry
/// problem, not a hypothetical one: `claude-sonnet-5` carries an intro rate
/// that lapses 2026-09-01, and the table also goes stale every time a provider
/// ships a model.
///
/// So the table is now **data with a code fallback**, in three layers:
///
///   1. `PricingTable.builtIn*` — the verified defaults compiled in. These are
///      the floor; they always exist and always parse.
///   2. `~/Library/Application Support/AIMonitor/pricing.json` — the user's
///      override, merged over the defaults at load.
///   3. `AIMONITOR_PRICING=<path>` — an explicit file, for tests and for
///      pointing a run at a candidate table without touching the real one.
///
/// **Why not `Bundle.module`.** Shipping the defaults as a bundled resource is
/// the obvious SPM answer and the wrong one here: `Bundle.module` *traps* when
/// the resource bundle is missing, and this app is installed by a shell script
/// that hand-assembles the `.app` — a pipeline that has already shipped a build
/// with a stale bundle once (see the note in `install.sh`). Turning a missing
/// file into a crash on launch, to save re-declaring rates that must be
/// verified by hand anyway, is a bad trade. The compiled defaults cannot go
/// missing, so the load path has no failure mode that ends in a crash.
///
/// The one rule that does not bend: **a malformed or unknown entry produces no
/// rate at all**, never a guessed one. A model that fails to parse is dropped
/// and named in `problems`; a model absent from every layer stays unpriced and
/// shows up in `ScanStats.unpricedModels`. A guess would still add up, which is
/// exactly what makes it worse than a hole.
public struct PricingCatalog: Sendable {
    /// Standard per-model rates.
    public var models: [String: ModelRate]
    /// Premium rates that apply when the log says the request ran in fast mode.
    public var fastMode: [String: ModelRate]
    /// Where the effective table came from, for the report to disclose.
    public var source: Source
    /// Entries that were present but unusable. Named, never silently dropped.
    public var problems: [String]

    public enum Source: Sendable, Equatable {
        /// Compiled defaults only — no override file present.
        case builtIn
        /// Compiled defaults with an override file merged over them.
        case merged(path: String, schemaVersion: Int, updated: String?)
        /// An override file that declared `"replace": true`.
        case replaced(path: String, schemaVersion: Int, updated: String?)

        public var describedPath: String? {
            switch self {
            case .builtIn: return nil
            case .merged(let p, _, _), .replaced(let p, _, _): return p
            }
        }
    }

    public init(
        models: [String: ModelRate],
        fastMode: [String: ModelRate],
        source: Source = .builtIn,
        problems: [String] = []
    ) {
        self.models = models
        self.fastMode = fastMode
        self.source = source
        self.problems = problems
    }

    // MARK: - The effective catalog

    /// The default override location, beside the store the app already writes.
    public static var defaultOverrideURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIMonitor/pricing.json")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: PricingCatalog?

    /// The table every cost calculation resolves against. Loaded once, then
    /// reused; `reload()` re-reads it after the file changes.
    public static var current: PricingCatalog {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = load()
        cached = loaded
        return loaded
    }

    /// Re-read the override file and replace the cached table.
    @discardableResult
    public static func reload() -> PricingCatalog {
        lock.lock()
        defer { lock.unlock() }
        let loaded = load()
        cached = loaded
        return loaded
    }

    /// Install a catalog directly. Tests use this; nothing else should.
    public static func override(with catalog: PricingCatalog?) {
        lock.lock()
        defer { lock.unlock() }
        cached = catalog
    }

    private static func load() -> PricingCatalog {
        let fallback = PricingCatalog(
            models: PricingTable.builtInAnthropic
                .merging(PricingTable.builtInOpenAI) { a, _ in a }
                .merging(PricingTable.builtInKimi) { a, _ in a },
            fastMode: PricingTable.builtInFastMode,
            source: .builtIn
        )

        let env = ProcessInfo.processInfo.environment
        let url: URL
        if let explicit = env["AIMONITOR_PRICING"], !explicit.isEmpty {
            url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        } else if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil {
            // Under XCTest, the default override path is not read.
            //
            // The suite asserts exact costs — `$0.000575` for a specific token
            // breakdown — and those assertions are about the *verified* table.
            // Letting the developer's own pricing.json reach them would mean a
            // green run proves something different on every machine, and a
            // machine with an edited rate would fail tests that are fine.
            // A test that wants the override path exercises it by setting
            // AIMONITOR_PRICING at an explicit fixture, which still works here.
            return fallback
        } else {
            url = defaultOverrideURL
        }

        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        guard let data = try? Data(contentsOf: url) else {
            var out = fallback
            out.problems = ["pricing override unreadable: \(url.path)"]
            return out
        }

        do {
            let file = try JSONDecoder().decode(PricingFile.self, from: data)
            return file.applied(to: fallback, path: url.path)
        } catch {
            var out = fallback
            // A broken override must not silently become "no prices". It falls
            // back to the compiled table and says so out loud.
            out.problems = ["pricing override ignored (\(error.localizedDescription)): \(url.path)"]
            return out
        }
    }

    // MARK: - Lookup

    /// Resolves a rate for a model id, applying the same normalization rules
    /// regardless of which layer the rate came from.
    ///
    /// Dated snapshot ids (`claude-haiku-4-5-20251001`) resolve to their base
    /// alias by longest-prefix match. Synthetic and unknown ids return nil.
    public func rate(forModel model: String, speed: String?) -> ModelRate? {
        if model.hasPrefix("<") { return nil }  // e.g. "<synthetic>" — locally generated, not billed

        let normalized = model.hasPrefix("anthropic.")
            ? String(model.dropFirst("anthropic.".count))
            : model

        if speed == "fast", let fast = fastMode[normalized] { return fast }
        if let exact = models[normalized] { return exact }

        // Dated snapshot: fall back to the longest matching alias.
        let candidates = models.keys.filter { alias in
            guard normalized.hasPrefix(alias) else { return false }
            // A base GPT rate must not leak into a distinct model such as
            // gpt-5.5-pro or gpt-5.50. Only dated snapshots inherit it.
            guard alias.hasPrefix("gpt-") else { return true }
            let suffix = String(normalized.dropFirst(alias.count))
            return suffix.range(of: #"^-(?:[0-9]{8}|[0-9]{4}-[0-9]{2}-[0-9]{2})$"#,
                                options: .regularExpression) != nil
        }
        if let best = candidates.max(by: { $0.count < $1.count }) {
            if speed == "fast", let fast = fastMode[best] { return fast }
            return models[best]
        }
        return nil
    }

    // MARK: - Emitting the table

    /// Serialises the effective table in the override file's own format.
    ///
    /// This is what makes the override usable without documentation drift:
    /// `aimonitor --pricing-dump > pricing.json` writes a file that is correct
    /// by construction, and the user edits the line they care about. A
    /// hand-maintained example file in the repo would be a second copy of the
    /// rates, and second copies go stale — which is the exact failure this
    /// whole change exists to fix.
    public func dumpJSON(updated: String) -> String {
        func number(_ d: Decimal) -> String { NSDecimalNumber(decimal: d).stringValue }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        func entry(_ id: String, _ rate: ModelRate, indent: String) -> String {
            var fields = ["\"input\": \"\(number(rate.inputPerMTok))\"",
                          "\"output\": \"\(number(rate.outputPerMTok))\""]
            if let cached = rate.cachedInputPerMTok {
                fields.append("\"cachedInput\": \"\(number(cached))\"")
            }
            if let i = rate.introInputPerMTok, let o = rate.introOutputPerMTok, let end = rate.introEndsBefore {
                fields.append("\"introInput\": \"\(number(i))\"")
                fields.append("\"introOutput\": \"\(number(o))\"")
                fields.append("\"introEndsBefore\": \"\(dayFormatter.string(from: end))\"")
            }
            return "\(indent)\"\(id)\": { \(fields.joined(separator: ", ")) }"
        }

        func block(_ table: [String: ModelRate]) -> String {
            table.keys.sorted()
                .map { entry($0, table[$0]!, indent: "    ") }
                .joined(separator: ",\n")
        }

        return """
        {
          "schemaVersion": \(PricingFile.supportedSchema),
          "updated": "\(updated)",

          "//": "Rates are per million tokens, as strings so they parse as exact decimals.",
          "//replace": "Set \\"replace\\": true to make this file the whole table instead of an overlay.",

          "models": {
        \(block(models))
          },

          "fastMode": {
        \(block(fastMode))
          }
        }
        """
    }

    /// One line describing where the rates came from, for the report to print.
    public var sourceNote: String? {
        switch source {
        case .builtIn:
            return nil
        case .merged(let path, _, let updated):
            return "pricing: built-in table + override from \(path)" + (updated.map { " (updated \($0))" } ?? "")
        case .replaced(let path, _, let updated):
            return "pricing: override REPLACES built-in table, from \(path)" + (updated.map { " (updated \($0))" } ?? "")
        }
    }
}

// MARK: - The file format

/// The on-disk shape of `pricing.json`.
///
/// **Rates are strings, not JSON numbers.** `5.6` in JSON decodes through a
/// binary `Double` and lands on a value that is not exactly 5.6; every rate
/// here feeds `Decimal` arithmetic that exists precisely to avoid that. Parsing
/// from the string preserves the decimal the provider actually published.
struct PricingFile: Decodable {
    var schemaVersion: Int
    var updated: String?
    /// When true the file *is* the table; the compiled defaults are discarded.
    /// Default is to merge, so adding one new model does not delete the rest.
    var replace: Bool?
    var models: [String: Entry]?
    var fastMode: [String: Entry]?

    struct Entry: Decodable {
        var input: String
        var cachedInput: String?
        var output: String
        var introInput: String?
        var introOutput: String?
        /// `yyyy-MM-dd`, interpreted UTC — the same basis as the compiled table.
        var introEndsBefore: String?
    }

    /// Highest schema this build understands. A file from the future is not
    /// guessed at: it is refused, with the compiled table left in place.
    static let supportedSchema = 1

    func applied(to fallback: PricingCatalog, path: String) -> PricingCatalog {
        guard schemaVersion <= Self.supportedSchema else {
            var out = fallback
            out.problems = [
                "pricing override needs schemaVersion \(schemaVersion), this build understands \(Self.supportedSchema): \(path)"
            ]
            return out
        }

        var problems: [String] = []
        let shouldReplace = replace ?? false

        func convert(_ raw: [String: Entry]?, label: String, builtIn: [String: ModelRate]) -> [String: ModelRate] {
            var out: [String: ModelRate] = [:]
            for (id, entry) in (raw ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let rate = entry.rate() else {
                    // Named and dropped — never approximated. What happens next
                    // depends on the mode, and the message has to say which,
                    // because "your edit was ignored, the old rate is still
                    // being used" and "this model now has no price" are very
                    // different things to be told.
                    if !shouldReplace, builtIn[id] != nil {
                        problems.append("\(label) entry '\(id)' has an unparseable rate; edit ignored, built-in rate still in force")
                    } else {
                        problems.append("\(label) entry '\(id)' has an unparseable rate; left unpriced")
                    }
                    continue
                }
                out[id] = rate
            }
            return out
        }

        let fileModels = convert(models, label: "models", builtIn: fallback.models)
        let fileFast = convert(fastMode, label: "fastMode", builtIn: fallback.fastMode)

        let mergedModels = shouldReplace ? fileModels : fallback.models.merging(fileModels) { _, new in new }
        let mergedFast = shouldReplace ? fileFast : fallback.fastMode.merging(fileFast) { _, new in new }

        return PricingCatalog(
            models: mergedModels,
            fastMode: mergedFast,
            source: shouldReplace
                ? .replaced(path: path, schemaVersion: schemaVersion, updated: updated)
                : .merged(path: path, schemaVersion: schemaVersion, updated: updated),
            problems: problems
        )
    }
}

extension PricingFile.Entry {
    /// Builds a rate, or nothing. Every field must parse as a decimal; a half
    /// parsed rate is not repaired with a default, because a default here is a
    /// price the provider never published.
    func rate() -> ModelRate? {
        guard let input = Decimal(string: input), let output = Decimal(string: output) else { return nil }
        let cached = cachedInput.flatMap { Decimal(string: $0) }
        if cachedInput != nil && cached == nil { return nil }

        var introIn: Decimal?
        var introOut: Decimal?
        var introEnd: Date?
        // The intro trio is all-or-nothing: two of three describes no rule.
        if let i = introInput, let o = introOutput, let end = introEndsBefore {
            guard let iv = Decimal(string: i), let ov = Decimal(string: o), let ed = Self.day(end) else { return nil }
            introIn = iv; introOut = ov; introEnd = ed
        } else if introInput != nil || introOutput != nil || introEndsBefore != nil {
            return nil
        }

        return ModelRate(
            input: input, output: output, cachedInput: cached,
            introInput: introIn, introOutput: introOut, introEndsBefore: introEnd
        )
    }

    /// `yyyy-MM-dd` in UTC, matching how the compiled table builds its dates.
    static func day(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)
    }
}
