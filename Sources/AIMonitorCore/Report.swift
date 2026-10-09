import Foundation

public enum ReportFormatter {
    public static func text(_ report: UsageReport) -> String {
        var out: [String] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        out.append("AI usage — generated \(df.string(from: report.generatedAt))")
        if let since = report.since {
            out.append("Window: since \(df.string(from: since))")
        } else {
            out.append("Window: all available history")
        }
        out.append("")

        for provider in report.providers {
            out.append("── \(provider.provider) " + String(repeating: "─", count: max(0, 56 - provider.provider.count)))

            if let tokens = provider.tokens, provider.tokenConfidence != .unavailable {
                out.append("  tokens (billable-equivalent)  \(pad(tokens.billableEquivalent.formatted()))  [\(provider.tokenConfidence.marker)]")
                out.append("    fresh input                 \(pad(tokens.uncachedInput.formatted()))")
                out.append("    cached input                \(pad(tokens.cachedInput.formatted()))")
                if tokens.cacheWriteTotal > 0 {
                    var parts: [String] = []
                    if tokens.cacheWrite1h > 0 { parts.append("\(tokens.cacheWrite1h.formatted()) @1h") }
                    if tokens.cacheWrite5m > 0 { parts.append("\(tokens.cacheWrite5m.formatted()) @5m") }
                    if tokens.cacheWriteUnspecified > 0 { parts.append("\(tokens.cacheWriteUnspecified.formatted()) @TTL?") }
                    out.append("    cache writes                \(pad(tokens.cacheWriteTotal.formatted()))  (\(parts.joined(separator: ", ")))")
                }
                out.append("    output                      \(pad(tokens.output.formatted()))")
                if tokens.reasoning > 0 {
                    out.append("      of which reasoning        \(pad(tokens.reasoning.formatted()))")
                }
            } else {
                out.append("  tokens                        unavailable")
            }

            if let cost = provider.apiEquivalentCostUSD, provider.apiEquivalentCostConfidence != .unavailable {
                out.append("  API-equivalent cost           \(pad(money(cost)))  [\(provider.apiEquivalentCostConfidence.marker)]")
            } else {
                out.append("  API-equivalent cost           unavailable")
            }
            out.append("  amount actually billed        unavailable  [\(provider.billedCostConfidence.marker)]")

            if provider.quotas.isEmpty {
                out.append("  quota                         unavailable")
            } else {
                for q in provider.quotas {
                    var line = "  quota \(q.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(format: "%6.1f%%", q.usedPercent)) used"
                    if let resets = q.resetsAt {
                        line += "  resets \(df.string(from: resets))"
                    }
                    line += "  [\(provider.quotaConfidence.marker)]"
                    out.append(line)
                    out.append("        observed \(df.string(from: q.observedAt))" + (q.planType.map { ", plan \($0)" } ?? ""))
                }
            }

            if !provider.perModel.isEmpty {
                out.append("  by model:")
                for m in provider.perModel {
                    let label = m.speed == "fast" ? "\(m.model) (fast)" : m.model
                    let costText = m.costUSD.map { money($0) } ?? "unpriced"
                    out.append("    \(label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(pad(m.tokens.billableEquivalent.formatted()))  \(costText)  \(m.requests) req")
                }
            }

            let s = provider.stats
            if s.filesScanned > 0 || s.filesFailed > 0 {
                var scan = "  scan: \(s.filesScanned) file(s), \(s.recordsWithUsage) usage record(s)"
                if s.duplicatesDropped > 0 { scan += ", \(s.duplicatesDropped) duplicate(s) dropped" }
                if s.counterResetsObserved > 0 { scan += ", \(s.counterResetsObserved) counter reset(s)" }
                if s.filesFailed > 0 { scan += ", \(s.filesFailed) unreadable" }
                out.append(scan)
            }

            for note in provider.notes {
                out.append("  · \(note)")
            }
            out.append("")
        }

        // Run-level disclosures last: they qualify every figure above, so they
        // read as a footnote to the whole page rather than to the final block.
        if !report.notes.isEmpty {
            out.append(String(repeating: "─", count: 60))
            for note in report.notes {
                out.append("· \(note)")
            }
            out.append("")
        }

        return out.joined(separator: "\n")
    }

    private static func pad(_ s: String, width: Int = 16) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    public static func money(_ value: Decimal) -> String {
        let rounded = NSDecimalNumber(decimal: value).doubleValue
        if rounded > 0 && rounded < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", rounded)
    }

    public static func json(_ report: UsageReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }
}
