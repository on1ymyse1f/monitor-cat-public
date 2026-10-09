import AIMonitorCore
import SwiftUI

/// Today, laid out like a product page: a hero with the day's one number and
/// the kitten standing in a spotlight beside it, then the live conversations,
/// quota, usage and flow as cards that rise into view as they are scrolled to.
struct DashboardView: View {
    @EnvironmentObject var model: MonitorModel
    @State private var shareFlash = false
    /// Sections arrive once the first dashboard lands, one after another.
    @State private var appeared = false
    /// Brief lift on the hero number when the day's count ticks up.
    @State private var heroPop = false
    /// The increment to draw rising off the hero number, and a serial so a
    /// second arrival during the first one's fade restarts it rather than
    /// being swallowed by an unchanged view identity.
    @State private var tally: (serial: Int, text: String)?
    @State private var tallySerial = 0
    /// Petting the kitten: she is pleased for a moment, then goes back to
    /// reacting to the page. A serial so a second pat extends the first.
    @State private var petSerial = 0
    @State private var petted = false
    @Environment(\.motionBudget) private var motion
    /// Watched — the night's ambient layers only run while someone looks.
    @Environment(\.isAttended) private var attended

    private var lang: Language { model.language }

    /// Everything the kitten is allowed to react to, gathered in one place.
    private func situation(_ d: StoreReport.Dashboard) -> Mascot.Situation {
        let live = model.live
        // The tightest window is the one worth reacting to; a comfortable
        // weekly figure should not calm the cat down about a spent 5-hour one.
        let tightest = d.quotas.map { max(0, 100 - $0.window.usedPercent) }.min()
        return Mascot.Situation(
            isLive: live?.isLive ?? false,
            quotaRemaining: tightest,
            quotaBlind: d.quotas.isEmpty && !pendingQuotas.isEmpty,
            storeEmpty: d.todayTokens == 0 && (live?.lastEventAt == nil),
            todayTokens: d.todayTokens,
            idleFor: live?.lastEventAt.map { StoreReport.age(of: $0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let d = model.dashboard {
                    hero(d)
                        .arrival(appeared, index: 0)
                        .scrollReveal()
                    // The running counters sit under the day's total, because
                    // the two answer different questions: the hero is "today",
                    // these are "right now, in each conversation".
                    //
                    // One row per session, not one row for the machine. People
                    // run these side by side — Claude Code and Codex CLI in the
                    // same minute is the normal case — and a single row showed
                    // whichever wrote last while the rest went unmentioned.
                    if let live = model.live, !live.sessions.isEmpty {
                        liveSection(live)
                            .arrival(appeared, index: 1)
                            .scrollReveal()
                    }
                    quotaSection(d)
                        .arrival(appeared, index: 2)
                        .scrollReveal()
                    usageSection(d)
                        .arrival(appeared, index: 3)
                        .scrollReveal()
                    flowSection(d)
                        .arrival(appeared, index: 4)
                        .scrollReveal()
                    footer
                        .arrival(appeared, index: 5)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 26)
            .frame(maxWidth: Theme.readingWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            // The dashboard may already be loaded before this view first draws
            // (refresh starts with the app); don't leave the page invisible.
            if model.dashboard != nil { appeared = true }
        }
        .onChange(of: model.dashboard != nil) {
            if model.dashboard != nil, !appeared { appeared = true }
        }
        .onChange(of: model.dashboard?.todayTokens) { previous, current in
            guard appeared, let current else { return }
            heroPop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { heroPop = false }

            // Only an increase we can attribute gets a tally. `previous == nil`
            // is the first load (the whole day's total is not an increment),
            // and a decrease is the midnight rollover or a rebuilt store —
            // neither is consumption, and printing "+today's total" at 00:00
            // every night would be the tally lying once a day, forever.
            guard let previous, current > previous else { return }
            tallySerial += 1
            tally = (tallySerial, CardReport.compact(current - previous, lang: lang))
            let serial = tallySerial
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.tallyHold) {
                // Only clear the tally still on screen; a newer one owns it now.
                if tally?.serial == serial { tally = nil }
            }
        }
    }

    // MARK: Hero

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch Skin.current {
        case .nocturne: return NocturneVoice.greeting(hour: hour, lang)
        case .aubade: return AubadeVoice.greeting(hour: hour, lang)
        case .observatory: break
        }
        switch hour {
        case 5..<12: return L10n.text(.greetingMorning, lang)
        case 12..<18: return L10n.text(.greetingAfternoon, lang)
        case 18..<23: return L10n.text(.greetingEvening, lang)
        default: return L10n.text(.greetingNight, lang)
        }
    }

    /// Claude's home greeting over Apple's hero: a serif hello, the day's
    /// number lettered in the one gradient on the page, and the kitten in a
    /// spotlight reacting to it.
    private func hero(_ d: StoreReport.Dashboard) -> some View {
        let skin = Skin.current
        // Aubade and Nocturne are played by a character: a portrait or a
        // photograph rather than a sticker, and her own words.
        let character = skin.hasCharacter
        let cast: (mood: MascotState.Mood, says: String?)
        if petted {
            let pet: L10n.Key = skin == .nocturne ? .nightPet : skin == .aubade ? .dayPet : .catPet
            cast = (.happy, L10n.text(pet, lang))
        } else if character {
            // Same state, her words.
            let pick = MascotState.castLine(for: situation(d))
            // Every state gets a line: the dialogue window (or the chat) is
            // never left empty, so the calm states have words of their own.
            let happy = pick.mood == .happy
            if skin == .aubade {
                let calm = L10n.text(happy ? .dayHappy : .dayCalm, lang)
                cast = (pick.mood, pick.line.map { AubadeVoice.text($0, lang) } ?? calm)
            } else {
                let calm = L10n.text(happy ? .nightHappy : .nightCalm, lang)
                cast = (pick.mood, pick.line.map { NocturneVoice.text($0, lang) } ?? calm)
            }
        } else {
            cast = Mascot.cast(for: situation(d), lang: lang)
        }
        let ambient = attended && motion.allowsTravel

        return VStack(alignment: .leading, spacing: 12) {
            // The greeting is said in full: in a narrow window the share
            // button gives up its words and keeps its icon, rather than the
            // greeting being cut to "Good morni…".
            ViewThatFits(in: .horizontal) {
                greetingRow(labelled: true)
                greetingRow(labelled: false)
            }

            // Number and chips on the left, the kitten centred against them
            // on the right: the two halves of an Apple hero, product beside
            // headline. In a narrow window she steps back a little rather
            // than squeezing the chips to one per line — decided by `HeroRow`,
            // not `ViewThatFits` (see there for why).
            // A character is a photograph by day and a portrait at night
            // rather than a sticker, and either needs more room to read as a
            // face than a line drawing does.
            HeroRow(cat: character ? 164 : 140, compact: character ? 118 : 108, minLeft: character ? 170 : 196) {
                heroHeadline(d)
                catStage(mood: cast.mood, says: character ? nil : cast.says, width: character ? 160 : 136,
                         ambient: ambient)
            }

            // At night she speaks in a galgame dialogue window across the foot
            // of the card, name plate and all; by day in a chat message, her
            // face beside it. Never a comic balloon over a character.
            if let line = cast.says {
                switch skin {
                case .nocturne:
                    DialogueBox(name: CharacterPack.current?.title, line: line)
                        .padding(.bottom, 6)
                case .aubade:
                    ChatBubble(name: CharacterPack.current?.title,
                               avatar: CharacterPack.current?.avatar(for: cast.mood), line: line)
                        .padding(.bottom, 8)
                case .observatory:
                    EmptyView()
                }
            }
        }
        .padding(18)
        .background {
            // Observatory: the spotlight, and over it focus lines converging
            // on the kitten — Apple's product shot and a manga splash panel
            // at once. Nocturne: moonlight, gold sparkles, fallen petals.
            ZStack {
                switch Skin.current {
                case .observatory:
                    HeroGlow()
                    FocusLines()
                case .aubade:
                    DayHeroBackdrop()
                case .nocturne:
                    NightHeroBackdrop()
                    NightAmbience(running: ambient)
                    VStack {
                        Spacer(minLength: 0)
                        LaceBand()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.heroCorner, style: .continuous))
        }
        .card(corner: Theme.heroCorner)
    }

    private func heroHeadline(_ d: StoreReport.Dashboard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                // 描き文字: the day's number lettered like a sound effect, with
                // a keyline of the card's own colour so the focus lines pass
                // behind it instead of through it.
                DrawnLettering(text: CardReport.compact(d.todayTokens, lang: lang), size: 50)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(heroPop && motion.allowsTravel ? 1.04 : 1, anchor: .bottomLeading)
                    .animation(motion.animation(Motion.press), value: heroPop)
                    .animation(motion.animation(Motion.settle), value: d.todayTokens)
                    // The tally rides above the number's top-right, outside
                    // the glyphs; a zero-size overlay takes no width from the
                    // kitten.
                    .overlay(alignment: .topTrailing) {
                        if let tally {
                            RisingTally(text: tally.text)
                                .id(tally.serial)
                                .offset(x: 30, y: 2)
                                .transition(.opacity)
                        }
                    }
                    .animation(motion.animation(Motion.turn), value: tally?.serial)
                Text(L10n.text(.tokensToday, lang))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }
            HeroStats(items: [
                (StoreReport.duration(minutes: d.todayActiveMinutes), L10n.text(.time, lang)),
                // Cents stop being information past $100, and on a heavy day
                // they were the two characters that pushed the row past the
                // narrowest window.
                (d.todayCostUSD.map { String(format: $0 >= 100 ? "$%.0f" : "$%.2f", $0) } ?? "n/a",
                 L10n.text(.cost, lang)),
                ("\(d.todayRequests)", L10n.text(.requests, lang)),
            ])
        }
    }

