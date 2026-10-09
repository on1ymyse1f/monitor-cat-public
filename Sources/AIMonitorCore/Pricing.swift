import Foundation

/// Per-million-token rates for a model.
public struct ModelRate: Sendable, Equatable {
    public let inputPerMTok: Decimal
    /// Provider-specific cached-input price. When absent, the shared 0.1x
    /// cache-read multiplier is used.
    public let cachedInputPerMTok: Decimal?
    public let outputPerMTok: Decimal
    /// Intro rate and the date it stops applying, when a model has one.
    public let introInputPerMTok: Decimal?
    public let introOutputPerMTok: Decimal?
    public let introEndsBefore: Date?

    public init(
        input: Decimal,
        output: Decimal,
        cachedInput: Decimal? = nil,
        introInput: Decimal? = nil,
        introOutput: Decimal? = nil,
        introEndsBefore: Date? = nil
    ) {
        self.inputPerMTok = input
        self.cachedInputPerMTok = cachedInput
        self.outputPerMTok = output
        self.introInputPerMTok = introInput
        self.introOutputPerMTok = introOutput
        self.introEndsBefore = introEndsBefore
    }

    func rates(asOf date: Date) -> (input: Decimal, output: Decimal) {
        if let end = introEndsBefore, let i = introInputPerMTok, let o = introOutputPerMTok, date < end {
            return (i, o)
        }
        return (inputPerMTok, outputPerMTok)
    }
}

/// List pricing, and the cost arithmetic that reads it.
///
/// Only rates that could be verified are present. A model absent from the
/// effective table produces **no cost figure at all** — it is recorded in
/// `ScanStats.unpricedModels` and degrades cost confidence. A guessed price is
/// worse than a missing one, because a guess still adds up.
///
/// The `builtIn*` tables below are the compiled floor. What a lookup actually
/// resolves against is `PricingCatalog.current`, which merges an optional
/// `pricing.json` over them so a list-price change does not require a rebuild.
/// See `PricingCatalog` for why the defaults stay in Swift rather than moving
/// into a bundled resource.
public struct PricingTable: Sendable {
    /// Cache reads bill at roughly a tenth of the input rate.
    public static let cacheReadMultiplier = Decimal(string: "0.1")!
    /// A 5-minute-TTL cache write bills at 1.25x the input rate.
    public static let cacheWrite5mMultiplier = Decimal(string: "1.25")!
    /// A 1-hour-TTL cache write bills at 2x the input rate — not 1.25x.
    ///
    /// Applying a flat 1.25x to an undifferentiated
    /// `cache_creation_input_tokens` field would underprice 1-hour writes.
    public static let cacheWrite1hMultiplier = Decimal(string: "2.0")!

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    /// Standard Anthropic rates, keyed by exact model id. The compiled floor —
    /// `PricingCatalog` may merge an override file over this.
    public static let builtInAnthropic: [String: ModelRate] = [
        "claude-fable-5": ModelRate(input: 10, output: 50),
        "claude-mythos-5": ModelRate(input: 10, output: 50),
        "claude-opus-5": ModelRate(input: 5, output: 25),
        "claude-opus-4-8": ModelRate(input: 5, output: 25),
        "claude-opus-4-7": ModelRate(input: 5, output: 25),
        "claude-opus-4-6": ModelRate(input: 5, output: 25),
        "claude-sonnet-5": ModelRate(
            input: 3, output: 15,
            introInput: 2, introOutput: 10,
            introEndsBefore: day(2026, 9, 1)
        ),
        "claude-sonnet-4-6": ModelRate(input: 3, output: 15),
        "claude-haiku-4-5": ModelRate(input: 1, output: 5),
    ]

    /// Fast mode runs the same model at premium rates. The Claude Code logs
    /// carry `usage.speed`, so this is detectable rather than assumed.
    public static let builtInFastMode: [String: ModelRate] = [
        "claude-opus-5": ModelRate(input: 10, output: 50),
        "claude-opus-4-8": ModelRate(input: 10, output: 50),
    ]

