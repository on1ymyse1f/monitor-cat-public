import AIMonitorCore
import SwiftUI

// MARK: - Timeline page

/// Claude's "Recents": a quiet list grouped by day, serif day headings that
/// stay pinned while their rows scroll, and a hover wash on each row.
struct TimelineView: View {
    @EnvironmentObject var model: MonitorModel

    private var providers: [String] {
        Array(Set(model.timeline.map(\.provider))).sorted()
    }

    private var days: [(String, [EventStore.TimelineEvent])] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let grouped = Dictionary(grouping: model.timeline) { fmt.string(from: $0.timestamp) }
        return grouped.sorted { $0.key > $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Button(L10n.text(.allProviders, model.language)) { model.timelineProvider = nil; model.refresh() }
                    Divider()
                    ForEach(providers, id: \.self) { p in
                        Button(p) { model.timelineProvider = p; model.refresh() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.timelineProvider.map { Theme.color(forProvider: $0) } ?? Theme.textFaint)
                            .frame(width: 7, height: 7)
                        Text(model.timelineProvider ?? L10n.text(.allProviders, model.language))
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.sunken, in: Capsule(style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)

            if model.timeline.isEmpty {
                MascotEmptyState(text: L10n.text(.noEvents, model.language), lang: model.language, mood: .blanket)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(days, id: \.0) { day, events in
                            Section {
                                ForEach(events, id: \.timestamp) { e in
                                    TimelineRow(e: e)
                                }
                            } header: {
                                Text(Self.dayLabel(day, lang: model.language))
                                    .font(Theme.serif(15, weight: .medium))
                                    .foregroundStyle(Theme.text)
                                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.window)
                            }
                        }
                    }
                    .padding(.bottom, 16)
                    .frame(maxWidth: Theme.readingWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    static func dayLabel(_ yyyyMMdd: String, lang: Language) -> String {
        let inFmt = DateFormatter(); inFmt.dateFormat = "yyyy-MM-dd"
        guard let d = inFmt.date(from: yyyyMMdd) else { return yyyyMMdd }
        let zh = lang.resolved == .zh
        if Calendar.current.isDateInToday(d) { return zh ? "今天" : "Today" }
        if Calendar.current.isDateInYesterday(d) { return zh ? "昨天" : "Yesterday" }
        let outFmt = DateFormatter()
        outFmt.locale = zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        outFmt.dateFormat = zh ? "M月d日 EEEE" : "EEEE, MMM d"
        return outFmt.string(from: d)
    }
}

struct TimelineRow: View {
    let e: EventStore.TimelineEvent
    @State private var hovering = false

    /// Long model ids collapse to the part that distinguishes them:
    /// "kimi-code/kimi-for-coding" → "kimi-for-coding", "claude-opus-5" stays.
    static func shortModel(_ m: String, max limit: Int = 22) -> String {
        let last = m.split(separator: "/").last.map(String.init) ?? m
        return last.count > limit ? String(last.prefix(limit)) + "…" : last
    }

    /// POSIX, or a Mac set to 12-hour time silently rewrites "HH:mm" into
    /// "3:34 PM" and the column wraps.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Theme.mono(Self.clock.string(from: e.timestamp), size: 11, color: Theme.textFaint)
                .frame(width: 38, alignment: .leading)
                .fixedSize()
            Circle()
                .fill(Theme.color(forProvider: e.provider))
                .frame(width: 7, height: 7)
            Text(e.provider)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text)
            if let m = e.model {
                Text(Self.shortModel(m))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            Theme.mono(StoreReport.compact(e.billable), size: 11.5, weight: .medium, color: Theme.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovering ? Theme.sunken : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
    }
}

// MARK: - Models page

struct ModelsView: View {
    @EnvironmentObject var model: MonitorModel

    private var maxBillable: Int { max(1, model.models.map(\.billable).max() ?? 1) }

    /// Priced models only, ranked by cost. An unpriced model stays in the
    /// list below — a missing price is absent data, never a zero slice.
    private var costSlices: [(model: String, cost: Double)] {
        model.models
            .compactMap { m in m.costUSD.flatMap { $0 > 0 ? (m.model, $0) : nil } }
            .sorted { $0.cost > $1.cost }
    }

    var body: some View {
        ScrollView {
            if model.models.isEmpty {
                MascotEmptyState(text: L10n.text(.noEvents, model.language), lang: model.language, mood: .boxpaws)
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    if !costSlices.isEmpty {
                        costRingSection(costSlices)
                            .scrollReveal()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(L10n.text(.tabModels, model.language), cat: .box)
                        VStack(spacing: 0) {
                            ForEach(Array(model.models.enumerated()), id: \.element.model) { i, m in
                                if i > 0 { Hairline().padding(.leading, 16) }
                                modelRow(m)
                            }
                        }
                        .card()
                    }
                    .scrollReveal()
                }
                .padding(.horizontal, 20).padding(.vertical, 18)
                .frame(maxWidth: Theme.readingWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func modelRow(_ m: EventStore.ModelTotals) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.model)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Theme.mono(StoreReport.compact(m.billable), size: 12.5, weight: .semibold, color: Theme.text)
            }
            HStack {
                Circle().fill(Theme.color(forProvider: m.provider)).frame(width: 6, height: 6)
                Text(m.provider).font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                Spacer()
                Text("\(m.requests) \(L10n.text(.requestsSuffix, model.language)) · \(m.costUSD.map { "$" + String(format: "%.2f", $0) } ?? L10n.text(.unpriced, model.language))")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
            }
            TrackBar(fraction: Double(m.billable) / Double(maxBillable),
                     color: Theme.color(forProvider: m.provider).opacity(0.85), height: 5)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    /// Ring left, legend right — the legend's swatches are the arcs' colours
    /// by construction.
    private func costRingSection(_ slices: [(model: String, cost: Double)]) -> some View {
        let total = slices.map(\.cost).reduce(0, +)
        // Top ranks get their own colour; the tail merges into one "other"
        // slice on the neutral stone.
        let named = CostRing.slots - 1
        let head = slices.prefix(named).map { (TimelineRow.shortModel($0.model), $0.cost) }
        let tailCost = slices.dropFirst(named).map(\.cost).reduce(0, +)
        let hasOther = tailCost > 0
        let rows = head + (hasOther ? [(L10n.text(.other, model.language), tailCost)] : [])

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(L10n.text(.costByModel, model.language), cat: .fish)
            HStack(alignment: .center, spacing: 20) {
                CostRing(slices: rows.map { (label: $0.0, value: $0.1) },
                         centerTitle: Self.compactCost(total),
                         centerCaption: L10n.text(.totalCost, model.language),
                         hasOther: hasOther)
                    .frame(width: 116, height: 116)
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(CostRing.color(rank: i, of: rows.count, hasOther: hasOther))
                                .frame(width: 8, height: 8)
                            Text(row.0)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Theme.mono("\(Int((row.1 / total * 100).rounded()))%", size: 11, color: Theme.textMuted)
                            Theme.mono(Self.compactCost(row.1), size: 11, weight: .medium, color: Theme.text)
                                .frame(minWidth: 52, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(16)
            .card()
        }
    }

    /// $476.83 under four figures, $3.98k past them.
    private static func compactCost(_ usd: Double) -> String {
        if usd >= 1000 { return "$" + String(format: "%.2fk", usd / 1000) }
        return "$" + String(format: "%.2f", usd)
    }
}

// MARK: - Settings page

/// System Settings' grouped cards in Claude's colours: a serif heading per
/// group, rows separated by hairlines inside one card.
struct SettingsView: View {
    @EnvironmentObject var model: MonitorModel
    @State private var retention = "90"
    @State private var notifications = false
    @State private var confirmDelete = false
    @State private var exportedPath: String?

    private var lang: Language { model.language }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                group(L10n.text(.appearance, lang), cat: .groom) {
                    // The room first: it decides what the rest of this group
                    // can change (the night has no light mode).
                    row {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(L10n.text(.theme, lang)).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                choices(Skin.allCases.map { ($0.rawValue, themeLabel($0)) },
                                        selected: model.skin.rawValue) {
                                    model.setSkin(Skin(rawValue: $0) ?? .observatory)
                                }
                            }
                            if model.skin.hasCharacter, CharacterPack.pack(for: model.skin) == nil {
                                Text(L10n.text(.characterPackNone, lang))
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                                    .lineSpacing(1.5)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Hairline()
                    // Labelled like its neighbours. It used to be the one row in
                    // the group with no name — three chips hanging under
                    // "Theme", so it read as a sub-choice of the room rather
                    // than the light/dark switch it is.
                    row {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(L10n.text(.appearanceMode, lang)).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                choices([("system", L10n.text(.appearanceSystem, lang)),
                                         ("light", L10n.text(.appearanceLight, lang)),
                                         ("dark", L10n.text(.appearanceDark, lang))],
                                        selected: model.appearance) { model.setAppearance($0) }
                                    .disabled(model.skin.forcedScheme != nil)
                                    .opacity(model.skin.forcedScheme != nil ? 0.45 : 1)
                            }
                            if let forced = model.skin.forcedScheme {
                                Text(L10n.text(forced == .light ? .themeAlwaysLight : .themeAlwaysDark, lang))
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                    Hairline()
                    row {
                        HStack {
                            Text(L10n.text(.language, lang)).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            choices([(Language.system.rawValue, L10n.text(.languageSystem, lang)),
                                     (Language.en.rawValue, "English"),
                                     (Language.zh.rawValue, "中文")],
                                    selected: model.language.rawValue) {
                                model.setLanguage(Language(rawValue: $0) ?? .system)
                            }
                        }
                    }
                    Hairline()
                    toggleRow(L10n.text(.animations, lang), detail: L10n.text(.animationsDetail, lang),
                              isOn: Binding(get: { model.animationsEnabled },
                                            set: { model.setAnimationsEnabled($0) }))
                }

                group(L10n.text(.quota, lang), cat: .loaf) {
                    toggleRow(L10n.text(.claudeQuota, lang), detail: L10n.text(.claudeQuotaDetail, lang),
                              isOn: Binding(get: { model.claudeQuotaEnabled },
                                            set: { model.setClaudeQuotaEnabled($0) }))
                    Hairline()
                    toggleRow(L10n.text(.kimiQuota, lang), detail: L10n.text(.kimiQuotaDetail, lang),
                              isOn: Binding(get: { model.kimiQuotaEnabled },
                                            set: { model.setKimiQuotaEnabled($0) }))
                    Hairline()
                    toggleRow(L10n.text(.cursorQuota, lang), detail: L10n.text(.cursorQuotaDetail, lang),
                              isOn: Binding(get: { model.cursorQuotaEnabled },
                                            set: { model.setCursorQuotaEnabled($0) }))
                    Hairline()
                    toggleRow(L10n.text(.notifications, lang), detail: L10n.text(.notificationsDetail, lang),
                              isOn: $notifications)
                        .onChange(of: notifications) {
                            try? model.store.setSetting("notifications_enabled", notifications ? "true" : "false")
                        }
                }

                group(L10n.text(.exportCard, lang), cat: .mug) {
                    row {
                        VStack(alignment: .leading, spacing: 8) {
                            FlowLayoutRow(items: (try? model.store.providersPresent()) ?? []) { p in
                                Button {
                                    exportedPath = model.exportCard(provider: p)?.path
                                } label: {
                                    HStack(spacing: 5) {
                                        Circle().fill(Theme.color(forProvider: p)).frame(width: 6, height: 6)
                                        Text(p).font(.system(size: 11.5, weight: .medium))
                                    }
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Theme.sunken, in: Capsule(style: .continuous))
                                }
                                .buttonStyle(.pressable)
                            }
                            if let exportedPath {
                                Text("\(L10n.text(.exportCardDone, lang))\(exportedPath)")
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                group(L10n.text(.retention, lang), cat: .bed) {
                    row {
                        choices([("7", L10n.text(.retention7, lang)), ("30", L10n.text(.retention30, lang)),
                                 ("90", L10n.text(.retention90, lang)), ("365", L10n.text(.retentionYear, lang)),
                                 ("0", L10n.text(.retentionForever, lang))],
                                selected: retention) { value in
                            retention = value
                            try? model.store.setSetting("retention_days", value)
                            try? model.store.applyRetention()
                        }
                    }
                    Hairline()
                    row {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(confirmDelete ? L10n.text(.deleteConfirm, lang) : L10n.text(.deleteAll, lang)) {
                                if confirmDelete {
                                    try? model.store.deleteAllData()
                                    confirmDelete = false
                                    model.refresh()
                                } else {
                                    confirmDelete = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmDelete = false }
                                }
                            }
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(confirmDelete ? Color.white : Theme.danger)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(confirmDelete ? Theme.danger : Theme.dangerSoft, in: Capsule(style: .continuous))
                            .animation(Motion.turn, value: confirmDelete)
                            .buttonStyle(.pressable)
                            Text(L10n.text(.deleteNote, lang))
                                .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                group(L10n.text(.collectorsAccess, lang), cat: .peek) {
                    collectorNote("Claude Code", L10n.text(.claudeCollectorNote, lang))
                    Hairline()
                    collectorNote("Codex CLI", L10n.text(.codexCollectorNote, lang))
                    Hairline()
                    collectorNote("Kimi Code", L10n.text(.kimiCollectorNote, lang))
                    Hairline()
                    row {
                        Text(L10n.text(.storageNote, lang))
                            .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: Theme.readingWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            retention = model.store.setting("retention_days") ?? "90"
            notifications = model.store.setting("notifications_enabled") == "true"
        }
    }

    // MARK: Building blocks

    /// "Nocturne · 长夜月" when a character pack is installed for the theme,
    /// so the choice says who will be on the page.
    private func themeLabel(_ skin: Skin) -> String {
        let base: String
        switch skin {
        case .observatory: return L10n.text(.themeObservatory, lang)
        case .aubade: base = L10n.text(.themeAubade, lang)
        case .nocturne: base = L10n.text(.themeNocturne, lang)
        }
        return CharacterPack.pack(for: skin).map { "\(base) · \($0.title)" } ?? base
    }

    private func group<Content: View>(_ title: String, cat: MascotState.Mood? = nil,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title, cat: cat)
            VStack(alignment: .leading, spacing: 0) { content() }
                .card(corner: 16)
        }
        .scrollReveal()
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        row {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    Toggle(title, isOn: isOn)
                        .labelsHidden()
                        .toggleStyle(.switch).controlSize(.mini)
                        .tint(Theme.accent)
                }
                Text(detail)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A row of pill choices, the selected one filled in clay.
    private func choices(_ options: [(String, String)], selected: String,
                         _ pick: @escaping (String) -> Void) -> some View {
        FlowLayoutRow(items: options.map(\.0)) { value in
            let label = options.first { $0.0 == value }?.1 ?? value
            let on = value == selected
            Button { pick(value) } label: {
                Text(label)
                    .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(on ? Theme.accent : Theme.sunken, in: Capsule(style: .continuous))
            }
            .buttonStyle(.pressable)
            .animation(Motion.turn, value: on)
        }
    }

    private func collectorNote(_ name: String, _ body: String) -> some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.color(forProvider: name)).frame(width: 6, height: 6)
                    Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                }
                Text(body).font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Pills that wrap onto a new line instead of truncating when the window is
/// narrow or a translation runs long.
struct FlowLayoutRow<Item: Hashable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { cell($0) }
        }
    }
}

/// Minimal wrapping layout: left to right, next line when full.
///
/// Its *ideal* width (no width proposed) is its widest single item, not every
/// item on one line: this layout would rather wrap than insist on a row.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
