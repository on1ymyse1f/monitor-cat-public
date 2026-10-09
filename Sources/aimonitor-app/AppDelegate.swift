import AIMonitorCore
import AppKit
import Combine
import SwiftUI
import UserNotifications

// MARK: - App delegate: the window, the menu-bar cat, the tick

/// Why AppKit owns the window instead of SwiftUI's `WindowGroup`:
///
/// SwiftUI persists the scene's window set in Saved Application State. Close
/// the dashboard window and then kill the process, and the next launch
/// faithfully restores **zero windows**. AppKit ownership makes recreation
/// deterministic without retaining an off-screen `NSHostingView`: the content
/// tree is released on close, then Dock and menu actions build a fresh one.
///
/// Owning the NSWindow here makes every entry point deterministic:
/// launch, Dock click, and the menu bar all funnel into `showMainWindow()`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var tick: Timer?
    /// Menu-bar cat cels: the resting frame and the mid-blink squash.
    private var menuBarCat: NSImage?
    private var menuBarCatBlink: NSImage?
    /// Blink/rotation is opportunistic on the monitor's existing tick. A second
    /// repeating timer woke an otherwise idle menu-bar process every 4.2s.
    private var lastMenuBarBlinkAt = Date.distantPast
    private static let menuBarBlinkInterval: TimeInterval = 4.2
    /// Which provider's quota is showing; advances one step per cat blink.
    private var quotaRotationIndex = 0
    /// Quota thresholds already notified, per window id — reset when usage drops.
    private var notifiedThresholds: [String: Int] = [:]
    /// Rebuild the status menu after asynchronous model publication. Without
    /// this, cold launch attached an empty status item and did not create its
    /// menu until the first 15-second timer tick.
    private var menuObservers: Set<AnyCancellable> = []
    private var mainWindow: NSWindow?
    let model: MonitorModel

    init(model: MonitorModel) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        attachStatusItem()
        observeMenuPresentation()
        showMainWindow()
        model.refresh()
        scheduleTick(live: false)
    }

    /// Two cadences, chosen by whether anything is actually running.
    ///
    /// The steady state stays at 15s: that tick fingerprints the log
    /// directories with stat calls only, and paying for it more often while the
    /// machine is idle buys nothing. But a running counter that lags its source
    /// by up to fifteen seconds is not a running counter, so while a session is
    /// live the tick drops to 2s. The floor is still the tool's own log flush —
    /// this only stops the app from adding latency on top of it.
    private var tickIsLive = false
    private var fastTicksSinceFull = 0
    /// Whether this app is the one the user is actually looking at.
    ///
    /// **A monitor has to cost less than the thing it monitors.** The fast
    /// cadence exists so a *watched* counter keeps up; nobody is watching it
    /// from inside their editor. When the app is not frontmost the tick drops
    /// back to the idle rhythm even while a session is live — the data does not
    /// go stale, because the store is correct whenever it is next asked and the
    /// window refreshes on activation.
    private var appIsActive = true

    private func scheduleTick(live: Bool) {
        guard tick == nil || tickIsLive != live else { return }
        tickIsLive = live
        fastTicksSinceFull = 0
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: live ? 2 : 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The fast cadence is for the running counter alone. Doing the
                // full refresh at 2s re-synced the logs, ran five analytics
                // queries and republished five `@Published` properties — a
                // whole-page rebuild — to move one number, which measured at
                // about a fifth of a core, sustained.
                if self.tickIsLive {
                    self.fastTicksSinceFull += 1
                    // Fold the full refresh back in on the old 15s rhythm so
                    // quota and the visible page never go stale. The full job
                    // already includes live counters, so do one or the other.
                    if self.fastTicksSinceFull >= 8 {
                        self.fastTicksSinceFull = 0
                        self.model.refresh()
                    } else {
                        self.model.refreshLive()
                    }
                } else {
                    self.model.refresh()
                }
                self.renderMenuBar()
                self.advanceMenuBarPresentation()
                self.scheduleTick(live: self.shouldUseLiveCadence)
            }
        }
    }

    /// Fast polling is useful only when a human can see the running counter.
    private var shouldUseLiveCadence: Bool {
        appIsActive && mainWindow?.isVisible == true && (model.live?.isLive ?? false)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appIsActive = true
        // Coming back to the window should show current numbers immediately,
        // not whatever the idle rhythm last left behind.
        model.setWindowVisible(mainWindow?.isVisible == true)
        model.refresh()
        scheduleTick(live: shouldUseLiveCadence)
    }

    func applicationDidResignActive(_ notification: Notification) {
        appIsActive = false
        scheduleTick(live: false)
    }

    /// Dock-icon click (or `open` while running): always show the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        model.refresh()
        return false
    }

    /// Create the dashboard window when needed. Closing releases both the
    /// NSWindow and its hosting controller; this path recreates them for Dock or
    /// status-menu opens while frame autosave restores the user's geometry.
    func showMainWindow() {
        if mainWindow == nil {
            let root = RootView().environmentObject(model)
            let hosting = NSHostingController(rootView: root)
            let w = NSWindow(contentViewController: hosting)
            w.title = "AI Monitor"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            // The window was pinned to exactly 420×620 by setting contentMin
            // and contentMax to the same size and leaving `.resizable` out of
            // the mask. That made every proportion in the page a constant, so
            // the quota grid stayed two columns whether it had two cards or
            // seven, and the sheet could not be widened to read them.
            //
            // It is resizable now, with a floor rather than a fixed size. The
            // floor is the width at which the two-column quota grid still fits
            // a card without truncating "Codex CLI · weekly"; below that the
            // grid drops to one column on its own.
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 420, height: 620))
            w.contentMinSize = NSSize(width: 360, height: 480)
            // Tall and narrow is the page's natural shape, but nothing breaks
            // wide — the grid reflows — so the ceiling is the screen.
            w.contentMaxSize = NSSize(width: 1400, height: 2000)
            // ARC owns the window through `mainWindow`. AppKit releasing it in
            // the middle of `performClose` while the delegate also tears down
            // the content can leave close-button accessibility code holding a
            // stale object, so release it ourselves after that event returns.
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            // Remember where the user put it and how big they made it. Set
            // after `center()` so a first launch still opens centred, and after
            // the size constraints so a restored frame is clamped to them.
            w.setFrameAutosaveName("AIMonitorMainWindow")
            mainWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        model.setWindowVisible(true)
        scheduleTick(live: shouldUseLiveCadence)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === mainWindow else { return }

        model.setWindowVisible(false)
        scheduleTick(live: false)

        // `windowWillClose` runs inside AppKit's close-button action. Releasing
        // the controller (or the window itself) synchronously here leaves that
        // action with stale references. Tear down on the next main-run-loop turn
        // instead. The visibility guard also makes an immediate Dock/menu reopen
        // win a very small race rather than having its window pulled away.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window,
                  self.mainWindow === window,
                  !window.isVisible else { return }
            window.contentViewController = nil
            window.delegate = nil
            self.mainWindow = nil
            // With no window, nothing draws a character or a star field: a
            // menu-bar-only app should not keep their bitmaps resident.
            MascotArt.purge()
            CharacterPack.purgeAll()
            Stars.purge()
        }
    }

    // MARK: Menu bar

    private func attachStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applySkinToStatusItem(model.skin)
        renderMenuBar()
    }

    /// `MonitorModel.refresh()` publishes after its background sync and
    /// queries finish. Rendering before that async work (the old timer path)
    /// necessarily showed the previous tick and left a first launch with no
    /// menu at all. Observe the three values the status item presents and
    /// rebuild only after their new values arrive on the main run loop.
    private func observeMenuPresentation() {
        guard menuObservers.isEmpty else { return }
        Publishers.CombineLatest3(model.$dashboard, model.$live, model.$language)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                self.renderMenuBar()
                // A refresh publishes `live` after the background store read.
                // Re-evaluate here so a just-opened live session gets the 2s
                // cadence immediately instead of waiting for the next 15s tick.
                self.scheduleTick(live: self.shouldUseLiveCadence)
            }
            .store(in: &menuObservers)
        model.$skin
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] skin in self?.applySkinToStatusItem(skin) }
            .store(in: &menuObservers)
    }

    /// 瞬き — the menu-bar cat blinks, and the quota rotates on the blink.
    ///
    /// Same sensibility as the page mascot: a held cel, a brief squash, back —
    /// two frames a few seconds apart, not an 8fps loop. Status-item redraws
    /// are not free, and a cat that fidgets in the corner of the screen stops
    /// being a pet and starts being a notification. The provider hand-off
    /// happens *while the eyes are shut*: the cat blinks and a different name
    /// is standing there, one motion in one rhythm. This is called by the main
    /// monitoring tick instead of owning another repeating timer. The 4.2s gate
    /// keeps a 2s live tick restrained; the 15s idle tick naturally lowers idle
    /// wakeups. In Low Power Mode the cat holds still but quota still rotates.
    private func advanceMenuBarPresentation(now: Date = Date()) {
        guard now.timeIntervalSince(lastMenuBarBlinkAt) >= Self.menuBarBlinkInterval else { return }
        lastMenuBarBlinkAt = now

        if let data = model.dashboard,
           (model.store.setting("menubar_metric") ?? "quota") == "quota",
           !data.quotas.isEmpty {
            quotaRotationIndex = (quotaRotationIndex + 1) % data.quotas.count
            if let title = Self.quotaTitle(data.quotas, index: quotaRotationIndex) {
                statusItem?.button?.title = " \(title)"
            }
        }
        guard model.animationsEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              let button = statusItem?.button,
              let base = menuBarCat, let blink = menuBarCatBlink else { return }
        button.image = blink
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            self?.statusItem?.button?.image = base
        }
    }

    /// The menu-bar mark follows the skin: the cat, her camera by day, a
    /// crescent and stars at night. All keep the same two-cel blink.
    private func applySkinToStatusItem(_ skin: Skin) {
        let mark: NSImage?
        switch skin {
        case .observatory:
            mark = Self.loadMenuBarCat()
        case .aubade:
            // Her camera.
            mark = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "AI Monitor")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            mark?.isTemplate = true
        case .nocturne:
            mark = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: "AI Monitor")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            mark?.isTemplate = true
        }
        guard let mark else { return }
        menuBarCat = mark
        menuBarCatBlink = Self.squashed(mark)
        statusItem?.button?.image = mark
        statusItem?.button?.imagePosition = .imageLeading
        lastMenuBarBlinkAt = Date()
    }

    /// A one-cel blink: the same drawing squashed toward its baseline. Generated
    /// once from the static art so the menu bar needs no second asset on disk.
    static func squashed(_ image: NSImage, yScale: CGFloat = 0.8) -> NSImage {
        let size = image.size
        let out = NSImage(size: size, flipped: false) { _ in
            image.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height * yScale),
                       from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1)
            return true
        }
        out.isTemplate = true
        return out
    }

    /// Template image — inverts with the menu bar style.
    static func loadMenuBarCat() -> NSImage? {
        let image = AppResources.image(named: "menubar-cat")
        image?.isTemplate = true
        return image
    }

    private func renderMenuBar() {
        // Timer fires on the main run loop; the model is MainActor-isolated.
        MainActor.assumeIsolated {
            guard let data = model.dashboard else { return }
            renderMenuBar(data: data)
        }
    }

    @MainActor
    private func renderMenuBar(data: StoreReport.Dashboard) {
        let store = model.store
        let lang = model.language

        let metric = store.setting("menubar_metric") ?? "quota"
        let title: String
        switch metric {
        case "tokens": title = StoreReport.compact(data.todayTokens)
        case "time": title = StoreReport.duration(minutes: data.todayActiveMinutes)
        case "cost": title = data.todayCostUSD.map { "~" + ReportFormatter.money(Decimal($0)) } ?? "n/a"
        case "none": title = ""
        default:
            title = Self.quotaTitle(data.quotas, index: quotaRotationIndex)
                ?? StoreReport.compact(data.todayTokens)
        }
        statusItem?.button?.title = title.isEmpty ? "" : " \(title)"

        let menu = NSMenu()
        func header(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func row(_ s: String) { let i = NSMenuItem(title: "   " + s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }

        header("AI Monitor")
        // Every conversation that is writing, not just the one that wrote
        // last: the menu is the only place a user sees this without opening
        // the window, and naming one of three running sessions reads as "the
        // other two are idle". Same source as the dashboard rows, so the two
        // cannot drift apart. `ageText` floors at zero — log timestamps can
        // sit ahead of this clock.
        if let live = model.live {
            for session in live.sessions where session.isLive {
                let project = StoreReport.liveRowProject(of: session, among: live.sessions)
                row("● \(session.provider)\(session.model.map { " · \(TimelineRow.shortModel($0))" } ?? "")"
                    + (project.map { " · \($0)" } ?? "")
                    + " · \(StoreReport.compact(session.billable)) · "
                    + (session.clockDisagrees
                       ? L10n.text(.clockAhead, lang).replacingOccurrences(of: "%@", with: StoreReport.shortDuration(session.clockSkew))
                       : "\(StoreReport.ageText(of: session.lastEventAt)) ago"))
            }
            if live.hiddenSessions > 0 {
                row("  " + L10n.text(.moreSessions, lang).replacingOccurrences(of: "%d", with: "\(live.hiddenSessions)"))
            }
        }
        menu.addItem(.separator())
        let costText = data.todayCostUSD.map { "~" + ReportFormatter.money(Decimal($0)) + " eq." } ?? "n/a"
        row("\(L10n.text(.today, lang)): \(StoreReport.compact(data.todayTokens)) tokens · \(StoreReport.duration(minutes: data.todayActiveMinutes)) · \(costText)")

        if !data.usageShares.isEmpty {
            menu.addItem(.separator())
            for share in data.usageShares.prefix(6) {
                row(String(format: "%-14@ %3.0f%%  %@", share.provider as NSString, share.fraction * 100, StoreReport.compact(share.billable)))
            }
        }
        if !data.quotas.isEmpty {
            menu.addItem(.separator())
            for q in data.quotas {
                row(String(format: "%@ %@ — %.0f%% · %@", q.provider, q.window.label, q.window.usedPercent,
                           StoreReport.resetDescription(q.window.resetsAt, lang: lang)))
            }
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: L10n.text(.openDashboard, lang), action: #selector(openDashboard), keyEquivalent: "d")
        open.target = self
        menu.addItem(open)
        let resync = NSMenuItem(title: L10n.text(.syncNow, lang), action: #selector(forceSync), keyEquivalent: "r")
        resync.target = self
        menu.addItem(resync)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.text(.quit, lang), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu

        maybeNotify(quotas: data.quotas)
    }

    // MARK: Menu bar quota rotation

    /// Quota title naming the provider, at `index` in the rotation.
    ///
    /// The old behaviour showed only the *tightest* window — right for an
    /// alarm, wrong for a status line: every other provider stayed invisible
    /// until it became the worst. Rotation names each one in turn, so a glance
    /// says whose number it is. The index is a plain counter advanced by the
    /// monitoring tick, so the hand-off always lands exactly on the cat's blink.
    static func quotaTitle(_ quotas: [StoreReport.QuotaView], index: Int) -> String? {
        guard !quotas.isEmpty else { return nil }
        let q = quotas[index % quotas.count]
        return "\(shortProvider(q.provider)) \(Int(q.window.usedPercent.rounded()))%"
    }

    /// Menu-bar width is scarce: "Codex CLI" → "Codex", "Kimi Code" → "Kimi".
    static func shortProvider(_ name: String) -> String {
        for suffix in [" CLI", " Code"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    @objc private func openDashboard() {
        showMainWindow()
        model.refresh()
    }

    @objc private func forceSync() {
        MainActor.assumeIsolated { model.refresh() }
    }

    /// Local notifications: off by default. Enabled via `notifications_enabled`;
    /// fires once per threshold (80/90/100) per window per session.
    private func maybeNotify(quotas: [StoreReport.QuotaView]) {
        guard model.store.setting("notifications_enabled") == "true" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        for q in quotas {
            let window = q.window
            let crossed = [100, 90, 80].filter { window.usedPercent >= Double($0) }.max()
            guard let threshold = crossed else {
                // A quota reset normally drops below 80%. Forget the previous
                // cycle so a later crossing can notify again in this process.
                notifiedThresholds.removeValue(forKey: window.id)
                continue
            }
            guard (notifiedThresholds[window.id] ?? 0) < threshold else { continue }
            notifiedThresholds[window.id] = threshold

            let content = UNMutableNotificationContent()
            content.title = "AI Monitor — \(q.provider)"
            content.body = "\(window.label) quota reached \(Int(window.usedPercent))%."
            if let p = q.projection,
               p.exhaustedAt.timeIntervalSinceNow < (window.resetsAt?.timeIntervalSinceNow ?? 0) {
                content.body += String(format: " At current pace it runs out in %.0fh %02.0fm.",
                                       floor(p.exhaustedAt.timeIntervalSinceNow / 3600),
                                       p.exhaustedAt.timeIntervalSinceNow.truncatingRemainder(dividingBy: 3600) / 60)
            }
            center.add(UNNotificationRequest(identifier: "quota-\(window.id)-\(threshold)", content: content, trigger: nil))
        }
    }
}
