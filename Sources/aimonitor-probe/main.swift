import AIMonitorCore
import Foundation

/// Format probe.
///
/// The failure mode this exists to catch: a parser that finds nothing reports
/// zero, and zero looks like a light usage day rather than a broken parser. This
/// prints the *key paths* present in the real logs — never values — so a drift in
/// either format is visible before any number is trusted.
///
/// It prints key names and counts only. No prompt text, no file contents, no
/// token values.

let home = FileManager.default.homeDirectoryForCurrentUser
let codexRoot = home.appendingPathComponent(".codex/sessions")
let claudeRoot = home.appendingPathComponent(".claude/projects")
let kimiRoots = KimiCollector().sessionsRoots

func keyPaths(in object: [String: Any], prefix: String = "", depth: Int = 0, into set: inout Set<String>) {
    guard depth < 4 else { return }
    for (key, value) in object {
        let path = prefix.isEmpty ? key : "\(prefix).\(key)"
        if let nested = value as? [String: Any] {
            set.insert(path + "{}")
            keyPaths(in: nested, prefix: path, depth: depth + 1, into: &set)
        } else if value is [Any] {
            set.insert(path + "[]")
        } else if value is NSNull {
            set.insert(path + " (null)")
        } else {
            set.insert(path)
        }
    }
}

print("aimonitor format probe — key paths only, no values printed")
print("")

// ── Codex ────────────────────────────────────────────────────────────────────
print("Codex: \(codexRoot.path)")
let codexFiles = CodexCollector.rolloutFiles(under: codexRoot)
print("  rollout files: \(codexFiles.count)")

// Sample several recent files, not just the newest. A session that was opened
// and aborted contains no `token_count` events at all, so probing one file can
// report a healthy format as broken.
var codexUsagePaths = Set<String>()
var codexQuotaPaths = Set<String>()
var codexUsageRecords = 0
var codexQuotaRecords = 0
var codexPopulatedQuotaRecords = 0
var codexFilesWithUsage = 0
let codexSample = codexFiles.suffix(10)

for file in codexSample {
    var fileUsage = 0
    try? JSONL.forEachObject(at: file) { object in
        let payload = object.dict("payload") ?? object
        if let info = payload.dict("info"), info.dict("total_token_usage") != nil {
            fileUsage += 1
            codexUsageRecords += 1
            if codexUsagePaths.count < 40 { keyPaths(in: info, prefix: "payload.info", into: &codexUsagePaths) }
        }
        if let limits = payload.dict("rate_limits") {
            codexQuotaRecords += 1
            // A `primary` of null means the snapshot carries no usable window.
            if limits.dict("primary") != nil {
                codexPopulatedQuotaRecords += 1
                if codexQuotaPaths.count < 40 { keyPaths(in: limits, prefix: "payload.rate_limits", into: &codexQuotaPaths) }
            }
        }
    }
    if fileUsage > 0 { codexFilesWithUsage += 1 }
}

print("  sampled \(codexSample.count) most recent file(s); \(codexFilesWithUsage) contained usage records")
print("  token_count records carrying total_token_usage: \(codexUsageRecords)")
for path in codexUsagePaths.sorted() { print("    \(path)") }
print("  records carrying rate_limits: \(codexQuotaRecords) (\(codexPopulatedQuotaRecords) with a populated primary window)")
if codexPopulatedQuotaRecords == 0 {
    print("    ⚠️  No populated quota window in the sample — a `primary` of null carries no")
    print("        usable percentage, so quota would report unavailable.")
}
for path in codexQuotaPaths.sorted() { print("    \(path)") }

if codexUsageRecords == 0 && !codexFiles.isEmpty {
    print("  ⚠️  No usage records across the sample. Token totals would read zero — treat")
    print("      that as a parser problem, not a quiet day.")
}
print("")

// ── Claude Code ──────────────────────────────────────────────────────────────
print("Claude Code: \(claudeRoot.path)")
let claudeFiles = ClaudeCodeCollector.transcriptFiles(under: claudeRoot)
print("  transcript files: \(claudeFiles.count)")

var usagePaths = Set<String>()
var records = 0
var withRequestID = 0
var withoutRequestID = 0
var models = Set<String>()

for file in claudeFiles.suffix(5) {
    try? JSONL.forEachObject(at: file) { object in
        guard let message = object.dict("message"), let usage = message.dict("usage") else { return }
        records += 1
        if let rid = object.str("requestId"), !rid.isEmpty { withRequestID += 1 } else { withoutRequestID += 1 }
        if let model = message.str("model") { models.insert(model) }
        if records <= 20 { keyPaths(in: usage, prefix: "message.usage", into: &usagePaths) }
    }
}

print("  usage-bearing records (last 5 files): \(records)")
print("  with requestId: \(withRequestID)   without: \(withoutRequestID)")
if withoutRequestID > 0 {
    print("    → those fall back to positional keys, which is what degrades token confidence to est.")
}
for path in usagePaths.sorted() { print("    \(path)") }
print("  models seen: \(models.sorted().joined(separator: ", "))")

let unpriced = models.filter { PricingTable.rate(forModel: $0, speed: nil) == nil }
if !unpriced.isEmpty {
    print("  unpriced by the bundled table: \(unpriced.sorted().joined(separator: ", "))")
    print("    → tokens still counted; cost excluded rather than guessed.")
}

if records == 0 {
    print("  ⚠️  No usage records found. Token totals would read zero — treat that as a")
    print("      parser problem, not a quiet day.")
}
print("")

// ── Kimi Code ───────────────────────────────────────────────────────────────
print("Kimi Code")
var kimiFiles = 0
var kimiRecords = 0
var kimiUsagePaths = Set<String>()
for root in kimiRoots {
    let files = KimiCollector.wireFiles(under: root)
    kimiFiles += files.count
    for file in files.suffix(5) {
        try? JSONL.forEachObject(at: file, needles: ["\"usage.record\""]) { object in
            guard object.dict("usage") != nil,
                  object.str("usageScope") == nil || object.str("usageScope") == "turn"
            else { return }
            kimiRecords += 1
            if kimiRecords <= 20 { keyPaths(in: object, into: &kimiUsagePaths) }
        }
    }
}
print("  wire files: \(kimiFiles)")
print("  usage-bearing records (up to last 5 per root): \(kimiRecords)")
for path in kimiUsagePaths.sorted() { print("    \(path)") }
if kimiRecords == 0 && kimiFiles > 0 {
    print("  ⚠️  Wire logs exist but no usage records parsed; do not report zero usage.")
}
print("")

// ── Installed app coverage gates ────────────────────────────────────────────
let applications = URL(fileURLWithPath: "/Applications")
let appChecks = [
    ("ChatGPT / Codex", "ChatGPT.app", true),
    ("ChatGPT Classic", "ChatGPT Classic.app", false),
    ("Claude Desktop", "Claude.app", true),
    ("Gemini Desktop", "Gemini.app", false),
    ("Kimi Desktop", "Kimi.app", true),
]
print("Installed app coverage")
for (name, bundle, hasSource) in appChecks {
    guard FileManager.default.fileExists(atPath: applications.appendingPathComponent(bundle).path) else { continue }
    print("  \(name): \(hasSource ? "source detected" : "no verified token/quota source yet")")
}
