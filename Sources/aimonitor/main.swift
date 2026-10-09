import AIMonitorCore
import Foundation

func usage() -> String {
    """
    aimonitor — local AI coding-tool usage, with the confidence of each number stated

    USAGE
      aimonitor [--since <days>] [--json]
      aimonitor --sync <db-path> [--claude-root <dir>] [--codex-root <dir>] [--kimi-root <dir>]
      aimonitor card [--provider <name>] [--out <file.html>] [--lang en|zh] [--db <db-path>]
      aimonitor --pricing-dump | --pricing-where
      aimonitor --recost <db-path> [--models id,id]
      aimonitor --unpriced [<db-path>] | --unpriced-baseline [<db-path>]
      aimonitor --verify [<db-path>]
      aimonitor [--claude-root <dir>] [--codex-root <dir>] [--kimi-root <dir>] --live [<db-path>]
      aimonitor --timeline [<db-path>]
      aimonitor --install-agent [<seconds>] | --uninstall-agent | --agent-status
      aimonitor --audit
      aimonitor --quota claude|kimi|cursor

    OPTIONS
      --since <days>       Only count usage from the last N days (default: all history)
      --json               Emit machine-readable JSON instead of the text report
      --claude-root <dir>  Read Claude Code transcripts from <dir> instead of
                           ~/.claude/projects
      --codex-root <dir>   Read Codex rollout logs from <dir> instead of
                           ~/.codex/sessions
      --kimi-root <dir>    Read Kimi Code wire logs from <dir> instead of
                           ~/.kimi-code/sessions
      --help               This message

    LIVE QUOTA
      `--quota` is an explicit one-shot network check. It reads the selected
      app/CLI's current local login, asks only that provider's official usage
      endpoint, prints quota percentages and reset times, and never stores or
      refreshes the credential.

    CARD
      Renders a shareable profile card (heatmap + streaks) as a self-contained
      HTML file, from the store. Options:
        --provider <name>  Provider to feature (default: the one with most usage)
        --out <file>       Output path (default: ~/Desktop/aimonitor-card.html)
        --lang en|zh       Card language (default: system)
        --db <path>        Store path (default: ~/Library/Application Support/AIMonitor)
        --name / --handle  Display name and handle (default: this Mac's user)

    PRICING
      Rates are the compiled table with an optional override merged over it, so
      a list-price change does not need a rebuild:

        aimonitor --pricing-dump > ~/Library/Application\\ Support/AIMonitor/pricing.json

      Edit that file and the next run uses it. `--pricing-where` says which
      table is in force and names any entry that failed to parse. An entry that
      cannot be read is left **unpriced** rather than defaulted — an unpriced
      model produces no cost figure at all, which is the point.

      Costs are computed at sync time and stored, so editing the table changes
      only events synced afterwards. To reprice history as well:

        aimonitor --recost ~/Library/Application\\ Support/AIMonitor/aimonitor.db

      Each row reprices against its own timestamp, so a lapsed intro rate still
      applies to the events it covered.

      Add --models with exact comma-separated IDs to migrate only selected
      models (for example gpt-6-astra,gpt-5.5); omitting it keeps whole-store
      recost behavior.

    UNPRICED MODELS
      Something is always unpriced — `<synthetic>`, models a provider ships
      without publishing a rate — so "unpriced models exist" is not a signal.
      `--unpriced` splits the list into what you have acknowledged and what is
      new; only the second half means the table has gone stale. Acknowledge the
      current set with `--unpriced-baseline`. Exits non-zero when something is
      newly unpriced, so it can gate a shell prompt or a cron check.

    VERIFY
      `--verify` checks the token counts this tool reconstructs against the
      provider's own quota accounting, which it did not produce. Where the ratio
      between them is stable, the reconstruction tracks books it did not write;
      where it scatters, the reconstruction is missing or duplicating events.
      Offline — both series are already in the store. It reports a spread only
      from three or more clean segments, and names what it dropped.

    LIVE AND TIMELINE
      `--live` is a running counter: it syncs when the logs change and repaints
      every 2s. The resolution floor is the tool's own log flush, not this
      interval — Claude Code writes per assistant message, Codex per
      `token_count` — so the counter steps when the log steps.

      `--timeline` groups the event stream into stretches of continuous work
      (same session, same model, no pause longer than 5 minutes) instead of one
      row per accounting record. Concurrent tools are grouped per session, so
      two tools running at once no longer chop each other's spans apart.

    WITHOUT THE APP
      The dashboard is not the only way to want these numbers, and keeping a
      SwiftUI process alive so a figure stays fresh is a poor way to want them.
      `--install-agent` writes a launchd LaunchAgent that runs `--sync` on an
      interval (default 300s, low IO priority), so the CLI answers instantly
      with nothing else running:

        aimonitor --install-agent
        launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.aimonitor.sync.plist

      The agent runs the same read-only collectors and makes no network request
      — the quota fetches are app-side and opt-in. `--agent-status` says whether
      it is installed; `--uninstall-agent` removes the plist.

    REPRODUCIBILITY
      The live logs grow while you read them — an agent session appends usage
      records as it works, so two runs seconds apart legitimately differ. To
      compare runs, copy the logs aside and point --claude-root / --codex-root /
      --kimi-root at the frozen snapshot.

    NOTES
      Every figure carries a confidence marker: exact (read from the provider's
      own accounting), est. (reconstructed from logs, with the caveat named), or
      n/a (not derivable locally — reported as absent, never as zero).

      Run `aimonitor-probe` first to confirm the local log formats still
      match what the parsers expect.
    """
}

