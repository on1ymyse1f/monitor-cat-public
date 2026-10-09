import Foundation

/// Reads Claude Code usage from `~/.claude/projects/**/*.jsonl`.
///
/// The trap in this format: several assistant records share one `requestId` and
/// repeat the same usage figures. A naive line-by-line sum can therefore
/// over-report output tokens. This collector folds by `requestId` (last-wins) and
/// reports how many duplicates it dropped so the correction is visible rather
/// than implicit.
///
/// The other correction that matters is cost: `cache_creation` breaks writes
/// into `ephemeral_1h_input_tokens` and `ephemeral_5m_input_tokens`, which bill
/// at 2x and 1.25x the input rate respectively. Collapsing them into the flat
/// `cache_creation_input_tokens` field would lose the distinction between the
/// two rates.
public struct ClaudeCodeCollector: Sendable {
    public let projectsRoot: URL

    public init(projectsRoot: URL? = nil) {
        self.projectsRoot = projectsRoot ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public static let providerName = "Claude Code"

    struct Entry {
        var model: String
        var speed: String?
        var tokens: TokenBreakdown
        var timestamp: Date?
    }

    public func collect(since: Date? = nil) -> ProviderReport {
        var stats = ScanStats()
        var entries: [String: Entry] = [:]
        var notes: [String] = []
        var apiErrorRecords = 0

        let files = Self.transcriptFiles(under: projectsRoot)
        guard !files.isEmpty else {
            return ProviderReport(
                provider: Self.providerName,
                tokenConfidence: .unavailable,
                billedCostConfidence: .unavailable,
                quotaConfidence: .unavailable,
                stats: stats,
                notes: [
                    "No transcripts found under \(projectsRoot.path).",
                    "Reporting unavailable rather than zero — an empty scan is not a quiet day.",
                ]
            )
        }

        for file in files {
            var lineNumber = 0
            do {
                // Only records carrying a usage block matter; everything else
                // (prompt/response content) is skipped before JSON parsing.
                try JSONL.forEachObject(at: file, needles: ["\"usage\""]) { object in
                    lineNumber += 1
                    guard let message = object.dict("message"),
                          let usage = message.dict("usage") else { return }

                    // Error envelopes carry a usage block for a request that did
                    // not complete. Counting them would inflate the total.
                    if object.bool("isApiErrorMessage") == true {
                        apiErrorRecords += 1
                        return
                    }

                    let timestamp = Timestamps.parse(object.str("timestamp"))
                    if let since, let timestamp, timestamp < since { return }

                    stats.recordsWithUsage += 1

                    if let serverTools = usage.dict("server_tool_use") {
                        stats.webSearchRequests += serverTools.int("web_search_requests") ?? 0
                        stats.webFetchRequests += serverTools.int("web_fetch_requests") ?? 0
                    }

                    let key: String
                    if let requestID = object.str("requestId"), !requestID.isEmpty {
                        key = requestID
                    } else if let messageID = message.str("id"), !messageID.isEmpty {
                        key = "msg:" + messageID
                    } else {
                        // No provider-assigned identity. Keyed positionally, which
                        // cannot detect a duplicate of this record elsewhere —
                        // this is what degrades confidence below.
                        stats.syntheticallyKeyed += 1
                        key = "line:\(file.path)#\(lineNumber)"
                    }

                    let candidate = Entry(
                        model: message.str("model") ?? "unknown",
                        speed: usage.str("speed"),
                        tokens: Self.normalize(usage),
                        timestamp: timestamp
                    )

                    // Records sharing a requestId are progressive snapshots of one
                    // streaming message: input and cache figures hold steady while
                    // output grows (e.g. 2 -> 783 tokens), and no field was ever
                    // observed to decrease. The completed snapshot is therefore the
                    // largest one.
                    //
                    // Keeping the largest rather than the last makes the fold
                    // independent of traversal order — a later file listing or an
                    // out-of-order append cannot change the total.
                    if let existing = entries[key] {
                        stats.duplicatesDropped += 1
                        if candidate.tokens.billableEquivalent > existing.tokens.billableEquivalent {
                            entries[key] = candidate
                        }
                    } else {
                        entries[key] = candidate
                    }
                }
                stats.filesScanned += 1
            } catch {
                stats.filesFailed += 1
                continue
            }
        }

        // Aggregate per model+speed so fast-mode traffic is priced separately.
        var grouped: [String: (model: String, speed: String?, tokens: TokenBreakdown, cost: Decimal?, requests: Int, priced: Bool)] = [:]
        var total = TokenBreakdown()
        var totalCost: Decimal = 0
        var anyUnpriced = false

        for entry in entries.values {
            total += entry.tokens
            let groupKey = entry.model + "|" + (entry.speed ?? "standard")
            let costDate = entry.timestamp ?? Date()
            let cost = PricingTable.cost(
                of: entry.tokens,
                model: entry.model,
                speed: entry.speed,
                asOf: costDate
            )
            if cost == nil {
                anyUnpriced = true
                stats.unpricedModels.insert(entry.model)
            } else {
                totalCost += cost!
            }

            var g = grouped[groupKey] ?? (entry.model, entry.speed, TokenBreakdown(), nil, 0, cost != nil)
            g.tokens += entry.tokens
            g.requests += 1
            if let cost { g.cost = (g.cost ?? 0) + cost }
            g.priced = g.priced && cost != nil
            grouped[groupKey] = g
        }

        let perModel = grouped.values
            .sorted { $0.tokens.billableEquivalent > $1.tokens.billableEquivalent }
            .map { ModelUsage(model: $0.model, speed: $0.speed, tokens: $0.tokens, costUSD: $0.cost, requests: $0.requests) }

        // Never exact, on purpose.
        //
        // `input_tokens` and cache-write fields do not establish a complete
        // input total from local records alone. The upstream field semantics
        // have also been disputed, so this collector does not label the result
        // exact even when parsing succeeds.
        //
        // That reading makes the totals complete. But an upstream report
        // (anthropics/claude-code#28197) describes this same field as a streaming
        // placeholder that never receives the final count, which would mean some
        // real input is unaccounted for. Local logs cannot settle which reading is
        // right, and the honest label for a number that depends on an ambiguous
        // upstream field is an estimate — so this caps at `.estimated` even on a
        // perfectly clean scan. Any error is bounded by the fresh-input term, the
        // smallest component of the total.
        let tokenConfidence: Confidence = .estimated

        if stats.duplicatesDropped > 0 {
            notes.append(
                "Dropped \(stats.duplicatesDropped) duplicate usage records sharing a requestId; summing raw lines would have over-reported."
            )
        }
        if stats.syntheticallyKeyed > 0 {
            notes.append(
                "\(stats.syntheticallyKeyed) record(s) had no requestId or message id and were keyed by file+line, so a duplicate among them could survive dedup."
            )
        }
        if apiErrorRecords > 0 {
            notes.append("Excluded \(apiErrorRecords) API-error record(s), which carry a usage block for a request that did not complete.")
        }
        if total.cacheWrite1h > 0 || total.cacheWrite5m > 0 {
            notes.append(
                "Cache writes split \(total.cacheWrite1h.formatted()) at 1h (2x rate) / \(total.cacheWrite5m.formatted()) at 5m (1.25x rate)."
            )
        }
        if anyUnpriced {
            notes.append(
                "Unpriced models present (\(stats.unpricedModels.sorted().joined(separator: ", "))); their tokens are counted but excluded from cost."
            )
        }
        if stats.webSearchRequests > 0 || stats.webFetchRequests > 0 {
            notes.append(
                "\(stats.webSearchRequests) web search + \(stats.webFetchRequests) web fetch request(s) seen. These bill per request, not per token, and are excluded from the cost above — no verified per-request rate ships with this build."
            )
        }
        notes.append(
            "Fresh input reads low (\(total.uncachedInput.formatted()) tokens) because new content each turn is written to cache and counted under cache writes; upstream disputes this field's meaning, so totals are an estimate, not exact."
        )
        notes.append(
            "Cost is API-equivalent list price, not an invoice: a subscription plan does not bill per token."
        )

        return ProviderReport(
            provider: Self.providerName,
            tokens: total,
            tokenConfidence: tokenConfidence,
            apiEquivalentCostUSD: entries.isEmpty ? nil : totalCost,
            apiEquivalentCostConfidence: entries.isEmpty
                ? .unavailable
                : (anyUnpriced ? .estimated : Confidence.combine([tokenConfidence, .estimated])),
            billedCostConfidence: .unavailable,
            quotas: [],
            quotaConfidence: .unavailable,
            perModel: perModel,
            stats: stats,
            notes: notes
        )
    }

    /// Maps Claude Code's usage shape onto the neutral breakdown.
    ///
    /// `input_tokens` here is the uncached remainder — cache reads are reported
    /// separately, the opposite of Codex's inclusive convention.
    static func normalize(_ usage: [String: Any]) -> TokenBreakdown {
        var breakdown = TokenBreakdown(
            uncachedInput: usage.int("input_tokens") ?? 0,
            cachedInput: usage.int("cache_read_input_tokens") ?? 0,
            output: usage.int("output_tokens") ?? 0,
            reasoning: usage.dict("output_tokens_details")?.int("thinking_tokens") ?? 0
        )

        // Prefer the TTL breakdown when present; it drives the cache-write rate.
        if let creation = usage.dict("cache_creation") {
            breakdown.cacheWrite1h = creation.int("ephemeral_1h_input_tokens") ?? 0
            breakdown.cacheWrite5m = creation.int("ephemeral_5m_input_tokens") ?? 0
            let split = breakdown.cacheWrite1h + breakdown.cacheWrite5m
            let flat = usage.int("cache_creation_input_tokens") ?? 0
            // If the flat field exceeds the split, the difference is a TTL this
            // build does not recognize; carry it rather than dropping it.
            if flat > split { breakdown.cacheWriteUnspecified = flat - split }
        } else {
            breakdown.cacheWriteUnspecified = usage.int("cache_creation_input_tokens") ?? 0
        }
        return breakdown
    }

    public static func transcriptFiles(under root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }
}
