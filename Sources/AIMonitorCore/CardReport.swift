import Foundation

/// The shareable "profile card": one provider's whole-history usage rendered
/// as a self-contained dark HTML file (GitHub-style heatmap + headline stats).
///
/// All numbers come from the local store — the card is generated offline and
/// contains no identifiers beyond the name/handle the caller passes in.
public enum CardReport {

    public struct Stats {
        public var totalBillable: Int
        public var peakDay: (day: Date, billable: Int)?
        /// Consecutive days with usage ending **today**. No usage today = 0 —
        /// a streak you are still on, matching how the reference card reads.
        public var currentStreak: Int
        public var longestStreak: Int
        /// Every day with usage, ascending. The heatmap pads to whole weeks.
        public var days: [(day: Date, billable: Int)]
    }

    /// Streak and peak math over a daily series. Pure — unit-tested directly.
    public static func stats(from days: [(day: Date, billable: Int)], today: Date = Date()) -> Stats {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: today)
        let active = Set(days.filter { $0.billable > 0 }.map { cal.startOfDay(for: $0.day) })

        var current = 0
        if active.contains(todayStart) {
            var d = todayStart
            while active.contains(d) {
                current += 1
                d = cal.date(byAdding: .day, value: -1, to: d)!
            }
        }

        var longest = 0
        var run = 0
        var previous: Date?
        for d in active.sorted() {
            if let p = previous, cal.date(byAdding: .day, value: 1, to: p) == d {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = d
        }

        return Stats(
            totalBillable: days.reduce(0) { $0 + $1.billable },
            peakDay: days.max { $0.billable < $1.billable },
            currentStreak: current,
            longestStreak: longest,
            days: days
        )
    }

    /// Compact token count, localized: zh 万/亿, en k/M/B.
    public static func compact(_ n: Int, lang: Language) -> String {
        if lang.resolved == .zh {
            switch n {
            case 100_000_000...: return trimmed(Double(n) / 100_000_000) + "亿"
            case 10_000...: return trimmed(Double(n) / 10_000) + "万"
            default: return "\(n)"
            }
        }
        switch n {
        case 1_000_000_000...: return trimmed(Double(n) / 1_000_000_000) + "B"
        case 1_000_000...: return trimmed(Double(n) / 1_000_000) + "M"
        case 1_000...: return trimmed(Double(n) / 1_000) + "k"
        default: return "\(n)"
        }
    }

    private static func trimmed(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    // MARK: - HTML

    /// Renders the card. `weeks` of heatmap columns; 26 matches the reference
    /// layout. Escapes the only interpolated free text (name/handle/provider).
    public static func html(
        provider: String,
        stats: Stats,
        name: String,
        handle: String,
        lang: Language,
        weeks: Int = 26,
        generatedAt: Date = Date()
    ) -> String {
        let zh = lang.resolved == .zh
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: generatedAt)

        // Heatmap grid: 7 rows (weekdays) × `weeks` columns, oldest left.
        // Column 0 starts on the Monday of the oldest visible week.
        let byDay = Dictionary(uniqueKeysWithValues: stats.days.map { (cal.startOfDay(for: $0.day), $0.billable) })
        let weekdayOfToday = (cal.component(.weekday, from: todayStart) + 5) % 7   // Mon = 0
        guard let lastColumnStart = cal.date(byAdding: .day, value: -weekdayOfToday, to: todayStart),
              let firstColumnStart = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: lastColumnStart)
        else { return "" }
        let peak = max(stats.peakDay?.billable ?? 0, 1)

        var cells = ""
        for row in 0..<7 {
            cells += "<div class=\"row\">"
            for col in 0..<weeks {
                guard let day = cal.date(byAdding: .day, value: col * 7 + row, to: firstColumnStart) else { continue }
                let v = day > todayStart ? 0 : (byDay[day] ?? 0)
                let level = v == 0 ? 0 : min(4, 1 + Int(3.0 * Double(v) / Double(peak)))
                let title = "\(day.formatted(.iso8601.year().month().day())) · \(compact(v, lang: lang))"
                cells += "<span class=\"c l\(level)\" title=\"\(title)\"></span>"
            }
            cells += "</div>"
        }

        let initials = name.split(separator: " ").map { String($0.prefix(1)) }.joined().uppercased()
        let displayInitials = initials.isEmpty ? "AI" : String(initials.prefix(2))
        let daysUnit = zh ? " 天" : " d"
        let statsHTML = [
            (compact(stats.totalBillable, lang: lang), zh ? "累计 Token" : "Total tokens"),
            (stats.peakDay.map { compact($0.billable, lang: lang) } ?? "0", zh ? "峰值日" : "Peak day"),
            ("\(stats.currentStreak)\(daysUnit)", zh ? "当前连续天数" : "Current streak"),
            ("\(stats.longestStreak)\(daysUnit)", zh ? "最长连续使用" : "Longest streak"),
        ].map { "<div class=\"stat\"><div class=\"v\">\($0.0)</div><div class=\"k\">\($0.1)</div></div>" }
            .joined(separator: "<div class=\"div\"></div>")

        return """
        <!doctype html>
        <html lang="\(zh ? "zh-CN" : "en")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(provider)) · AI Monitor</title>
        <style>
          :root {
            --bg: #1b1e2b; --cell0: #262a3b; --cell1: #2d3a5c; --cell2: #3b579a;
            --cell3: #4a6fc5; --cell4: #6e9bff; --text: #e8eaf2; --muted: #8b91a7;
            --green: #35c08d; --hairline: #2e3347;
          }
          * { margin: 0; box-sizing: border-box; }
          body {
            background: var(--bg); color: var(--text); padding: 40px 44px;
            font: 14px/1.5 -apple-system, "SF Pro", "PingFang SC", sans-serif;
            max-width: 1000px; margin: 0 auto;
          }
          header { display: flex; align-items: center; gap: 18px; margin-bottom: 34px; }
          .avatar {
            width: 84px; height: 84px; border-radius: 50%; background: var(--green);
            color: #fff; font-size: 28px; font-weight: 600; flex: none;
            display: flex; align-items: center; justify-content: center;
          }
          .who h1 { font-size: 26px; font-weight: 700; letter-spacing: .01em; }
          .who p { color: var(--muted); font-size: 15px; }
          .brand { margin-left: auto; color: var(--muted); font-size: 22px; font-weight: 600; letter-spacing: .02em; }
          .grid { display: flex; flex-direction: column; gap: 6px; margin-bottom: 38px; overflow-x: auto; }
          .row { display: flex; gap: 6px; }
          .c { width: 24px; height: 24px; border-radius: 5px; background: var(--cell0); flex: none; }
          .c.l1 { background: var(--cell1); } .c.l2 { background: var(--cell2); }
          .c.l3 { background: var(--cell3); } .c.l4 { background: var(--cell4); }
          footer { display: flex; align-items: stretch; }
          .stat { flex: 1; }
          .stat .v { font-size: 30px; font-weight: 700; }
          .stat .k { color: var(--muted); font-size: 13px; margin-top: 4px; }
          .div { width: 1px; background: var(--hairline); margin: 4px 26px; }
        </style>
        </head>
        <body>
          <header>
            <div class="avatar">\(escape(displayInitials))</div>
            <div class="who"><h1>\(escape(name))</h1><p>@\(escape(handle))</p></div>
            <div class="brand">\(escape(provider))</div>
          </header>
          <div class="grid">\(cells)</div>
          <footer>\(statsHTML)</footer>
        </body>
        </html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