var since: Date?
var wantsJSON = false
var claudeRoot: URL?
var codexRoot: URL?
var kimiRoot: URL?
var args = Array(CommandLine.arguments.dropFirst())

func takeDirectory(_ flag: String, from args: inout [String]) -> URL {
    guard let value = args.first else {
        FileHandle.standardError.write(Data("error: \(flag) needs a directory\n".utf8))
        exit(2)
    }
    args.removeFirst()
    return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
}

/// `aimonitor card` — render one provider's whole history as a shareable card.
func runCardCommand(_ cardArgs: [String]) {
    var provider: String?
    var out = "~/Desktop/aimonitor-card.html"
    var dbPath = EventStore.defaultPath()
    var lang = Language.system
    var name = NSFullUserName()
    var handle = NSUserName()

    var rest = cardArgs
    while let arg = rest.first {
        rest.removeFirst()
        func takeValue() -> String {
            guard let v = rest.first else {
                FileHandle.standardError.write(Data("error: \(arg) needs a value\n".utf8))
                exit(2)
            }
            rest.removeFirst()
            return v
        }
        switch arg {
        case "--provider": provider = takeValue()
        case "--out": out = takeValue()
        case "--db": dbPath = (takeValue() as NSString).expandingTildeInPath
        case "--lang": lang = Language(rawValue: takeValue()) ?? .system
        case "--name": name = takeValue()
        case "--handle": handle = takeValue()
        default:
            FileHandle.standardError.write(Data("error: unknown card option '\(arg)'\n".utf8))
            exit(2)
        }
    }

    do {
        let store = try EventStore(path: dbPath)
        let present = try store.providersPresent()
        guard let provider = provider ?? present.first else {
            FileHandle.standardError.write(Data("error: no usage in the store yet — run `aimonitor --sync` first\n".utf8))
            exit(1)
        }
        let days = try store.dailyBillable(provider: provider)
        let stats = CardReport.stats(from: days)
        if name.isEmpty { name = handle }
        let html = CardReport.html(provider: provider, stats: stats, name: name, handle: handle, lang: lang)
        let outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        try html.write(to: outURL, atomically: true, encoding: .utf8)
        print("card written to \(outURL.path)")
        print("  \(provider): total \(stats.totalBillable), peak day \(stats.peakDay?.billable ?? 0), streak \(stats.currentStreak)/\(stats.longestStreak) days, \(days.count) active days")
    } catch {
        FileHandle.standardError.write(Data("error: card failed: \(error)\n".utf8))
        exit(1)
    }
}

func printQuota(_ windows: [QuotaWindow], provider: String) {
    let formatter = ISO8601DateFormatter()
    print("\(provider) live quota")
    for window in windows {
        let reset = window.resetsAt.map(formatter.string(from:)) ?? "unknown"
        print(String(format: "  %-16@ %6.2f%% used  reset %@",
                     window.label as NSString, window.usedPercent, reset as NSString))
    }
}

