#if DEBUG
import AIMonitorCore
import AppKit
import SwiftUI

/// `--demo-window`: the real window, on synthetic data.
///
/// Opens the dashboard exactly as the app does, backed by an in-memory store
/// seeded with two live sessions and two quota windows. Nothing reads the
/// production database, the provider logs, or any credential — so the page
/// can be looked at, resized and profiled (idle CPU, energy) without the
/// numbers belonging to anyone.
@MainActor
enum DemoWindow {
    static func run() throws {
        Attention.forceAttended = CommandLine.arguments.contains("--attended")
        // `--store <file>`: a copy of a real store (make one with sqlite3
        // `.backup`), for looking at real figures and profiling at real size
        // — a 100k-event store, not eighteen rows. Never point this at the
        // live database: the app's own refresh would be writing to it.
        let now = Date()
        let store: EventStore
        if let i = CommandLine.arguments.firstIndex(of: "--store"), CommandLine.arguments.count > i + 1 {
            let path = CommandLine.arguments[i + 1]
            precondition(path != EventStore.defaultPath(), "--store takes a copy, not the live database")
            store = try EventStore(path: path)
        } else {
            store = try EventStore.inMemory()
            try seed(store, now: now)
            try seedWeek(store, now: now)
        }
        let model = try MonitorModel(store: store, readsSources: false)
        if CommandLine.arguments.contains("--nocturne") { model.setSkin(.nocturne) }
        if CommandLine.arguments.contains("--aubade") { model.setSkin(.aubade) }
        // `--receipt`: open on the settlement slip, both spans loaded, for
        // watching the print and profiling a printed page at rest.
        if CommandLine.arguments.contains("--receipt") {
            model.page = .receipt
            model.receipts = [.day: try store.receipt(.day, now: now), .week: try store.receipt(.week, now: now)]
            if CommandLine.arguments.contains("--week") { model.receiptSpan = .week }
            // `--flip`: switch spans after 2.5s, as a click on the toggle would,
            // to watch (and time) the tear-off and the reprint without a mouse.
            if CommandLine.arguments.contains("--flip") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(Motion.tear) {
                        model.setReceiptSpan(model.receiptSpan == .day ? .week : .day)
                    }
                }
            }
        }
        model.dashboard = try StoreReport.dashboard(from: store, now: now)
        model.live = try store.liveCounters(now: now)
        model.setWindowVisible(true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RootView().environmentObject(model))
        window.setContentSize(NSSize(width: 420, height: 720))
        window.center()

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        // On screen even when macOS declines to hand the demo focus: an
        // occluded window is never drawn, and profiling it measures nothing.
        window.orderFrontRegardless()
        // Profiling runs force attention instead, so they need not take the
        // keyboard from whatever the user is doing.
        if !Attention.forceAttended { app.activate(ignoringOtherApps: true) }
        // A profiling window is looked at, not used: clicks during a run turn
        // the measurement into a measurement of the clicks.
        window.ignoresMouseEvents = Attention.forceAttended
        print("demo window pid \(ProcessInfo.processInfo.processIdentifier)")
        // `--snapshot <dir>`: three frames of the live window, a cel apart,
        // for checking the Core Animation kitten without screen recording.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
            // `--snapshot-at 0.1,0.4,…`: frames at chosen moments instead —
            // for seeing a one-shot animation (the receipt's print) mid-flight.
            var times = (0..<3).map { 3 + Double($0) * 0.19 }
            if let j = CommandLine.arguments.firstIndex(of: "--snapshot-at"), CommandLine.arguments.count > j + 1 {
                times = CommandLine.arguments[j + 1].split(separator: ",").compactMap { Double($0) }
            }
            for (n, at) in times.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    guard let view = window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("frame\(n).png"))
                    // The render server's view of the kitten: the presentation
                    // transform must differ cel to cel if the track is playing.
                    func cels(in v: NSView) -> [NSView] {
                        (v is MascotCels.CelView ? [v] : []) + v.subviews.flatMap(cels)
                    }
                    for cel in cels(in: view) {
                        if let t = cel.layer?.sublayers?.first?.presentation()?.transform {
                            print(String(format: "cel frame %d: m11=%.4f m12=%.4f m22=%.4f m42=%.2f",
                                         n, t.m11, t.m12, t.m22, t.m42))
                        }
                    }
                    fflush(stdout)
                }
            }
        }
        // Profiling needs to know which regime it measured: the kitten only
        // animates while the app is frontmost.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            print("active=\(app.isActive) visible=\(window.occlusionState.contains(.visible))")
            fflush(stdout)
        }
        app.run()
    }

    /// The six days before today, for the settlement slip: three tools, a
    /// quiet day in the middle, and one model with no price — so the slip
    /// shows its unpriced line, its closed day and its per-day ledger.
    static func seedWeek(_ store: EventStore, now: Date) throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let lines: [(provider: String, model: String, perDay: Int, cost: String?)] = [
            ("Claude Code", "demo-opus", 3_400_000, "6.10"),
            ("Codex CLI", "demo-codex", 1_900_000, "1.45"),
            ("Kimi Code", "demo-kimi", 2_600_000, nil),
        ]
        for back in 1...6 where back != 3 {           // day -3: the shop was closed
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let scale = Double(7 - back) / 6 + 0.25
            for (i, line) in lines.enumerated() {
                try store.insert(usage: AIEvent(
                    id: "week-\(back)-\(i)", timestamp: day.addingTimeInterval(10 * 3600 + Double(i) * 600),
                    provider: line.provider, model: line.model, sessionId: "week-\(line.provider)",
                    project: "demo-project",
                    tokens: TokenBreakdown(output: Int(Double(line.perDay) * scale)),
                    costUSD: line.cost.flatMap { Decimal(string: $0) }.map { $0 * Decimal(scale) },
                    confidence: .estimated), keepLargest: false)
            }
        }
    }

    /// Two tools writing side by side, the way the page is normally used.
    static func seed(_ store: EventStore, now: Date) throws {
        for i in 0..<18 {
            try store.insert(usage: AIEvent(
                id: "demo-\(i)", timestamp: now.addingTimeInterval(-Double(i * 60)),
                provider: i % 2 == 0 ? "Codex CLI" : "Claude Code",
                model: i % 2 == 0 ? "demo-model-a" : "demo-model-b",
                sessionId: i % 2 == 0 ? "demo-codex" : "demo-claude", project: "demo-project",
                tokens: TokenBreakdown(output: 1200 + i * 70), costUSD: Decimal(string: "0.02"),
                confidence: .estimated), keepLargest: false)
        }
        for (id, provider, used) in [("demo-week", "Codex CLI", 28.0), ("demo-day", "Claude Code", 94.0)] {
            try store.insert(quota: QuotaWindow(
                id: id, label: id == "demo-week" ? "weekly" : "5h", usedPercent: used,
                windowMinutes: id == "demo-week" ? 10080 : 300,
                resetsAt: now.addingTimeInterval(2400), observedAt: now), provider: provider)
        }
    }
}
#endif