    /// OpenAI list pricing — platform.openai.com/docs/pricing, standard tier,
    /// short context. GPT-6 Sol and Luna verified 2026-09-23; GPT-5.4
    /// verified 2026-09-07; GPT-6 Astra and GPT-5.5 verified 2026-09-05:
    /// https://developers.openai.com/api/docs/pricing
    /// https://developers.openai.com/api/docs/models/gpt-5.4
    /// https://developers.openai.com/api/docs/models/gpt-6-astra
    /// https://developers.openai.com/api/docs/models/gpt-5.5
    /// Other entries retain the 2026-08-19 table. Cached reads (0.1x) and cache
    /// writes (1.25x) multiply the input rate exactly as on the Anthropic
    /// card, so the shared cost path prices both providers unchanged; Codex
    /// logs report output inclusive of reasoning, so `output` covers it.
    ///
    /// The long-context tier (2x input, 1.5x output past 272k) is NOT applied:
    /// per-event deltas cannot reconstruct a request's prompt size, so every
    /// event prices at the short-context rate. Unverified models and variants
    /// stay unpriced. Service-tier premiums/discounts are not inferred from
    /// Codex token deltas; these figures are API-equivalent estimates.
    public static let builtInOpenAI: [String: ModelRate] = [
        "gpt-5.4": ModelRate(input: 2.5, output: 15),
        "gpt-6-astra": ModelRate(input: 10, output: 50),
        "gpt-6-sol": ModelRate(input: 2, output: 10, cachedInput: 0.2),
        "gpt-6-luna": ModelRate(input: 0.1, output: 0.5, cachedInput: 0.01),
        "gpt-5.5": ModelRate(input: 5, output: 30),
        "gpt-5.6-sol": ModelRate(input: 5, output: 30),
        "gpt-5.6-terra": ModelRate(input: 2, output: 12),
        "gpt-5.6-luna": ModelRate(input: 0.2, output: 1.2),
        // OpenAI's Luna Reserve fallback is surfaced in Codex logs as
        // `gpt-reserve`, but the official help page says it runs GPT-5.6 Luna.
        "gpt-reserve": ModelRate(input: 0.2, output: 1.2),
    ]

    /// Kimi API-equivalent rates for model ids emitted by Kimi Code and Kimi
    /// Work. Kimi Code and Work actually consume subscription credits; these
    /// rates are only a comparable public API list-price estimate.
    /// Sources verified 2026-09-07:
    /// https://platform.kimi.ai/
    /// https://www.kimi.com/code/docs/en/kimi-code/
    public static let builtInKimi: [String: ModelRate] = [
        // Kimi K3: $3.00 uncached input / $0.30 cached input / $15 output.
        "kimi-code/k3": ModelRate(input: 3, output: 15, cachedInput: 0.30),
        "k3-agent": ModelRate(input: 3, output: 15, cachedInput: 0.30),
        // Kimi K2.6 Agent: $0.95 uncached input / $0.16 cached input / $4 output.
        "k2d6-agent": ModelRate(input: 0.95, output: 4, cachedInput: 0.16),
        // Kimi K2.7 Code: $0.95 uncached input / $0.19 cached input / $4 output.
        "kimi-code/kimi-for-coding": ModelRate(input: 0.95, output: 4, cachedInput: 0.19),
    ]

    /// Resolves a rate for a model id against the effective catalog.
    ///
    /// Dated snapshot ids (`claude-haiku-4-5-20251001`) resolve to their base
    /// alias by longest-prefix match. Synthetic and unknown ids return nil.
    public static func rate(forModel model: String, speed: String?) -> ModelRate? {
        PricingCatalog.current.rate(forModel: model, speed: speed)
    }

    /// Costs a breakdown at list price. Returns nil for an unpriced model.
    public static func cost(
        of tokens: TokenBreakdown,
        model: String,
        speed: String?,
        asOf date: Date
    ) -> Decimal? {
        guard let rate = rate(forModel: model, speed: speed) else { return nil }
        let (inputRate, outputRate) = rate.rates(asOf: date)
        let perToken = { (count: Int, rate: Decimal) -> Decimal in
            Decimal(count) / Decimal(1_000_000) * rate
        }
        let cachedInputRate = rate.cachedInputPerMTok ?? (inputRate * cacheReadMultiplier)
        return perToken(tokens.uncachedInput, inputRate)
            + perToken(tokens.cachedInput, cachedInputRate)
            + perToken(tokens.cacheWrite5m, inputRate * cacheWrite5mMultiplier)
            + perToken(tokens.cacheWrite1h, inputRate * cacheWrite1hMultiplier)
            // TTL-less writes are costed at the 5m rate because 5m is the
            // default TTL. This is the one assumption in the cost path, and a
            // non-zero `cacheWriteUnspecified` makes the report say so.
            + perToken(tokens.cacheWriteUnspecified, inputRate * cacheWrite5mMultiplier)
            + perToken(tokens.output, outputRate)
    }
}
