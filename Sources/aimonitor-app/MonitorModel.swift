import AIMonitorCore
import AppKit
import SwiftUI

// MARK: - Pages

/// Which screen is showing. Owned by the model rather than by `@State` in the
/// view: an `.onAppear`-restores / `.onChange`-saves pair raced on launch —
/// the save fired first with the default value and destroyed the stored tab
/// before the restore ever read it. Loading it once in `MonitorModel.init`,
/// the same way language and appearance are loaded, removes the race instead
/// of trying to order it.
enum Page: String, CaseIterable, Sendable {
    case dashboard, timeline, models, receipt, settings

    func label(_ lang: Language) -> String {
        switch self {
        case .dashboard: return L10n.text(.tabToday, lang)
        case .timeline: return L10n.text(.tabTimeline, lang)
        case .models: return L10n.text(.tabModels, lang)
        case .receipt: return L10n.text(.tabReceipt, lang)
        case .settings: return L10n.text(.tabSettings, lang)
        }
    }
}
// MARK: - Live-quota health

/// What happened the last time an opt-in quota endpoint was asked.
///
/// This exists because the previous code did `if case .success` and dropped
/// every failure on the floor. A user who switched the feature on and got a
/// blank board had no way to tell an expired token from a provider that simply
/// reports nothing — which is the exact "zero is not the same as unknown"
/// mistake this project refuses to make everywhere else.
enum QuotaHealth: Equatable, Sendable {
    case off
    case checking
    case ok
    case unavailable(L10n.Key)

    static func reason(for error: ClaudeQuotaProvider.FetchError) -> L10n.Key {
        switch error {
        case .keychainUnavailable: return .quotaNoToken
        case .tokenExpired: return .quotaTokenExpired
        case .httpStatus: return .quotaServerError
        case .malformed: return .quotaUnexpectedResponse
        }
    }

    static func reason(for error: KimiQuotaProvider.FetchError) -> L10n.Key {
        switch error {
        case .credentialsUnavailable: return .quotaNoToken
        case .tokenExpired: return .quotaTokenExpired
        case .httpStatus: return .quotaServerError
        case .malformed: return .quotaUnexpectedResponse
        }
    }

    static func reason(for error: CursorQuotaProvider.FetchError) -> L10n.Key {
        switch error {
        case .credentialsUnavailable: return .quotaNoToken
        case .tokenExpired: return .quotaTokenExpired
        case .databaseUnavailable, .malformed: return .quotaUnexpectedResponse
        case .httpStatus: return .quotaServerError
        }
    }

}

// MARK: - View model

@MainActor
final class MonitorModel: ObservableObject {
    @Published var dashboard: StoreReport.Dashboard?
    @Published var flowRange: StoreReport.FlowRange = .today
    @Published var timeline: [EventStore.TimelineEvent] = []
    /// The running counter. Refreshed on every tick, including the fast ticks
    /// taken while a session is live.
    @Published var live: EventStore.LiveCounters?
    @Published var models: [EventStore.ModelTotals] = []
    /// The settlement slips, both spans at once, so switching 1D ⇄ 7D is
    /// immediate and animates from data already in hand. Loaded only while
    /// the Receipt tab is on screen.
    @Published var receipts: [Receipt.Span: Receipt] = [:]
    @Published var receiptSpan: Receipt.Span = .day
    @Published var timelineProvider: String? = nil
    @Published var language: Language
    @Published var appearance: String   // "system" | "light" | "dark"
    /// Which room the page is printed in. Mirrored into `Skin.current`, which
    /// every `Theme` colour reads at draw time.
    @Published private(set) var skin: Skin
    @Published var animationsEnabled: Bool
    @Published var claudeQuotaEnabled: Bool
    @Published var kimiQuotaEnabled: Bool
    @Published var cursorQuotaEnabled: Bool
    @Published var claudeQuotaHealth: QuotaHealth = .off
    @Published var kimiQuotaHealth: QuotaHealth = .off
    @Published var cursorQuotaHealth: QuotaHealth = .off
    @Published var page: Page