while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--help", "-h":
        print(usage())
        exit(0)
    case "--json":
        wantsJSON = true
    case "--since":
        guard let value = args.first, let days = Double(value) else {
            FileHandle.standardError.write(Data("error: --since needs a number of days\n".utf8))
            exit(2)
        }
        args.removeFirst()
        since = Date().addingTimeInterval(-days * 86_400)
    case "--claude-root":
        claudeRoot = takeDirectory(arg, from: &args)
    case "--codex-root":
        codexRoot = takeDirectory(arg, from: &args)
    case "--kimi-root":
        kimiRoot = takeDirectory(arg, from: &args)
    case "card":
        runCardCommand(args)
        exit(0)
    case "--quota":
        guard let provider = args.first?.lowercased() else {
            FileHandle.standardError.write(Data("error: --quota needs claude, kimi, or cursor\n".utf8))
            exit(2)
        }
        args.removeFirst()
        switch provider {
        case "claude":
            switch await ClaudeQuotaProvider().fetch() {
            case .success(let windows): printQuota(windows, provider: ClaudeQuotaProvider.providerName)
            case .failure(let error):
                FileHandle.standardError.write(Data("error: Claude quota unavailable: \(error)\n".utf8)); exit(1)
            }
        case "kimi":
            // Check the credential before spending a request on it. Kimi's
            // access token carries `expires_in: 900` — fifteen minutes — so
            // "expired" is the *normal* state between sessions, and saying so
            // plainly beats a bare `tokenExpired` the user cannot act on.
            let kimi = KimiQuotaProvider()
            switch kimi.credentialState() {
            case .absent:
                FileHandle.standardError.write(Data(
                    "error: no Kimi credential at \(kimi.credentialsURL.path) — sign in with Kimi Code first\n".utf8))
                exit(1)
            case .expired(let since):
                let mins = Int(Date().timeIntervalSince(since) / 60)
                FileHandle.standardError.write(Data("""
                    error: Kimi's access token expired \(mins) min ago.

                      Kimi issues tokens that live 15 minutes, and refreshes them only while
                      Kimi Code is running. There is no offline fallback: unlike Codex, Kimi
                      writes no rate-limit data into its logs, so the endpoint is the only
                      source. Run Kimi Code once, then try again — the app now picks the
                      quota up automatically whenever a fresh token appears.

                    """.utf8))
                exit(1)
            case .valid:
                switch await kimi.fetch() {
                case .success(let windows): printQuota(windows, provider: KimiQuotaProvider.providerName)
                case .failure(let error):
                    FileHandle.standardError.write(Data("error: Kimi quota unavailable: \(error)\n".utf8)); exit(1)
                }
            }
        case "cursor":
            switch await CursorQuotaProvider().fetch() {
            case .success(let windows): printQuota(windows, provider: CursorQuotaProvider.providerName)
            case .failure(let error):
                FileHandle.standardError.write(Data("error: Cursor quota unavailable: \(error)\n".utf8)); exit(1)
            }
        default:
            FileHandle.standardError.write(Data("error: unknown quota provider '\(provider)'\n".utf8)); exit(2)
        }
        exit(0)
    case "--pricing-dump":
        // Emits the effective table in the override file's own format, so the
        // starting point for an edit is generated rather than transcribed.
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        print(PricingCatalog.current.dumpJSON(updated: day.string(from: Date())))
        exit(0)
    case "--install-agent", "--uninstall-agent", "--agent-status":
        // Keeps the store current with nothing running: no dock icon, no menu
        // bar, no SwiftUI process — just an incremental parse on an interval.
        let dbPath = EventStore.defaultPath()
        do {
            if arg == "--uninstall-agent" {
                let removed = try BackgroundAgent.remove()
                if removed {
                    print("removed \(BackgroundAgent.plistURL.path)")
                    print("now run:  launchctl bootout gui/$(id -u)/\(BackgroundAgent.label)")
                } else {
                    print("no agent installed at \(BackgroundAgent.plistURL.path)")
                }
                exit(0)
            }
            if arg == "--agent-status" {
                print(BackgroundAgent.isInstalled()
                      ? "installed: \(BackgroundAgent.plistURL.path)"
                      : "not installed")
                print("store: \(dbPath)")
                print("log:   \(BackgroundAgent.logURL.path)")
                exit(BackgroundAgent.isInstalled() ? 0 : 1)
            }
            var every = 300
            if let value = args.first, let n = Int(value) { args.removeFirst(); every = max(60, n) }
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            let url = try BackgroundAgent.write(executable: exe, dbPath: dbPath, everySeconds: every)
            print("wrote \(url.path)")
            print("  runs: \(exe) --sync \(dbPath)")
            print("  every \(every)s, at low IO priority")
            print("")
            print("Load it (this is the step that starts it):")
            print("  launchctl bootstrap gui/$(id -u) \(url.path)")
            print("")
            print("After that `aimonitor` answers with the app closed. Remove with --uninstall-agent.")
        } catch {
            FileHandle.standardError.write(Data("error: agent setup failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    case "--audit":
        // Re-derives privacy and security claims from the current system.
        // Asks for nothing: no Keychain, no network, no new permission.
        let report = SelfAudit.run()
        print("aimonitor self-audit — every line below was checked just now, not asserted")
        print("")
        for f in report.findings {
            let mark = f.verdict == .pass ? "✓" : (f.verdict == .warn ? "!" : "·")
            print("  \(mark) \(f.title)")
            print("      \(f.detail)")
        }
        print("")
        print(report.warnings == 0
              ? "No warnings. Verify independently: `fs_usage -w -f filesys aimonitor` for reads,"
                + "\n`nettop -p aimonitor` for network."
              : "\(report.warnings) warning(s) above.")
        exit(report.warnings == 0 ? 0 : 1)
    case "--live":
        // A running counter in the terminal. Repaints on a short tick; the
        // resolution floor is the tool's own log flush, not this interval.
        let dbPath = args.first.map { p -> String in args.removeFirst(); return (p as NSString).expandingTildeInPath }
            ?? EventStore.defaultPath()
        do {
            let store = try EventStore(path: dbPath)
            // The caller's roots are a privacy and reproducibility boundary,
            // not a hint. The old live path parsed them and then constructed a
            // default engine anyway, silently importing the real HOME logs
            // into a database that was meant to contain only a frozen fixture.
            let engine = SyncEngine(
                store: store,
                claudeRoot: claudeRoot,
                codexRoot: codexRoot,
                kimiRoots: kimiRoot.map { [$0] }
            )
            var lastFingerprint: Int?
            var lastCumulative: Int?
            while true {
                let fingerprint = engine.logsFingerprint()
                var delta: Int?
                if fingerprint != lastFingerprint {
                    _ = engine.sync()
                    lastFingerprint = fingerprint
                    let cumulative = try store.cumulativeBillable()
                    delta = lastCumulative.map { cumulative - $0 }
                    lastCumulative = cumulative
                }
                let live = try store.liveCounters()

                // The rate is machine-wide and says so. Printing it beside a
                // single session's total is what let the dashboard claim a
                // pace that would spend the whole conversation inside a
                // minute — the rate was four other conversations.
                let rate = live.tokensPerMinute.map { String(format: "%7.0f tok/min", $0) } ?? "         idle"
                let arrow = (delta ?? 0) > 0 ? String(format: "  +%d", delta!) : ""
                let state = live.isLive ? "●" : "○"
                let shown = live.sessions.prefix(3)
                    .map { "\($0.provider) \($0.billable.formatted())" }
                    .joined(separator: "   ")
                let hidden = max(0, live.liveSessionCount - min(3, live.sessions.count))
                let hiddenText = hidden > 0 ? "   +\(hidden) more" : ""
                FileHandle.standardOutput.write(Data("\u{1B}[2K\r\(state) \(rate) all tools   \(shown.isEmpty ? "-" : shown)\(hiddenText)\(arrow)".utf8))
                fflush(stdout)
                try await Task<Never, Never>.sleep(nanoseconds: 2_000_000_000)
            }
        } catch {
            FileHandle.standardError.write(Data("error: live failed: \(error)\n".utf8))
            exit(1)
        }
    case "--timeline":
        let dbPath = args.first.map { p -> String in args.removeFirst(); return (p as NSString).expandingTildeInPath }
            ?? EventStore.defaultPath()
        do {
            let store = try EventStore(path: dbPath)
            let spans = try store.recentActivity(limit: 25)
            if spans.isEmpty { print("no activity in the store yet — run `aimonitor --sync` first."); exit(0) }
            let f = DateFormatter()
            // POSIX locale: `HH` follows the user's 12/24-hour setting
            // otherwise, and a column that is sometimes "14:57" and sometimes
            // "2:57 PM" does not line up.
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "MM-dd HH:mm"
            print("recent activity — one row per stretch of continuous work, not per record")
            print("")
            for s in spans {
                let minutes = max(1, Int(s.duration / 60))
                let cost = s.costUSD.map { String(format: "$%.2f", $0) } ?? "  -  "
                let model = (s.model ?? "-").padding(toLength: 16, withPad: " ", startingAt: 0)
                let project = (s.project ?? "-").prefix(18).padding(toLength: 18, withPad: " ", startingAt: 0)
                print(String(
                    format: "  %@  %-11@ %@ %@ %12@ %7@ %4dm %5d rec",
                    f.string(from: s.startedAt), s.provider as NSString, model as NSString,
                    project as NSString, s.billable.formatted() as NSString, cost as NSString,
                    minutes, s.events
                ))
            }
        } catch {
            FileHandle.standardError.write(Data("error: timeline failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    case "--verify":
        // Checks the reconstructed token counts against the provider's own
        // quota accounting. Offline: both series are already in the store.
        let dbPath = args.first.map { p -> String in args.removeFirst(); return (p as NSString).expandingTildeInPath }
            ?? EventStore.defaultPath()
        do {
            let store = try EventStore(path: dbPath)
            let results = try UsageVerification.verifyAll(store: store)
            if results.isEmpty {
                print("no quota history in the store — nothing to verify against.")
                print("Codex writes quota into its logs; Claude needs the opt-in live-quota fetch.")
                exit(0)
            }
            var measured = false
            for r in results {
                print("── \(r.provider) · \(r.label)")
                print("   \(r.verdict)")
                if let model = r.segments.first?.dominantModel {
                    print("   dominant model in the usable segments: \(model)")
                }
                for (reason, n) in r.rejected.sorted(by: { $0.value > $1.value }) {
                    print("   · \(n) segment(s) dropped — \(reason)")
                }
                if r.relativeSpread != nil { measured = true }
                print("")
            }
            print("What this does and does not say:")
            print("  Token counts are reconstructed here; quota percentages are written by the")
            print("  provider. A stable ratio between them means the reconstruction tracks books")
            print("  it did not produce. It cannot detect an error that scales both alike, and it")
            print("  says nothing about money — only about the token accounting.")
            exit(measured ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("error: verify failed: \(error)\n".utf8))
            exit(2)
        }
    case "--unpriced", "--unpriced-baseline":
        // Everything unpriced, split into what the user already acknowledged
        // and what is new. Only the second half is a signal.
        let takingBaseline = (arg == "--unpriced-baseline")
        let dbPath = args.first.map { p -> String in args.removeFirst(); return (p as NSString).expandingTildeInPath }
            ?? EventStore.defaultPath()
        do {
            let store = try EventStore(path: dbPath)
            let scan = try store.unpricedScan()

            if takingBaseline {
                let baseline = scan.asBaseline()
                try baseline.save()
                print("baseline written to \(UnpricedBaseline.defaultURL.path)")
                print("  \(baseline.acknowledged.count) model(s) acknowledged as unpriced")
                print("  future runs report only models that are not in this set")
                exit(0)
            }

            func line(_ m: UnpricedModel) -> String {
                let seen = m.lastSeen.map { " last seen \(ISO8601DateFormatter().string(from: $0))" } ?? ""
                return "  \(m.provider) · \(m.model) — \(m.billable.formatted()) tokens, \(m.requests) req\(seen)"
            }

            let fresh = scan.newlyUnpriced
            let known = scan.acknowledged
            if !known.isEmpty {
                print("acknowledged unpriced (\(known.count)) — counted, excluded from cost, not news:")
                known.forEach { print(line($0)) }
                print("")
            }
            if fresh.isEmpty {
                print("no newly unpriced models — the pricing table covers everything the store has seen.")
                exit(0)
            }
            print("NEWLY UNPRICED (\(fresh.count)) — the pricing table has gone stale:")
            fresh.forEach { print(line($0)) }
            print("")
            print("Their tokens are counted; their cost is absent, not zero. To fix:")
            print("  aimonitor --pricing-dump > \(PricingCatalog.defaultOverrideURL.path)")
            print("  # add the rate, then:")
            print("  aimonitor --recost \(dbPath)")
            print("Or accept them as permanently unpriced:  aimonitor --unpriced-baseline")
            // Non-zero so this can gate a shell prompt or a cron check.
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("error: unpriced scan failed: \(error)\n".utf8))
            exit(2)
        }
    case "--recost":
        // Stored costs were priced at sync time, so an edited rate table only
        // reaches events synced after the edit. This repoints the whole store
        // at the current table, each row against its own timestamp.
        guard let dbPath = args.first else {
            FileHandle.standardError.write(Data("error: --recost needs a database path\n".utf8))
            exit(2)
        }
        args.removeFirst()
        var recostModels: Set<String>?
        if !args.isEmpty {
            guard args.count == 2, args[0] == "--models" else {
                FileHandle.standardError.write(Data("error: expected --recost <db> [--models id,id]\n".utf8))
                exit(2)
            }
            let names = args[1].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard names.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("--") }) else {
                FileHandle.standardError.write(Data("error: --models requires non-empty exact model IDs\n".utf8))
                exit(2)
            }
            recostModels = Set(names)
        }
        do {
            let store = try EventStore(path: (dbPath as NSString).expandingTildeInPath)
            let catalog = PricingCatalog.current
            print(catalog.sourceNote ?? "pricing: built-in table only (no override file)")
            for problem in catalog.problems { print("  ! \(problem)") }

            if let recostModels { print("scope: exact model IDs \(recostModels.sorted().joined(separator: ", "))") }
            let s = try store.recost(onlyModels: recostModels)
            print("recost: \(s.rowsChanged) of \(s.rowsExamined) event(s) repriced")
            print("  total \(ReportFormatter.money(s.previousTotalUSD)) → \(ReportFormatter.money(s.newTotalUSD)) (\(s.deltaUSD < 0 ? "-" : "+")\(ReportFormatter.money(abs(s.deltaUSD))))")
            if s.nowPriced > 0 { print("  \(s.nowPriced) event(s) gained a price the table previously lacked") }
            if s.nowUnpriced > 0 {
                print("  ! \(s.nowUnpriced) event(s) LOST their price — a model id in the table no longer matches")
            }
            if s.unvouchedSpeedRows > 0 {
                print("  ! \(s.unvouchedSpeedRows) event(s) predate the speed column; recosted at the standard rate, fast-mode premium not recoverable")
            }
        } catch {
            FileHandle.standardError.write(Data("error: recost failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    case "--pricing-where":
        let catalog = PricingCatalog.current
        print(catalog.sourceNote ?? "pricing: built-in table only (no override file)")
        print("override path: \(PricingCatalog.defaultOverrideURL.path)")
        print("models priced: \(catalog.models.count) standard, \(catalog.fastMode.count) fast-mode")
        for problem in catalog.problems { print("  ! \(problem)") }
        exit(catalog.problems.isEmpty ? 0 : 1)
    case "--sync":
        // Sync into the store at the given path, then print what the store
        // believes — for cross-checking the incremental path against the
        // full-scan report on the same logs.
        guard let dbPath = args.first else {
            FileHandle.standardError.write(Data("error: --sync needs a database path\n".utf8))
            exit(2)
        }
        args.removeFirst()
        do {
            let store = try EventStore(path: (dbPath as NSString).expandingTildeInPath)
            let engine = SyncEngine(store: store, claudeRoot: claudeRoot, codexRoot: codexRoot, kimiRoots: kimiRoot.map { [$0] })
            let summary = engine.sync()
            print("sync: \(summary.filesScanned) scanned, \(summary.filesSkippedUnchanged) unchanged, \(summary.filesFailed) failed; +\(summary.claudeEvents) claude, +\(summary.codexEvents) codex, +\(summary.kimiEvents) kimi events")
            for provider in [ClaudeCodeCollector.providerName, CodexCollector.providerName, KimiCollector.providerName] {
                guard let b = try store.tokenBreakdown(provider: provider) else { continue }
                print("""
                    \(provider): billable \(b.billableEquivalent) = input \(b.uncachedInput) + cached \(b.cachedInput) \
                    + writes(5m \(b.cacheWrite5m), 1h \(b.cacheWrite1h), ?\(b.cacheWriteUnspecified)) + output \(b.output) \
                    [reasoning \(b.reasoning)], events \(try store.eventCount(provider: provider))
                    """)
            }
        } catch {
            FileHandle.standardError.write(Data("error: sync failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    default:
        FileHandle.standardError.write(Data("error: unknown argument '\(arg)'\n\n".utf8))
        print(usage())
        exit(2)
    }
}

let report = Aggregator(
    codex: CodexCollector(sessionsRoot: codexRoot),
    claudeCode: ClaudeCodeCollector(projectsRoot: claudeRoot),
    kimi: KimiCollector(sessionsRoot: kimiRoot)
).report(since: since)

if wantsJSON {
    do {
        print(try ReportFormatter.json(report))
    } catch {
        FileHandle.standardError.write(Data("error: could not encode report: \(error)\n".utf8))
        exit(1)
    }
} else {
    print(ReportFormatter.text(report))
}
