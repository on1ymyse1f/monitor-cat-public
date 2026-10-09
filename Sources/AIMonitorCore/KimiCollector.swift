import Foundation

/// Reads Kimi Code CLI usage from its own session wire logs.
///
/// No credentials are touched here. Kimi Code appends a `usage.record` line to
/// `~/.kimi-code/sessions/<workspace>/session_<uuid>/agents/main/wire.jsonl`
/// at the end of every turn:
///
/// ```json
/// {"type":"usage.record","model":"kimi-code/example-model",
///  "usage":{"inputOther":120,"output":12,"inputCacheRead":800,"inputCacheCreation":0},
///  "usageScope":"turn","time":1700000000000}
/// ```
///
/// The parser relies on these record semantics:
///
///   * Each record is **per-turn**, not cumulative — records sum directly, no
///     delta/reset handling is needed (unlike Codex's cumulative counters).
///   * `time` is epoch **milliseconds**.
///   * `inputOther` is fresh input, exclusive of `inputCacheRead` — the same
///     convention as Claude Code, so no cached-portion subtraction.
///   * `inputCacheCreation` carries no TTL information, so it lands in
///     `cacheWriteUnspecified` and stays out of any TTL-priced math.
///
/// `usageScope` values other than `"turn"` (should any appear) are skipped:
/// a session-scope cumulative record summed next to turn records would
/// double-count. Wire logs also carry prompt content; those lines are skipped
/// by the needle filter before JSON parsing, and no content field is ever read.
///
/// Project attribution comes from `~/.kimi-code/session_index.jsonl`
/// (`{"sessionId","sessionDir","workDir"}` per line), falling back to the
/// workspace directory slug when a session is not indexed.
public struct KimiCollector: Sendable {
    /// All session roots that hold wire logs: the standalone Kimi Code CLI
    /// (~/.kimi-code) and the Kimi desktop app's embedded runtime, which is
    /// where most interactive usage actually lands.
    public let sessionsRoots: [URL]

    public init(sessionsRoot: URL? = nil) {
        if let sessionsRoot {
            self.sessionsRoots = [sessionsRoot]
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.sessionsRoots = [
                home.appendingPathComponent(".kimi-code/sessions", isDirectory: true),
                home.appendingPathComponent(
                    "Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions",
                    isDirectory: true
                ),
            ]
        }
    }

    public init(sessionsRoots: [URL]) {
        self.sessionsRoots = sessionsRoots
    }

    public static let providerName = "Kimi Code"

    public func collect(since: Date? = nil) -> ProviderReport {
        var stats = ScanStats()
        var total = TokenBreakdown()
        var perModel: [String: (tokens: TokenBreakdown, requests: Int)] = [:]

        let files = sessionsRoots.flatMap { Self.wireFiles(under: $0) }
        guard !files.isEmpty else {
            return ProviderReport(
                provider: Self.providerName,
                tokenConfidence: .unavailable,
                billedCostConfidence: .unavailable,
                quotaConfidence: .unavailable,
                stats: stats,
                notes: [
                    "No wire logs found under \(sessionsRoots.map(\.path).joined(separator: ", ")).",
                    "Reporting unavailable rather than zero — an empty scan is not a quiet day.",
                ]
            )
        }

        for file in files {
            do {
                // Accounting lives in usage.record lines; everything else in a
                // wire log is conversation content — skip it before JSON parsing.
                try JSONL.forEachObject(at: file, needles: ["\"usage.record\""]) { object in
                    guard let tokens = Self.tokens(from: object) else { return }
                    if let since, let t = Self.timestamp(of: object), t < since { return }
                    total += tokens
                    stats.recordsWithUsage += 1
                    let model = object.str("model") ?? "unknown"
                    var entry = perModel[model] ?? (TokenBreakdown(), 0)
                    entry.tokens += tokens
                    entry.requests += 1
                    perModel[model] = entry
                }
                stats.filesScanned += 1
            } catch {
                stats.filesFailed += 1
            }
        }

        var notes: [String] = []
        if total.cacheWriteUnspecified > 0 {
            notes.append(
                "Kimi reports cache writes without a TTL; \(total.cacheWriteUnspecified.formatted()) tokens are recorded as TTL-unspecified."
            )
        }
        notes.append(
            "Cost uses public Kimi API-equivalent rates for known Kimi Code/Work model ids; subscription-credit billing is not an invoice."
        )
        notes.append(
            "Live quota is opt-in (Settings): a read-only GET to the provider's usage endpoint, at most once every 15 minutes."
        )

        return ProviderReport(
            provider: Self.providerName,
            tokens: total,
            tokenConfidence: stats.recordsWithUsage > 0 ? .exact : .unavailable,
            billedCostConfidence: .unavailable,
            quotaConfidence: .unavailable,
            perModel: perModel.map {
                ModelUsage(model: $0.key, tokens: $0.value.tokens, costUSD: nil, requests: $0.value.requests)
            }.sorted { $0.tokens.billableEquivalent > $1.tokens.billableEquivalent },
            stats: stats,
            notes: notes
        )
    }

    /// Normalizes one `usage.record` object onto the neutral breakdown.
    /// Returns nil for non-turn scopes (see struct docs) and records without usage.
    static func tokens(from object: [String: Any]) -> TokenBreakdown? {
        if let scope = object.str("usageScope"), scope != "turn" { return nil }
        guard let usage = object.dict("usage") else { return nil }
        return TokenBreakdown(
            uncachedInput: usage.int("inputOther") ?? 0,
            cachedInput: usage.int("inputCacheRead") ?? 0,
            cacheWriteUnspecified: usage.int("inputCacheCreation") ?? 0,
            output: usage.int("output") ?? 0
        )
    }

    /// `time` is epoch milliseconds.
    static func timestamp(of object: [String: Any]) -> Date? {
        guard let ms = object.int("time") else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    /// All wire logs under the sessions root, sorted for deterministic scans.
    public static func wireFiles(under root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in e where url.lastPathComponent == "wire.jsonl" {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Session identity from the path: `session_<uuid>` for the CLI,
    /// `conv-*` / `ctitle-*` for the desktop runtime.
    static func sessionId(for file: URL) -> String? {
        file.pathComponents.last {
            $0.hasPrefix("session_") || $0.hasPrefix("conv-") || $0.hasPrefix("ctitle-")
        }
    }

    /// sessionId → workDir, from `session_index.jsonl` next to the sessions root.
    static func sessionIndex(under sessionsRoot: URL) -> [String: String] {
        let index = sessionsRoot.deletingLastPathComponent()
            .appendingPathComponent("session_index.jsonl")
        guard let data = try? Data(contentsOf: index) else { return [:] }
        var out: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["sessionId"] as? String,
                  let workDir = object["workDir"] as? String
            else { continue }
            out[id] = workDir
        }
        return out
    }

    /// Project name for a wire file: the workDir's last path component via the
    /// session index; otherwise the workspace slug without its generated
    /// `wd_` prefix and hash suffix.
    static func projectName(for file: URL, under root: URL, index: [String: String]) -> String? {
        if let sessionId = sessionId(for: file),
           let workDir = index[sessionId],
           let last = workDir.split(separator: "/").last {
            return String(last)
        }
        let rel = file.path.dropFirst(root.path.count).split(separator: "/")
        guard var slug = rel.first.map(String.init) else { return nil }
        if slug.hasPrefix("wd_") { slug.removeFirst(3) }
        if let range = slug.range(of: #"_[0-9a-f]{6,}$"#, options: .regularExpression) {
            slug.removeSubrange(range)
        }
        return slug.isEmpty ? nil : slug
    }
}