    let store: EventStore
    let engine: SyncEngine
    /// One lane for fingerprinting, sync and store reads. The previous global
    /// closures could overlap `SyncEngine.sync()` and raced on an explicitly
    /// `nonisolated(unsafe)` fingerprint. A serial lane preserves the engine's
    /// single-writer contract without moving filesystem work onto MainActor.
    private let refreshQueue = DispatchQueue(label: "com.aimonitor.refresh", qos: .utility)
    /// Accessed only on `refreshQueue`; nonisolated so a Sendable GCD closure
    /// never reaches across MainActor for queue-owned state.
    nonisolated(unsafe) private var syncedFingerprint = -1
    /// Full refreshes capture UI filters. A later choice invalidates any older
    /// result still waiting in the queue, so provider A cannot overwrite B.
    private var refreshGeneration = 0
    /// The AppKit owner tells the model whether a SwiftUI tree is mounted.
    ///
    /// The menu bar still needs the dashboard summary and live counters with no
    /// window, but timeline and model analytics have no consumer then. Keeping
    /// this outside `@Published` is deliberate: mounting/unmounting the window
    /// must not itself invalidate the view tree it describes.
    private(set) var isWindowVisible = false
    private var lastClaudeQuotaFetch = Date.distantPast
    private var lastKimiQuotaFetch = Date.distantPast
    private var lastCursorQuotaFetch = Date.distantPast
    private let claudeQuota = ClaudeQuotaProvider()
    private let claudeDesktopQuota = ClaudeDesktopQuota()
    private let kimiQuota = KimiQuotaProvider()
    private let cursorQuota = CursorQuotaProvider()

    /// False for the DEBUG demo and visual review: a refresh then only
    /// re-reads the supplied store. Without this, any refresh — a tab click,
    /// a range change — ran a *first* sync of the user's real provider logs
    /// into the synthetic in-memory store: a full historical scan, most of a
    /// core for as long as it took, in a mode that promises to read no logs.
    private let readsSources: Bool

    init(store suppliedStore: EventStore? = nil, readsSources: Bool = true) throws {
        let s = try suppliedStore ?? EventStore(path: EventStore.defaultPath())
        store = s
        self.readsSources = readsSources
        // One cache for the app's whole lifetime: the point is that a tick
        // costs nothing when nothing moved.
        engine = SyncEngine(store: s, fileSizes: FileSizeCache())
        language = Language(rawValue: s.setting("language") ?? "system") ?? .system
        appearance = s.setting("appearance") ?? "system"
        let savedSkin = Skin(rawValue: s.setting("skin") ?? "") ?? .observatory
        skin = savedSkin
        Skin.current = savedSkin
        animationsEnabled = s.setting("animations_enabled") != "false"
        claudeQuotaEnabled = s.setting("claude_quota_optin") == "true"
        kimiQuotaEnabled = s.setting("kimi_quota_optin") == "true"
        cursorQuotaEnabled = s.setting("cursor_quota_optin") == "true"
        // Every stored property must be assigned before any of them is read
        // back through `self`, so `page` lands here rather than below.
        page = Page(rawValue: s.setting("last_tab") ?? "") ?? .dashboard
        receiptSpan = Int(s.setting("receipt_span") ?? "").flatMap(Receipt.Span.init(rawValue:)) ?? .day
        claudeQuotaHealth = claudeQuotaEnabled ? .checking : .off
        kimiQuotaHealth = kimiQuotaEnabled ? .checking : .off
        cursorQuotaHealth = cursorQuotaEnabled ? .checking : .off
    }

    /// Only a deliberate tab change persists — nothing writes `last_tab` during
    /// launch, so the stored value survives a restart.
    func setPage(_ p: Page) {
        guard page != p else { return }
        page = p
        try? store.setSetting("last_tab", p.rawValue)
        // Page-specific data is loaded lazily. A newly selected page therefore
        // asks for its own read model immediately instead of waiting for the
        // next 15-second full tick.
        if isWindowVisible { refresh() }
    }