    /// The kitten on her spot: a warm spotlight behind, a soft contact shadow
    /// under her feet, her line in a bubble above. Click to pet her.
    /// Flexible up to `width`: `HeroRow` proposes a smaller width in a narrow
    /// window and the kitten, her shadow and her bubble scale to it.
    @ViewBuilder
    private func catStage(mood: MascotState.Mood, says: String?, width: CGFloat, ambient: Bool) -> some View {
        Group {
            switch Skin.current {
            case .nocturne: mirrorStage(mood: mood, says: says, width: width, ambient: ambient)
            case .aubade: photoStage(mood: mood, width: width)
            case .observatory: stickerStage(mood: mood, says: says, width: width)
            }
        }
        // Hearts rise from her with every pat.
        .overlay { HeartBurst(trigger: petSerial) }
    }

    /// At night she stands in the moon mirror; her words go to the dialogue
    /// window. No `.id(mood)` here: the same portrait layer is kept, so a new
    /// expression arrives with its pop (see `MascotCels`) instead of a fade.
    private func mirrorStage(mood: MascotState.Mood, says: String?, width: CGFloat, ambient: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            MoonMirror {
                ZStack {
                    Mascot(mood: mood, width: width, tilt: 0, flexible: true, mirror: true)
                    MirrorGlint(running: ambient)
                }
            }
        }
        .frame(maxWidth: width + 4)
        .contentShape(Rectangle())
        .onTapGesture { pet() }
        .animation(motion.animation(Motion.press), value: mood)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: says)
        .accessibilityAddTraits(.isButton)
    }

    /// By day she is in a photograph she just took, dated in the margin; her
    /// words go to the chat message under the card. Tap to pet her, as ever.
    private func photoStage(mood: MascotState.Mood, width: CGFloat) -> some View {
        InstantPhoto(caption: Self.photoCaption()) {
            Mascot(mood: mood, width: width, tilt: 0, flexible: true, floats: true)
        }
        .padding(.top, 6)
        .frame(maxWidth: width + 4)
        .contentShape(Rectangle())
        .onTapGesture { pet() }
        .animation(motion.animation(Motion.press), value: mood)
        .accessibilityAddTraits(.isButton)
    }

    /// The photo's margin: today's date the way a camera prints it.
    private static func photoCaption() -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        return String(format: "%02d.%02d ☆", c.month ?? 0, c.day ?? 0)
    }

    private func stickerStage(mood: MascotState.Mood, says: String?, width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            // A sticker stands on something; a portrait dissolving into the
            // night does not, so only the observatory draws a floor.
            if Skin.current == .observatory {
                Ellipse()
                    .fill(RadialGradient(colors: [Theme.text.opacity(0.12), .clear],
                                         center: .center, startRadius: 0, endRadius: width * 0.38))
                    .frame(height: 16)
                    .padding(.horizontal, width * 0.09)
                    .offset(y: 3)
            }
            Mascot(mood: mood, width: width, tilt: 2, says: says, flexible: true)
                .id(mood)
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
        }
        .frame(maxWidth: width + 4)
        .contentShape(Rectangle())
        .onTapGesture { pet() }
        .animation(motion.animation(Motion.press), value: mood)
        .accessibilityAddTraits(.isButton)
    }

    private func pet() {
        petSerial += 1
        let serial = petSerial
        petted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if petSerial == serial { petted = false }
        }
    }

    private func greetingRow(labelled: Bool) -> some View {
        HStack(alignment: .center, spacing: 7) {
            BrandMark()
                .frame(width: 13, height: 13)
            Text(greeting)
                .font(Theme.serif(17))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: labelled, vertical: false)
            Spacer(minLength: 6)
            shareButton(labelled: labelled)
        }
    }

    private func shareButton(labelled: Bool) -> some View {
        Button {
            shareFlash = model.shareTodayImage() != nil
            if shareFlash {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { shareFlash = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: shareFlash ? "checkmark" : "square.and.arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                if labelled {
                    Text(shareFlash ? L10n.text(.shareDone, lang) : L10n.text(.share, lang))
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.sunken, in: Capsule(style: .continuous))
            .contentTransition(.opacity)
            .animation(motion.animation(Motion.turn), value: shareFlash)
        }
        .buttonStyle(.pressable)
        .fixedSize()
        .help(L10n.text(.share, lang))
        .accessibilityLabel(L10n.text(.share, lang))
    }

    // MARK: Live

    private func liveSection(_ live: EventStore.LiveCounters) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(L10n.text(.activeNow, lang), cat: live.isLive ? .stalk : .curl)
            ForEach(live.sessions) { session in
                LiveSessionRow(session: session, peers: live.sessions, lang: lang)
            }
            if live.hiddenSessions > 0 {
                HiddenSessionsNote(hidden: live.hiddenSessions, lang: lang)
            }
        }
    }

    // MARK: Quota

    /// Providers the user switched on that are not (yet) reporting a window.
    ///
    /// These get a card of their own instead of being left off the board. A
    /// board showing one provider when three are enabled looks like the other
    /// two are idle; it actually meant nobody ever checked whether they failed.
    private var pendingQuotas: [(provider: String, health: QuotaHealth)] {
        var out: [(String, QuotaHealth)] = []
        let live = Set((model.dashboard?.quotas ?? []).map(\.provider))
        if model.claudeQuotaEnabled, !live.contains(ClaudeQuotaProvider.providerName) {
            out.append((ClaudeQuotaProvider.providerName, model.claudeQuotaHealth))
        }
        if model.kimiQuotaEnabled, !live.contains(KimiQuotaProvider.providerName) {
            out.append((KimiQuotaProvider.providerName, model.kimiQuotaHealth))
        }
        if model.cursorQuotaEnabled, !live.contains(CursorQuotaProvider.providerName) {
            out.append((CursorQuotaProvider.providerName, model.cursorQuotaHealth))
        }
        return out
    }

    private func quotaSection(_ d: StoreReport.Dashboard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(L10n.text(.quota, lang), cat: .loaf)
            if d.quotas.isEmpty && pendingQuotas.isEmpty {
                EmptyNote(text: L10n.text(.noQuotaData, lang), cat: .flop)
            } else {
                // Every card on the board is cut to the same height — the
                // fullest card's, not a constant sized for a worst case that
                // left most boards half empty.
                let height = QuotaCard.height(for: d.quotas, withPending: !pendingQuotas.isEmpty)
                CardGrid(minimum: 160) {
                    ForEach(d.quotas, id: \.window.id) { q in
                        QuotaCard(q: q, lang: lang, height: height)
                    }
                    ForEach(pendingQuotas, id: \.provider) { item in
                        QuotaUnavailableCard(provider: item.provider, health: item.health, lang: lang,
                                             height: height)
                    }
                }
            }
        }
    }

    // MARK: Usage

    private func usageSection(_ d: StoreReport.Dashboard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(L10n.text(.usage, lang), cat: .groom)
            if d.usageShares.isEmpty {
                EmptyNote(text: L10n.text(.noUsageToday, lang), cat: .mug)
            } else {
                UsageBreakdown(shares: d.usageShares, lang: lang)
                    .padding(16)
                    .card()
            }
        }
    }

    // MARK: Token flow

    private func flowSection(_ d: StoreReport.Dashboard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                SectionHeader(L10n.text(.tokenFlow, lang), cat: .mouse)
                Spacer(minLength: 8)
                RangePicker(selection: $model.flowRange)
            }
            if d.flow.isEmpty {
                EmptyNote(text: L10n.text(.noUsageInRange, lang), cat: .play)
            } else {
                FlowChart(flow: d.flow, hourly: d.flowIsHourly)
                    .padding(16)
                    .card()
            }
        }
    }

    // MARK: Footer

    private static var footerLine: L10n.Key {
        switch Skin.current {
        case .observatory: return .localFirst
        case .aubade: return .dayFooter
        case .nocturne: return .nightFooter
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Mascot(mood: .sleep, width: 34, tilt: 0, animated: false)
                .accessibilityHidden(true)
            Text(L10n.text(Self.footerLine, lang))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

/// Headline on the left, the kitten on the right, both centred on one line.
///
/// The kitten takes `cat` points while the headline keeps at least `minLeft`,
/// and steps down to `compact` when it would not. This used to be a
/// `ViewThatFits` over two copies of the row — which keeps *both* candidates
/// alive to measure them, so two 8fps kittens were ticking and every cel made
/// it re-measure, re-laying out the entire page eight times a second: about a
/// quarter of a core while the window was being looked at. A layout that
/// picks a width once per size change costs nothing per frame.
struct HeroRow: Layout {
    var cat: CGFloat
    var compact: CGFloat
    var minLeft: CGFloat
    var gap: CGFloat = 4

    private func widths(_ total: CGFloat) -> (left: CGFloat, cat: CGFloat) {
        let c = total - cat - gap >= minLeft ? cat : compact
        return (max(0, total - c - gap), c)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let total = proposal.width ?? (minLeft + gap + cat)
        let (l, c) = widths(total)
        let left = subviews[0].sizeThatFits(ProposedViewSize(width: l, height: nil))
        let right = subviews[1].sizeThatFits(ProposedViewSize(width: c, height: nil))
        return CGSize(width: total, height: max(left.height, right.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (l, c) = widths(bounds.width)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: l, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(width: c, height: nil))
    }
}

/// The hero's spotlight: a warm clay glow behind where the kitten stands and
/// a fainter rose one opposite, drawn once as static gradients. It drifts a
/// little slower than the page while scrolling — Apple's parallax, costing a
/// single offset per scroll step and nothing while still.
private struct HeroGlow: View {
    @Environment(\.motionBudget) private var motion

    var body: some View {
        let travel = motion.allowsTravel
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent.opacity(0.26), Theme.accent.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 120))
                    .frame(width: 240, height: 240)
                    .position(x: geo.size.width - 78, y: geo.size.height * 0.46)
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.88, green: 0.44, blue: 0.48).opacity(0.10), .clear],
                                         center: .center, startRadius: 0, endRadius: 150))
                    .frame(width: 300, height: 300)
                    .position(x: 30, y: -30)
            }
        }
        .visualEffect { content, proxy in
            let y = proxy.frame(in: .scrollView).minY
            return content.offset(y: travel ? max(0, -y) * 0.35 : 0)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Quota cards

/// One provider's quota window. The big figure is what **remains**, beside a
/// ring that empties as it is spent — Apple Watch's vocabulary for "how much
/// of this is left today".
///
/// Under 10% left the card turns brick-tinted, the ring and figure go red,
/// and the kitten turns up cross about it from the corner.
struct QuotaCard: View {
    let q: StoreReport.QuotaView
    let lang: Language
    var height: CGFloat = QuotaCard.height(extraLines: 3)

    /// Title block + figure + padding, then one line per optional caption
    /// (reset, pace, as-of). `maxHeight` does not clip in SwiftUI, so a card
    /// that outgrew it used to draw its last line *under* the next card; the
    /// clip in `body` is the belt to this arithmetic's braces.
    static func height(extraLines: Int) -> CGFloat { 112 + 18 * CGFloat(min(3, extraLines)) }

    /// The height every card on a board shares: the fullest card's. A card
    /// with no number (`QuotaUnavailableCard`) carries a sentence of reason,
    /// which needs about as much room as two captions.
    static func height(for quotas: [StoreReport.QuotaView], withPending: Bool) -> CGFloat {
        let lines = quotas.map { q in
            (q.window.resetsAt != nil ? 1 : 0) + (q.projection != nil ? 1 : 0)
                + (q.window.staleness() != .live ? 1 : 0)
        }.max() ?? 0
        return max(height(extraLines: lines), withPending ? 152 : 0)
    }

    private var remaining: Double { max(0, 100 - q.window.usedPercent) }
    private var critical: Bool { remaining < 10 }
    /// Quota read from a log or a cache file is only as fresh as the last
    /// write, and how long that stays meaningful depends on the window.
    private var staleness: QuotaWindow.Staleness { q.window.staleness() }
    private var isStale: Bool { staleness != .live }

    private func staleNote(_ lang: Language) -> String {
        let zh = lang.resolved == .zh
        let fmt = DateFormatter()
        fmt.locale = zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        fmt.dateFormat = zh ? "M月d日 HH:mm" : "MMM d, HH:mm"
        let stamp = fmt.string(from: q.window.observedAt)
        // Say how far off it could be, not just when it was taken: on a rolling
        // window the age *is* the error bar.
        if let age = staleness.age {
            let drift = min(100, age / (Double(q.window.windowMinutes) * 60) * 100)
            if drift >= 1 { return stamp + String(format: " ±%.0f%%", drift) }
        }
        return (zh ? "更新于 " : "as of ") + stamp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(q.provider)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(q.window.label)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                QuotaRing(fraction: remaining / 100,
                          color: critical ? Theme.danger : Theme.color(forProvider: q.provider))
                    // At night the ring is dressed as the clock it is: it
                    // counts down to a reset.
                    .padding(Skin.current == .nocturne ? 4 : 0)
                    .background { if Skin.current == .nocturne { ClockTicks() } }
                    .frame(width: Skin.current == .nocturne ? 40 : 34, height: Skin.current == .nocturne ? 40 : 34)
            }

            Spacer(minLength: 2)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(remaining.rounded()))")
                    .font(Theme.figure(30))
                    .foregroundStyle(critical ? Theme.danger : Theme.text)
                    .contentTransition(.numericText())
                    .animation(Motion.settle, value: remaining)
                Text("% " + L10n.text(.remaining, lang))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(critical ? Theme.danger.opacity(0.8) : Theme.textMuted)
                    .padding(.leading, 3)
            }

            if q.window.resetsAt != nil {
                Theme.mono(StoreReport.resetDescription(q.window.resetsAt, lang: lang),
                           size: 10.5, color: Theme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let p = q.projection {
                Text(String(format: L10n.text(.exhaustedIn, lang), QuotaRow.pace(p.exhaustedAt)))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(critical ? Theme.danger : Theme.accentStrong)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if isStale {
                Text(staleNote(lang))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        // The cross kitten sits *over* the card's corner, added after the clip
        // so she can break the frame — the one overflow this page wants.
        .overlay(alignment: .bottomTrailing) {
            if critical {
                // An impact frame: the burst slams in behind the cross kitten
                // and breaks the card's edge, the way a comic shows something
                // bursting out of the panel. With her on the page — day or
                // night — the burst is ice, her element.
                ZStack {
                    if Skin.current.hasCharacter {
                        FrostBurst().fill(Theme.surface)
                        FrostBurst().stroke(Theme.frost, lineWidth: 1.3)
                    } else {
                        Starburst(spikes: 12, innerRatio: 0.66)
                            .fill(Theme.surface)
                        Starburst(spikes: 12, innerRatio: 0.66)
                            .stroke(Theme.text, lineWidth: 1.3)
                    }
                    Mascot(mood: .angry, width: 52, tilt: 6, animated: false)
                        .offset(y: 3)
                }
                .frame(width: 78, height: 78)
                .offset(x: 12, y: 14)
                .transition(.scale(scale: 1.6).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(Motion.press, value: critical)
        // Trouble here: screentone gathering in the corner on the manga page;
        // at night, the mirror cracking from the corner the burst sits in.
        .background {
            if critical {
                Group {
                    if Skin.current == .nocturne {
                        MirrorCracks()
                            .stroke(Theme.frost.opacity(0.32), style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))
                    } else {
                        Screentone(color: Theme.danger, opacity: 0.22)
                            .mask(LinearGradient(colors: [.clear, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            }
        }
        .card(tone: critical ? .danger : .plain)
    }
}

/// A ring that empties as quota is spent. Drawn in once from empty on appear.
struct QuotaRing: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat
    @State private var shown: Double
    @Environment(\.motionBudget) private var motion

    /// `animateIn: false` starts full for still renders — `ImageRenderer`
    /// captures before `onAppear` has run.
    init(fraction: Double, color: Color, lineWidth: CGFloat = 5, animateIn: Bool = true) {
        self.fraction = fraction
        self.color = color
        self.lineWidth = lineWidth
        _shown = State(initialValue: animateIn ? 0 : fraction)
    }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.sunken, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, shown)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .onAppear { shown = fraction }
        .onChange(of: fraction) { shown = fraction }
        .animation(motion.animation(Motion.settle), value: shown)
    }
}

/// A quota card with no number in it — because there genuinely isn't one, and
/// the reason is worth more than a blank space. A dashed edge says "present on
/// the board, not carrying a measurement"; the kitten peeking says she can't
/// see it either.
struct QuotaUnavailableCard: View {
    let provider: String
    let health: QuotaHealth
    let lang: Language
    var height: CGFloat = 152

    private var headline: String {
        switch health {
        case .checking: return L10n.text(.quotaChecking, lang)
        default: return L10n.text(.quotaUnavailable, lang)
        }
    }

    private var detail: String? {
        if case .unavailable(let key) = health { return L10n.text(key, lang) }
        return nil
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            Text(provider)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(headline)
                .font(Theme.serif(18))
                .foregroundStyle(Theme.textMuted)

            if let detail {
                Text(detail)
                    .font(.system(size: 9.5))
                    .lineSpacing(1.5)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 30)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottomTrailing) {
            Mascot(mood: .peek, width: 58, tilt: 0, mirrored: true, animated: false)
                .offset(x: 6, y: 6)
                .allowsHitTesting(false)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .clipShape(shape)
        .background(Theme.surface.opacity(0.6), in: shape)
        .overlay(shape.strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
    }
}

/// Equal-width cards, as many to a row as fit at `minimum`, but never more
/// columns than there are cards: two quota cards in a wide window share the
/// row instead of huddling at the left of a four-column grid.
struct CardGrid: Layout {
    var minimum: CGFloat = 160
    var spacing: CGFloat = Theme.gutter

    private func geometry(_ width: CGFloat, _ count: Int) -> (columns: Int, cell: CGFloat) {
        let fit = max(1, Int((width + spacing) / (minimum + spacing)))
        let columns = max(1, min(count, fit))
        return (columns, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    }

    private func rowHeights(_ subviews: Subviews, columns: Int, cell: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }
                .max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimum
        let (columns, cell) = geometry(width, subviews.count)
        let rows = rowHeights(subviews, columns: columns, cell: cell)
        return CGSize(width: width, height: rows.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columns, cell) = geometry(bounds.width, subviews.count)
        let rows = rowHeights(subviews, columns: columns, cell: cell)
        var y = bounds.minY
        for (r, height) in rows.enumerated() {
            for c in 0..<columns {
                let i = r * columns + c
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(c) * (cell + spacing), y: y),
                                  proposal: ProposedViewSize(width: cell, height: height))
            }
            y += height + spacing
        }
    }
}

struct QuotaRow: View {
    let q: StoreReport.QuotaView
    let lang: Language

    var body: some View { QuotaCard(q: q, lang: lang) }

    /// Time until a projected exhaustion, as a bare duration ("22h 14m");
    /// the sentence around it comes from `L10n.exhaustedIn`.
    static func pace(_ date: Date) -> String {
        let t = date.timeIntervalSinceNow
        if t < 3600 { return "\(max(1, Int(t / 60)))m" }
        if t < 86400 { return "\(Int(t / 3600))h \(Int(t.truncatingRemainder(dividingBy: 3600) / 60))m" }
        return "\(Int(t / 86400))d"
    }
}

// MARK: - Usage breakdown

/// Apple's storage bar: one capsule split into coloured segments, with a
/// legend underneath. Reads as "how today divides" at a glance, where a bar
/// per provider made the reader compare lengths across rows.
struct UsageBreakdown: View {
    let shares: [(provider: String, billable: Int, fraction: Double)]
    let lang: Language
    @State private var drawn: Bool
    @Environment(\.motionBudget) private var motion

    init(shares: [(provider: String, billable: Int, fraction: Double)], lang: Language, animateIn: Bool = true) {
        self.shares = shares
        self.lang = lang
        _drawn = State(initialValue: !animateIn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GeometryReader { geo in
                let gaps = CGFloat(max(0, shares.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(Array(shares.enumerated()), id: \.offset) { _, s in
                        Rectangle()
                            .fill(Theme.color(forProvider: s.provider))
                            .frame(width: max(3, (geo.size.width - gaps) * s.fraction * (drawn ? 1 : 0)))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 12)
            .background(Theme.sunken)
            .clipShape(Capsule(style: .continuous))
            .animation(motion.animation(Motion.reveal), value: drawn)

            VStack(spacing: 9) {
                ForEach(Array(shares.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(Theme.color(forProvider: s.provider))
                            .frame(width: 8, height: 8)
                        Text(s.provider)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Theme.mono(CardReport.compact(s.billable, lang: lang), size: 11.5, color: Theme.textMuted)
                        Theme.mono("\(Int((s.fraction * 100).rounded()))%", size: 12, weight: .semibold, color: Theme.text)
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                }
            }
        }
        .onAppear { drawn = true }
    }
}

/// The flow range, as a small segmented control matching the tab strip.
struct RangePicker: View {
    @Binding var selection: StoreReport.FlowRange
    @EnvironmentObject var model: MonitorModel
    @Namespace private var pill
    @Environment(\.motionBudget) private var motion

    private func label(_ r: StoreReport.FlowRange) -> String {
        switch r {
        case .today: return L10n.text(.rangeToday, model.language)
        case .week: return L10n.text(.range7D, model.language)
        case .month: return L10n.text(.range30D, model.language)
        case .all: return L10n.text(.rangeAll, model.language)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StoreReport.FlowRange.allCases, id: \.self) { range in
                Button {
                    selection = range
                    model.refresh()
                } label: {
                    Text(label(range))
                        .font(.system(size: 10.5, weight: selection == range ? .semibold : .medium))
                        .foregroundStyle(selection == range ? Theme.text : Theme.textMuted)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background {
                            if selection == range {
                                Capsule(style: .continuous)
                                    .fill(Theme.surface)
                                    .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "range-pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(2)
        .background(Theme.sunken, in: Capsule(style: .continuous))
        .animation(motion.animation(Motion.press), value: selection)
        .fixedSize()
    }
}