    /// The span is a view choice over slips that are both already loaded, so
    /// this only remembers it — no query, no refresh.
    func setReceiptSpan(_ span: Receipt.Span) {
        guard receiptSpan != span else { return }
        receiptSpan = span
        try? store.setSetting("receipt_span", String(span.rawValue))
    }

    /// Called only by `AppDelegate`, which owns the actual NSWindow lifecycle.
    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
    }

    func setLanguage(_ l: Language) {
        language = l
        try? store.setSetting("language", l.rawValue)
    }

    func setAppearance(_ a: String) {
        appearance = a
        try? store.setSetting("appearance", a)
    }

    func setSkin(_ s: Skin) {
        guard skin != s else { return }
        // The global first: the publish below re-renders the tree, and every
        // colour it draws reads `Skin.current`.
        Skin.current = s
        skin = s
        try? store.setSetting("skin", s.rawValue)
    }

    func setAnimationsEnabled(_ enabled: Bool) {
        animationsEnabled = enabled
        try? store.setSetting("animations_enabled", enabled ? "true" : "false")
    }

    func setClaudeQuotaEnabled(_ on: Bool) {
        claudeQuotaEnabled = on
        claudeQuotaHealth = on ? .checking : .off
        // Switching it back on is an explicit "try again": don't make the user
        // wait out the remainder of the 15-minute throttle to see a result.
        lastClaudeQuotaFetch = .distantPast
        try? store.setSetting("claude_quota_optin", on ? "true" : "false")
        if on { refresh() }
    }

    func setKimiQuotaEnabled(_ on: Bool) {
        kimiQuotaEnabled = on
        kimiQuotaHealth = on ? .checking : .off
        lastKimiQuotaFetch = .distantPast
        try? store.setSetting("kimi_quota_optin", on ? "true" : "false")
        if on { refresh() }
    }

    func setCursorQuotaEnabled(_ on: Bool) {
        cursorQuotaEnabled = on
        cursorQuotaHealth = on ? .checking : .off
        lastCursorQuotaFetch = .distantPast
        try? store.setSetting("cursor_quota_optin", on ? "true" : "false")
        if on { refresh() }
    }


    /// Renders today's usage as a manga-style PNG on the Desktop and reveals
    /// it in Finder. Offline; reads only the in-memory dashboard.
    @MainActor
    @discardableResult
    func shareTodayImage() -> URL? {
        guard let d = dashboard else { return nil }
        let renderer = ImageRenderer(content: ShareCardView(d: d, lang: language))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/aimonitor-today-\(fmt.string(from: Date())).png")
        do {
            try png.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch {
            return nil
        }
    }

    /// Writes a shareable profile card (heatmap + streaks) for the provider to
    /// a user-chosen location. Offline; reads only the store.
    func exportCard(provider: String) -> URL? {
        guard let days = try? store.dailyBillable(provider: provider) else { return nil }
        let stats = CardReport.stats(from: days)
        let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        let html = CardReport.html(
            provider: provider, stats: stats,
            name: name, handle: NSUserName(), lang: language
        )
        let slug = provider.replacingOccurrences(of: " ", with: "-").lowercased()
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/aimonitor-card-\(slug).html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// The full refresh: sync if the logs moved, rebuild the menu summary and
    /// live counters, then query only the visible page's additional read model.
    ///
    /// Dashboard data is also the menu bar's source, so it remains current while
    /// the window is closed. Timeline and all-history model totals do not: the
    /// latter is the most expensive store query and previously ran every 15
    /// seconds even with no Models view mounted. Running page-specific work only
    /// when that page is visible keeps the background monitor proportional to
    /// what it actually presents.
    func refresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        // Snapshot actor-isolated UI choices before leaving the main actor.
        // The background closure then touches only Sendable store/engine values.
        let engine = self.engine
        let store = self.store
        let refreshQueue = self.refreshQueue
        let flowRange = self.flowRange
        let timelineProvider = self.timelineProvider
        let loadTimeline = isWindowVisible && page == .timeline
        let loadModels = isWindowVisible && page == .models
        let loadReceipts = isWindowVisible && page == .receipt
        let readsSources = self.readsSources
        refreshQueue.async {
            [weak self, engine, store, flowRange, timelineProvider, loadTimeline, loadModels, loadReceipts] in
            guard let self else { return }
            let fp = readsSources ? engine.logsFingerprint() : self.syncedFingerprint
            if fp != self.syncedFingerprint {
                self.syncedFingerprint = fp
                _ = engine.sync()
            }
            let dash = try? StoreReport.dashboard(from: store, flowRange: flowRange)
            let tl: [EventStore.TimelineEvent]? = loadTimeline
                ? (try? store.recentEvents(provider: timelineProvider)) : nil
            let ms: [EventStore.ModelTotals]? = loadModels
                ? (try? store.totalsByModel()) : nil
            // Two grouped scans of an indexed time range — about 9 ms each on
            // a 109k-event store, a quarter of the Models page's query.
            var slips: [Receipt.Span: Receipt]?
            if loadReceipts {
                var made: [Receipt.Span: Receipt] = [:]
                for span in Receipt.Span.allCases { made[span] = try? store.receipt(span) }
                slips = made
            }
            let counters = try? store.liveCounters()
            DispatchQueue.main.async {
                guard self.refreshGeneration == generation else { return }
                if let dash { self.dashboard = dash }
                if let tl { self.timeline = tl }
                if let ms { self.models = ms }
                // Slips are settled to the minute and Equatable, so an unchanged
                // basket does not invalidate the page on every 15-second tick.
                if let slips, slips != self.receipts { self.receipts = slips }
                self.publishLive(counters)
            }
        }
        guard readsSources else { return }
        updateClaudeQuota()
        maybeFetchKimiQuota()
        maybeFetchCursorQuota()
    }

    /// The fast job: what the running counter needs, and nothing else.
    ///
    /// Two indexed queries and one `@Published` write. The dashboard, timeline,
    /// model totals and quota fetches are all left alone — none of them changes
    /// meaningfully inside two seconds, and rebuilding them at that rate was
    /// paying for a full page redraw to move one number.
    func refreshLive() {
        let engine = self.engine
        let store = self.store
        let refreshQueue = self.refreshQueue
        let readsSources = self.readsSources
        refreshQueue.async { [weak self, engine, store] in
            guard let self else { return }
            let fp = readsSources ? engine.logsFingerprint() : self.syncedFingerprint
            if fp != self.syncedFingerprint {
                self.syncedFingerprint = fp
                _ = engine.sync()
            }
            let counters = try? store.liveCounters()
            DispatchQueue.main.async { self.publishLive(counters) }
        }
    }

    /// Publish only when something a viewer could see actually moved.
    ///
    /// `LiveCounters` is `Equatable` for this reason: an idle machine produces
    /// an identical reading every tick, and assigning it anyway would redraw
    /// the meter — and everything bound to `live` — for no change at all.
    private func publishLive(_ counters: EventStore.LiveCounters?) {
        guard counters != live else { return }
        live = counters
    }

    /// Claude quota: **local first, network only as an opted-in fallback.**
    ///
    /// The desktop app's `plan-usage-history.json` holds the same percentages
    /// its own usage popover shows. Reading it is offline, touches no
    /// credential, and works for people signed in via an API key or a gateway —
    /// who have no Keychain OAuth token at all. It is therefore in the same
    /// category as the log collectors and needs no opt-in; the toggle governs
    /// only the network call, which is the part that reads a token and leaves
    /// the machine.
    private func updateClaudeQuota() {
        let desktop = claudeDesktopQuota
        let provider = claudeQuota
        let store = self.store
        let optedIn = claudeQuotaEnabled
        let mayUseNetwork = optedIn
            && Date().timeIntervalSince(lastClaudeQuotaFetch) >= ClaudeQuotaProvider.minimumInterval
        if mayUseNetwork { lastClaudeQuotaFetch = Date() }

        // Detached: the local read hits the filesystem and the online path
        // shells out to `security`, neither of which belongs on the main actor.
        Task.detached { [self] in
            switch desktop.read() {
            case .success(let windows):
                for w in windows {
                    try? store.insert(quota: w, provider: ClaudeDesktopQuota.providerName)
                }
                await MainActor.run { self.claudeQuotaHealth = .ok }
                return
            case .failure:
                break   // no desktop cache — try the network if allowed
            }

            guard mayUseNetwork else {
                // Throttled, or the user never asked for the online path.
                // Leave the previous verdict alone rather than flapping.
                if !optedIn { await MainActor.run { self.claudeQuotaHealth = .off } }
                return
            }

            let health: QuotaHealth
            switch await provider.fetch() {
            case .success(let windows):
                for w in windows {
                    try? store.insert(quota: w, provider: ClaudeQuotaProvider.providerName)
                }
                health = .ok
            case .failure(let error):
                health = .unavailable(QuotaHealth.reason(for: error))
            }
            await MainActor.run { self.claudeQuotaHealth = health }
        }
    }

    /// The credential mtime the last successful-or-attempted fetch was for.
    /// A change here means the CLI minted a new token, which is the one moment
    /// worth spending a request on.
    private var lastKimiCredentialStamp: Date?

    /// Opt-in, read-only, and driven by the token rather than by a clock.
    ///
    /// The old rule was a flat 15-minute timer, which is exactly the lifetime
    /// of Kimi's access token — two unsynchronised 15-minute cycles, so the
    /// fetch nearly always fired against a token that had already expired and
    /// the quota silently stopped appearing. Now: never spend a request on a
    /// dead token, and fetch immediately when a fresh one shows up.
    private func maybeFetchKimiQuota() {
        guard kimiQuotaEnabled else { return }

        switch kimiQuota.credentialState() {
        case .absent:
            kimiQuotaHealth = .unavailable(.quotaNoToken)
            return
        case .expired:
            // Nothing to be done until the user runs Kimi again — say so
            // instead of reporting a bare "unavailable" every 15 minutes.
            kimiQuotaHealth = .unavailable(.quotaNeedsKimiRunning)
            return
        case .valid(_, let issuedHint):
            let isNewToken = issuedHint != lastKimiCredentialStamp
            let intervalElapsed = Date().timeIntervalSince(lastKimiQuotaFetch) >= KimiQuotaProvider.minimumInterval
            // A brand-new token overrides the rate limit: it is the only window
            // in which this provider can be read at all.
            guard isNewToken || intervalElapsed else { return }
            lastKimiCredentialStamp = issuedHint
        }

        lastKimiQuotaFetch = Date()
        let provider = kimiQuota
        let store = self.store
        Task.detached { [self] in
            let health: QuotaHealth
            switch await provider.fetch() {
            case .success(let windows):
                for w in windows {
                    try? store.insert(quota: w, provider: KimiQuotaProvider.providerName)
                }
                health = .ok
            case .failure(let error):
                health = .unavailable(QuotaHealth.reason(for: error))
            }
            await MainActor.run { self.kimiQuotaHealth = health }
        }
    }

    /// Cursor quota is an opt-in, read-only account query. The provider reads
    /// the app's own state.vscdb and never touches browser cookies or refreshes
    /// the session token.
    private func maybeFetchCursorQuota() {
        guard cursorQuotaEnabled,
              Date().timeIntervalSince(lastCursorQuotaFetch) >= CursorQuotaProvider.minimumInterval
        else { return }
        lastCursorQuotaFetch = Date()
        let provider = cursorQuota
        let store = self.store
        Task.detached { [self] in
            let health: QuotaHealth
            switch await provider.fetch() {
            case .success(let windows):
                for w in windows {
                    try? store.insert(quota: w, provider: CursorQuotaProvider.providerName)
                }
                health = .ok
            case .failure(let error):
                health = .unavailable(QuotaHealth.reason(for: error))
            }
            await MainActor.run { self.cursorQuotaHealth = health }
        }
    }

}
