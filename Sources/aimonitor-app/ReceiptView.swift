import AIMonitorCore
import SwiftUI

// MARK: - 小票 / The settlement slip

/// The day's — or the week's — token bill, printed as a shop receipt.
///
/// A receipt is the one financial document everybody already knows how to
/// read: items, quantities, a unit price, a total, and a stamp that says it is
/// settled. So the page borrows the whole object rather than its look:
///
///   * **Items** are models: tokens are the quantity, the effective rate per
///     million tokens is the unit price, and the money is the line amount.
///   * **Unpriced lines stay on the slip without a price** and out of the
///     total, and the slip says so — a receipt that printed $0.00 for them
///     would add up to a smaller number than anyone actually spent.
///   * **It is printed.** On arrival the paper ratchets out of the printer's
///     slot a line at a time, at a printer's pace, with the text already on
///     it; the cutter fires and the slip drops free; then the seal lands.
///     Switching 1D ⇄ 7D tears the old slip off as the new one prints, and a
///     click on a printing slip feeds the rest out at once. All of it is
///     one-shot and event-driven: a printed slip is a still page.
///
/// The paper follows the skin — warm thermal paper with a cut zigzag edge in
/// the observatory, a white ticket with a punched edge taped into her album
/// by day, plum paper with a scalloped lace edge and a ribbon at night — and
/// so does the cashier, who is whoever the skin's character is.
struct ReceiptView: View {
    @EnvironmentObject var model: MonitorModel
    @Environment(\.motionBudget) private var motion
    /// The slip whose paper is running, if any — the printer's light and its
    /// noise follow it. A token, not a flag: a torn-off slip finishing late
    /// must not switch the printer off under the slip now printing.
    @State private var running: UUID?
#if DEBUG
    @Environment(\.receiptFilm) private var film
#endif

    private var lang: Language { model.language }

    private var busy: Bool {
#if DEBUG
        if let film { return film.clock < 1 }
#endif
        return running != nil
    }

    var body: some View {
        ScrollView {
            // Room above the printer for the cashier sitting on it.
            VStack(spacing: 34) {
                SpanToggle(selected: model.receiptSpan, receipts: model.receipts, lang: lang) { span in
                    // The tear-off and the new print are both transitions of
                    // the slip's identity; animating the span drives them.
                    withAnimation(motion.animation(Motion.tear)) { model.setReceiptSpan(span) }
                }

                VStack(spacing: 0) {
                    PrinterSlot(lang: lang, busy: busy, hasPaper: model.receipts[model.receiptSpan] != nil)
                        .zIndex(2)
                    ZStack(alignment: .top) {
                        if let slip = model.receipts[model.receiptSpan] {
                            ReceiptSlip(receipt: slip, lang: lang) { token, on in
                                if on { running = token } else if running == token { running = nil }
                            }
                                // A new identity per span: switching prints a
                                // fresh slip rather than rewriting this one.
                                // Live updates within a span keep the identity
                                // and roll their figures in place instead.
                                .id(model.receiptSpan)
                                .transition(.asymmetric(
                                    insertion: .identity,          // it prints itself on appear
                                    removal: motion.allowsTravel
                                        ? .modifier(active: TornOff(progress: 1), identity: TornOff(progress: 0))
                                        : .opacity))
                        } else {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity, minHeight: 200)
                        }
                    }
                    // The slip starts just under the slot's lip.
                    .padding(.top, -6)
                }
                .frame(maxWidth: 340)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - 1D ⇄ 7D

/// Two segments, each carrying its own total, with a pill that slides between
/// them — so the choice also reads as a comparison before anything is tapped.
private struct SpanToggle: View {
    let selected: Receipt.Span
    let receipts: [Receipt.Span: Receipt]
    let lang: Language
    let pick: (Receipt.Span) -> Void
    @Namespace private var pill
    @Environment(\.motionBudget) private var motion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Receipt.Span.allCases, id: \.self) { span in
                let on = span == selected
                Button { pick(span) } label: {
                    VStack(spacing: 1) {
                        Text(L10n.text(span == .day ? .receiptSpanDay : .receiptSpanWeek, lang))
                            .font(.system(size: 12, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? Theme.text : Theme.textMuted)
                        Theme.mono(Self.money(receipts[span]?.pricedCostUSD), size: 10.5,
                                   weight: on ? .semibold : .regular,
                                   color: on ? Theme.accentStrong : Theme.textFaint)
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if on {
                            SkinPill(trigger: span.rawValue)
                                .matchedGeometryEffect(id: "span-pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.sunken, in: Capsule(style: .continuous))
        .frame(maxWidth: 300)
        .animation(motion.animation(Motion.press), value: selected)
        .animation(motion.animation(Motion.settle), value: receipts[.day]?.pricedCostUSD)
        .animation(motion.animation(Motion.settle), value: receipts[.week]?.pricedCostUSD)
        .focusEffectDisabled()
    }

    static func money(_ v: Double?) -> String {
        v.map { String(format: "$%.2f", $0) } ?? "—"
    }
}

// MARK: - The printer

/// The slot the slip feeds out of: a dark lip with a status light. The light
/// is the skin's live colour while a slip is printing and settles to its
/// accent afterwards — set by the slip, never on a timer — and while it runs
/// the printer's noise is lettered beside it, the way a manga panel draws a
/// sound.
private struct PrinterSlot: View {
    let lang: Language
    let busy: Bool
    let hasPaper: Bool
    @Environment(\.motionBudget) private var motion

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(LinearGradient(colors: [Theme.text.opacity(0.88), Theme.text.opacity(0.72)],
                                     startPoint: .top, endPoint: .bottom))
            // The slit itself.
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.55))
                .frame(height: 3)
                .padding(.horizontal, 16)
                .offset(y: 2)
            HStack {
                Circle().fill(busy ? Theme.live : Theme.accent).frame(width: 5, height: 5)
                    .background {
                        // A static glow while the motor runs: one extra
                        // circle, no blur, no pulse.
                        Circle().fill(Theme.live.opacity(busy ? 0.35 : 0)).frame(width: 11, height: 11)
                    }
                Spacer()
            }
            .padding(.horizontal, 10)
            .offset(y: -1)
        }
        .frame(height: 14)
        // The slit's shadow on the paper leaving it — the edge the paper
        // comes out from under, rather than a line it is cut off at.
        .overlay(alignment: .bottom) {
            if hasPaper {
                LinearGradient(colors: [Color.black.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 7)
                    .padding(.horizontal, 18)
                    .offset(y: 7)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            DrawnLettering(text: L10n.text(.receiptPrinting, lang), size: 13,
                           fill: Theme.text, keyline: Theme.window, outline: 1.4)
                .fixedSize()
                .rotationEffect(.degrees(-6))
                .offset(x: 14, y: -17)
                .opacity(busy ? 1 : 0)
                .scaleEffect(busy ? 1 : 0.7, anchor: .bottomLeading)
                .allowsHitTesting(false)
        }
        .animation(motion.animation(Motion.turn), value: busy)
        // The cashier sits on the printer with her paws over its front edge —
        // drawn after the slot, so the paws are in front of it. She stays put
        // while slips are printed and torn off beneath her.
        .overlay(alignment: .bottomTrailing) {
            // Its own frame: an overlay is offered the slot's 14pt height,
            // and a fitted sticker in 14pt is a dot.
            Mascot(mood: .peek, width: 58, tilt: -3, animated: false)
                .frame(width: 58, height: 52, alignment: .bottom)
                .fixedSize()
                .offset(x: -22, y: 9)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, -8)
        .accessibilityHidden(true)
    }
}

// MARK: - The slip

/// A slip and its printing. This view only sequences the print — run, cut,
/// seal — and leaves the paper's movement to Core Animation (`PaperRun`), so
/// the seconds the paper takes to come out cost the app nothing per frame:
/// the render server plays the ratchet while the app sleeps, the way the
/// kitten's cels are played (see `MascotCels`).
struct ReceiptSlip: View {
    let receipt: Receipt
    let lang: Language
    /// Tells the printer when this slip's paper starts and stops running.
    var onRunning: (UUID, Bool) -> Void = { _, _ in }

    @State private var stage: PaperRun.Stage = .inSlot
    /// The seal: 0 = in the air, 1 = pressed into the paper.
    @State private var stamp: CGFloat = 0
    @State private var token = UUID()
    @Environment(\.motionBudget) private var motion
    @Environment(\.appAnimations) private var appAnimations
    @Environment(\.isAttended) private var attended
    @Environment(\.lowPowerMode) private var lowPower
#if DEBUG
    @Environment(\.receiptFilm) private var film
#endif

    private var filming: ReceiptFilmFrame? {
#if DEBUG
        return film
#else
        return nil
#endif
    }

    var body: some View {
        PaperRun(stage: stage, frozen: filming.map { ($0.clock, $0.hang) },
                 duration: Self.printDuration(receipt), onEnded: cutAndSeal,
                 paper: AnyView(
                    SlipPaper(receipt: receipt, lang: lang, stamp: filming?.stamp ?? stamp,
                              animatesSeal: filming == nil && motion.allowsTravel, onTap: rushOut)
                        // A hosting view of its own does not inherit these.
                        .environment(\.appAnimations, appAnimations)
                        .environment(\.isAttended, attended)
                        .environment(\.lowPowerMode, lowPower)))
            .onAppear(perform: printSlip)
            .onDisappear { if stage.isRunning { onRunning(token, false) } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(SlipPaper.summary(receipt, lang: lang))
    }

    /// Prints itself on appear: the paper runs, the cutter fires, the seal
    /// lands. With motion off the slip is simply there, sealed — a still
    /// receipt is still a receipt.
    private func printSlip() {
        if filming != nil { return }
        guard motion.allowsTravel else { stage = .still; stamp = 1; return }
        stage = .running
        onRunning(token, true)
    }

    /// A click on a printing slip: the rest of it comes out at once.
    private func rushOut() {
        if stage == .running { stage = .rushing }
    }

    /// The run (or the rush) is over: the cutter fires, then the seal lands —
    /// the paper's own `.animation` delays it by `Motion.stampDelay`.
    private func cutAndSeal() {
        guard stage.isRunning else { return }
        stage = .cut
        onRunning(token, false)
        stamp = 1
    }

    /// How long a slip takes to print: its height at the printer's speed. The
    /// height is estimated from what is on it — the fixed parts and the
    /// lines — so the film and the live run agree on it before either is
    /// laid out. Kept between 1.8s and 3.4s: long enough to watch, short
    /// enough that a long week is not a wait.
    static func printDuration(_ r: Receipt) -> TimeInterval {
        let lines = CGFloat(max(1, r.items.count)) * 38
            + (r.span == .week ? CGFloat(r.days.count) * 15 + 40 : 0)
        return Double(min(3.4, max(1.8, (560 + lines) / Motion.printSpeed)))
    }
}

/// The printed paper itself: everything on the slip, still. Only the seal,
/// its chime and the thanks move, and only once.
private struct SlipPaper: View {
    let receipt: Receipt
    let lang: Language
    /// 0 = the seal in the air, 1 = pressed.
    let stamp: CGFloat
    /// Spring the seal in when `stamp` changes (off when filming a frame).
    let animatesSeal: Bool
    let onTap: () -> Void

    private var zh: Bool { lang.resolved == .zh }
    private var skin: Skin { Skin.current }
    private var night: Bool { skin == .nocturne }
    private var ink: Color { Theme.receiptInk }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            DashedRule()
            meta
            DashedRule()
            items
            if receipt.span == .week {
                DashedRule()
                daily
            }
            DoubleRule()
            totals
            DashedRule()
            footer
        }
        .padding(.horizontal, 18)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .foregroundStyle(ink)
        .background { paper }
        .animation(animatesSeal ? Motion.stamp.delay(Motion.stampDelay) : nil, value: stamp)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    // MARK: Paper

    private var paper: some View {
        let shape = ReceiptEdges(style: skin == .nocturne ? .scallop : skin == .aubade ? .ticket : .zigzag)
        return ZStack {
            // A hard contact shadow and a soft lift under the foot — static
            // shapes, not a blurred layer.
            shape.fill(Color.black.opacity(night ? 0.35 : 0.07)).offset(x: 0, y: 2)
            Ellipse()
                .fill(RadialGradient(colors: [Color.black.opacity(night ? 0.35 : 0.10), .clear],
                                     center: .center, startRadius: 0, endRadius: 160))
                .frame(height: 30)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .offset(y: 14)
            shape.fill(Theme.receiptPaper)
            PaperGrain(color: ink, opacity: skin == .observatory ? 0.12 : skin == .aubade ? 0.07 : 0.10)
                .clipShape(shape)
            switch skin {
            case .observatory: EmptyView()
            case .aubade:
                // Glints in the margins, in her gold and her ice.
                DaySprinkle()
                    .clipShape(shape)
            case .nocturne:
                // Frost on the corners of a night slip, and starlight in it.
                FrostSprinkle()
                    .clipShape(shape)
            }
            shape.stroke(ink.opacity(night ? 0.22 : 0.10), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            switch skin {
            case .observatory: EmptyView()
            case .aubade:
                // Taped into the album at the corner, clear of the slot.
                WashiTape()
                    .frame(width: 44, height: 13)
                    .rotationEffect(.degrees(-28))
                    .offset(x: 2, y: 16)
            case .nocturne:
                // Tied on the corner like a gift tag, clear of the slot.
                RibbonBow()
                    .frame(width: 34, height: 20)
                    .rotationEffect(.degrees(-18))
                    .offset(x: 8, y: 14)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 4) {
            BrandMark()
                .frame(width: 20, height: 20)
            Text(L10n.text(night ? .receiptShopNight : skin == .aubade ? .receiptShopDay : .receiptShop, lang))
                .font(Theme.serif(15, weight: .semibold))
                .tracking(zh ? 1 : 1.6)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(L10n.text(.localFirst, lang))
                .font(.system(size: 9.5))
                .foregroundStyle(ink.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 3) {
            row(L10n.text(.receiptNo, lang), "№ " + receipt.number)
            row(spanLabel, Self.stamp(receipt.issuedAt, zh: zh))
            row(L10n.text(.receiptCashier, lang), cashierName + (night ? " ♭" : skin == .aubade ? " ☆" : " ♡"))
        }
        .font(.system(size: 10.5, design: .monospaced))
    }

    private var spanLabel: String {
        let from = SlipDates.string(receipt.from, "MM/dd", zh: zh)
        if receipt.span == .day { return L10n.text(.receiptSpanDay, lang) + " " + from }
        let last = receipt.days.last?.start ?? receipt.issuedAt
        return from + " → " + SlipDates.string(last, "MM/dd", zh: zh)
    }

    private var cashierName: String {
        if let title = CharacterPack.current?.title { return title }
        return L10n.text(.receiptCashierName, lang)
    }

    private func row(_ left: String, _ right: String) -> some View {
        HStack {
            Text(left).foregroundStyle(ink.opacity(0.6))
            Spacer(minLength: 8)
            Text(right).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    // MARK: Items

    private var items: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L10n.text(.receiptItem, lang))
                Spacer()
                Text(L10n.text(.receiptAmount, lang))
            }
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(ink.opacity(0.55))

            if receipt.items.isEmpty {
                VStack(spacing: 6) {
                    Mascot(mood: .sleep, width: 64, tilt: -2, animated: false)
                    Text(L10n.text(.receiptEmpty, lang))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } else {
                ForEach(receipt.items, id: \.model) { item in
                    ItemLine(item: item, lang: lang)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: Daily (7D)

    private var daily: some View {
        let peak = max(1, receipt.days.map(\.tokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text(.receiptDaily, lang))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(ink.opacity(0.55))
            ForEach(Array(receipt.days.enumerated()), id: \.offset) { i, day in
                DayLine(day: day, peak: peak, isToday: i == receipt.days.count - 1, lang: lang)
            }
        }
    }

    // MARK: Totals

    private var totals: some View {
        VStack(alignment: .leading, spacing: 5) {
            row(L10n.text(.receiptTokens, lang), CardReport.compact(receipt.totalTokens, lang: lang))
                .font(.system(size: 11, design: .monospaced))
            // Capitalised to sit under "Tokens"; the hero uses the same
            // word lower-case as a caption.
            row(L10n.text(.requests, lang).capitalized, receipt.totalRequests.formatted())
                .font(.system(size: 11, design: .monospaced))
            if receipt.unpricedItems > 0 || receipt.unpricedTokens > 0 {
                Text(String(format: L10n.text(.receiptUnpricedNote, lang),
                            max(receipt.unpricedItems, 1)))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.6))
            }
            // The total: drawn lettering on a band of screentone, the way a
            // manga panel sets off the one line you are meant to read.
            HStack(alignment: .center) {
                Text(L10n.text(.receiptTotal, lang))
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .tracking(2)
                Spacer(minLength: 6)
                if let cost = receipt.pricedCostUSD {
                    DrawnLettering(text: String(format: "$%.2f", cost), size: 30,
                                   fill: ink, keyline: Theme.receiptPaper, outline: 1.6)
                        .fixedSize()
                } else {
                    Text(L10n.text(.receiptNoPrice, lang))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.6))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                Screentone(color: ink, opacity: night ? 0.16 : 0.12)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .overlay(alignment: .topTrailing) {
                if receipt.pricedCostUSD != nil { chime }
            }
            .padding(.top, 4)
            .animation(Motion.settle, value: receipt.pricedCostUSD)
        }
    }

    /// 擬音 — the register's ding, lettered like a sound effect, popping in
    /// with the seal.
    private var chime: some View {
        // By day the sound is her camera's shutter.
        DrawnLettering(text: L10n.text(skin == .aubade ? .receiptChimeDay : .receiptChime, lang), size: 12,
                       fill: Theme.receiptStamp, keyline: Theme.receiptPaper, outline: 1.2)
            .fixedSize()
            .rotationEffect(.degrees(-8))
            .scaleEffect(0.4 + 0.6 * stamp, anchor: .bottomLeading)
            .opacity(Double(min(1, stamp)))
            .offset(x: -64, y: -14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Text(L10n.text(.receiptDisclaimer, lang))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(ink.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Barcode and seal side by side: the seal used to be placed by
            // offset from the slip's foot, and every footer height put it on
            // the barcode.
            HStack(alignment: .center, spacing: 10) {
                VStack(spacing: 4) {
                    Barcode(seed: receipt.number)
                        .fill(ink.opacity(0.85))
                        .frame(height: 30)
                    Text(receipt.number.map(String.init).joined(separator: " "))
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.55))
                }
                seal
            }
            .padding(.leading, 6)
            // The thanks pops in with the seal, but its room is kept from
            // the start: a bubble inserted into the stack would lengthen the
            // paper after it was printed and cut.
            VStack(alignment: .trailing, spacing: 3) {
                SpeechBubble(text: L10n.text(night ? .receiptThanksNight
                                             : skin == .aubade ? .receiptThanksDay : .receiptThanks, lang))
                    .scaleEffect(0.7 + 0.3 * stamp, anchor: .bottomTrailing)
                    .opacity(Double(min(1, stamp)))
                Mascot(mood: .happy, width: 58, tilt: 3)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 2D accents

    /// 済 — the settlement seal. A double ring in seal ink with the skin's
    /// mark at its heart, pressed at an angle the way a hand presses it.
    private var seal: some View {
        Hanko(text: L10n.text(receipt.isEmpty ? .receiptClosedStamp : .receiptPaid, lang),
              date: receipt.issuedAt, skin: skin)
            .frame(width: 74, height: 74)
            .rotationEffect(.degrees(-26 + 14 * Double(stamp)))
            .scaleEffect(2.1 - 1.1 * stamp)
            .opacity(0.92 * Double(min(1, stamp)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Helpers

    static func summary(_ receipt: Receipt, lang: Language) -> String {
        let money = receipt.pricedCostUSD.map { String(format: "$%.2f", $0) } ?? L10n.text(.receiptNoPrice, lang)
        let paper = SlipPaper(receipt: receipt, lang: lang, stamp: 1, animatesSeal: false, onTap: {})
        return "\(L10n.text(.tabReceipt, lang)) \(paper.spanLabel): \(money), "
            + "\(CardReport.compact(receipt.totalTokens, lang: lang)) tokens"
    }

    static func stamp(_ date: Date, zh: Bool) -> String {
        SlipDates.string(date, "yyyy-MM-dd HH:mm", zh: zh)
    }
}

// MARK: - Lines

/// One model on the slip: name and amount, then quantity × unit price — the
/// supermarket's two-line item, with dot leaders between name and amount.
private struct ItemLine: View {
    let item: Receipt.Item
    let lang: Language
    @State private var hovering = false
    @Environment(\.motionBudget) private var motion

    private var ink: Color { Theme.receiptInk }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Circle().fill(Theme.color(forProvider: item.provider)).frame(width: 6, height: 6)
                    .alignmentGuide(.lastTextBaseline) { d in d[.bottom] - 1 }
                Text(item.model)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                DotLeader()
                    .stroke(ink.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
                    .frame(height: 1)
                    .frame(minWidth: 8)
                Text(amount)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(item.costUSD == nil ? ink.opacity(0.5) : ink)
                    .contentTransition(.numericText())
                    .layoutPriority(2)
            }
            HStack(spacing: 4) {
                Text(quantity)
                if item.costUSD != nil, item.unpricedTokens > 0 {
                    Text("※ " + L10n.text(.receiptPartlyPriced, lang))
                }
                Spacer(minLength: 4)
                Text("×\(item.requests.formatted())")
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(ink.opacity(0.55))
            .padding(.leading, 11)
            .contentTransition(.numericText())
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(ink.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(.horizontal, -4)
        .onHover { hovering = $0 }
        .animation(motion.animation(Motion.turn), value: hovering)
        .animation(motion.animation(Motion.settle), value: item.tokens)
        .help("\(item.provider) · \(item.requests.formatted()) \(L10n.text(.requestsSuffix, lang))")
        .accessibilityElement(children: .combine)
    }

    private var amount: String {
        item.costUSD.map { String(format: "$%.2f", $0) } ?? "※ " + L10n.text(.unpriced, lang)
    }

    /// "4.2M tok × $2.88/M": the effective rate the line was billed at,
    /// computed over the priced tokens only.
    private var quantity: String {
        let qty = CardReport.compact(item.tokens, lang: lang) + " tok"
        let pricedTokens = item.tokens - item.unpricedTokens
        guard let cost = item.costUSD, pricedTokens > 0 else { return qty }
        return qty + String(format: " × $%.2f/M", cost / Double(pricedTokens) * 1_000_000)
    }
}

/// One day of a week's slip: date, a thin bar of its share of the busiest
/// day, tokens and money. A day with nothing on it says the shop was closed.
private struct DayLine: View {
    let day: Receipt.Day
    let peak: Int
    let isToday: Bool
    let lang: Language

    private var ink: Color { Theme.receiptInk }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 66, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if day.tokens == 0 {
                Text(L10n.text(.receiptClosed, lang) + " z")
                    .foregroundStyle(ink.opacity(0.4))
                Spacer(minLength: 0)
                Text("—").foregroundStyle(ink.opacity(0.4))
            } else {
                DayBar(fraction: CGFloat(day.tokens) / CGFloat(peak))
                    .fill(isToday ? Theme.accent : ink.opacity(0.35))
                    .frame(height: 10)
                Text(CardReport.compact(day.tokens, lang: lang))
                    .frame(width: 50, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(day.costUSD.map { String(format: "$%.2f", $0) } ?? "※")
                    .frame(width: 54, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .font(.system(size: 10, weight: isToday ? .semibold : .regular, design: .monospaced))
        .contentTransition(.numericText())
    }

    private var label: String {
        let zh = lang.resolved == .zh
        return (isToday ? "▸" : " ") + SlipDates.string(day.start, zh ? "MM/dd EEE" : "EEE MM/dd", zh: zh)
    }
}

/// A day's share of the busiest day: a capsule drawn at that fraction of its
/// width — a shape, not a `GeometryReader`, so a week's seven bars cost no
/// extra layout pass.
private struct DayBar: Shape {
    var fraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = max(3, rect.width * max(0, min(1, fraction)))
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.midY - 2, width: width, height: 4),
                    cornerRadius: 2, style: .continuous)
    }
}

/// Date formatters are costly to make and a slip prints a dozen dates: one per
/// language and pattern, made once.
@MainActor
private enum SlipDates {
    private static var made: [String: DateFormatter] = [:]

    static func string(_ date: Date, _ pattern: String, zh: Bool) -> String {
        let key = (zh ? "zh|" : "en|") + pattern
        if let f = made[key] { return f.string(from: date) }
        let f = DateFormatter()
        f.locale = Locale(identifier: zh ? "zh_CN" : "en_US")
        f.dateFormat = pattern
        made[key] = f
        return f.string(from: date)
    }
}

// MARK: - Shapes

/// The ratchet the paper leaves the printer on.
///
/// A receipt printer's motor advances the paper a line, stops while the head
/// burns the next one, and advances again — so the paper does not glide, it
/// steps. Each step is spent moving for its first `drive` (eased, so every
/// start and stop is at rest) and standing still for the rest. `PaperRun`
/// plays these steps as Core Animation keyframes; `fed` is the same curve as
/// a function, for drawing one moment of it (the review film).
enum PaperFeed {
    /// One step of paper: about two lines of the slip's text — at the
    /// printer's speed, ten steps a second, slow enough to see each one.
    static let pitch: CGFloat = 26
    /// The part of each step spent moving; the rest is the pause.
    static let drive: CGFloat = 0.55
    /// How far the cutter drops the slip.
    static let hang: CGFloat = 6
    /// The soft shadow under the slip's foot reaches this far below it, and
    /// must start out inside the printer too.
    static let foot: CGFloat = 32

    /// A whole number of steps, so the last one ends exactly in place.
    static func steps(_ travel: CGFloat) -> Int { max(1, Int((travel / pitch).rounded())) }

    /// How far the paper has moved, 0…1, at a point of the run's clock.
    static func fed(_ clock: CGFloat, travel: CGFloat) -> CGFloat {
        let steps = CGFloat(steps(travel))
        let x = max(0, min(1, clock)) * steps
        let k = x.rounded(.down)
        let f = min(1, (x - k) / drive)
        return min(steps, k + f * f * (3 - 2 * f)) / steps
    }
}

/// The slip's paper in the printer: a window whose top edge is the slot, and
/// the paper sliding down through it — played by Core Animation.
///
/// SwiftUI drives its own animations a frame at a time on the main thread:
/// for a paper run that was ~1.1 ms of view-graph and commit work every
/// frame, 120 times a second, for seconds. Here the paper is a hosting view
/// of its own inside a clipping layer, and the run is one keyframe animation
/// on that layer's `sublayerTransform` — handed to the render server once,
/// stepped there, and the app sleeps until the cutter. The rush after a click
/// and the cutter's drop are a basic and a spring animation on the same key.
struct PaperRun: NSViewRepresentable {
    enum Stage: Equatable {
        /// Still inside the printer, waiting to run.
        case inSlot
        case running
        /// Clicked: the rest comes out at once.
        case rushing
        /// Out, cut, dropped into place.
        case cut
        /// In place with no motion at all (Reduce Motion, Low Power).
        case still

        var isRunning: Bool { self == .running || self == .rushing }
    }

    let stage: Stage
    /// Review only: draw this moment (the run's clock, the hang) and run
    /// nothing.
    var frozen: (clock: CGFloat, hang: CGFloat)?
    let duration: TimeInterval
    let onEnded: () -> Void
    let paper: AnyView

    func makeNSView(context: Context) -> Feeder { Feeder(paper: paper) }

    func updateNSView(_ feeder: Feeder, context: Context) {
        feeder.controller.rootView = paper
        feeder.onEnded = onEnded
        feeder.duration = duration
        if let frozen {
            feeder.freeze(clock: frozen.clock, hang: frozen.hang)
        } else {
            feeder.go(stage)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Feeder, context: Context) -> CGSize? {
        let width = proposal.width ?? 340
        return CGSize(width: width, height: nsView.height(for: width))
    }

    final class Feeder: NSView {
        let controller: NSHostingController<AnyView>
        /// The window in the printer's face the paper is seen through. It
        /// reaches past the slip at the sides and the foot so the stroke and
        /// the shadow under the foot are not cut; its top edge is the slot.
        private let slot = Flipped()
        private static let side: CGFloat = 6
        private static let below: CGFloat = 40
        var onEnded: (() -> Void)?
        var duration: TimeInterval = 2.5
        private var stage: Stage?
        private var frozen: (clock: CGFloat, hang: CGFloat)?
        /// A run asked for before the paper had a size to run.
        private var pending = false
        /// When the run began (layer time) and the height it was timed for:
        /// the first layouts can see a height SwiftUI is only probing, and a
        /// slip can grow a line mid-print, so a run is re-timed — same start,
        /// new keyframes — whenever the height it moves changes.
        private var runBegan: CFTimeInterval = 0
        private var runHeight: CGFloat = 0
        private var lastWidth: CGFloat = -1
        private var lastHeight: CGFloat = 0

        init(paper: AnyView) {
            controller = NSHostingController(rootView: paper)
            controller.sizingOptions = []
            super.init(frame: .zero)
            wantsLayer = true
            slot.wantsLayer = true
            slot.layer?.masksToBounds = true
            addSubview(slot)
            slot.addSubview(controller.view)
            // Hidden in the printer until told otherwise.
            place(-10_000)
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        /// The page scrolls under the slip. The paper is a hosting view of its
        /// own, and one with nothing scrollable in it need not hand a wheel
        /// event on to the page's scroll view — so wheel events are never
        /// aimed at it: they land on the view behind, which is in the page.
        override func hitTest(_ point: NSPoint) -> NSView? {
            if NSApp.currentEvent?.type == .scrollWheel { return nil }
            return super.hitTest(point)
        }

        func height(for width: CGFloat) -> CGFloat {
            controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }

        private var travel: CGFloat { bounds.height + PaperFeed.foot }

        override func layout() {
            super.layout()
            slot.frame = CGRect(x: -Self.side, y: 0, width: bounds.width + 2 * Self.side,
                                height: bounds.height + Self.below)
            controller.view.frame = CGRect(x: Self.side, y: 0, width: bounds.width, height: bounds.height)
            if pending, bounds.height > 0 { pending = false; startRun() }
            if stage == .running, bounds.height > 0, abs(bounds.height - runHeight) > 0.5 { startRun(resuming: true) }
            if stage == .inSlot { place(-(travel + PaperFeed.hang)) }
            if let frozen { freeze(clock: frozen.clock, hang: frozen.hang) }
        }

        // MARK: Positions

        /// Points the paper sits below its final place (negative: up, inside
        /// the printer), as the layer's model value.
        private func place(_ down: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            slot.layer?.sublayerTransform = CATransform3DMakeTranslation(0, Self.layerY(down), 0)
            CATransaction.commit()
        }

        /// The slot's layer is flipped like its view (y down), so a point down
        /// on screen is a point down in the layer.
        private static func layerY(_ down: CGFloat) -> CGFloat { down }

        private var shown: CGFloat {
            let layer = slot.layer?.presentation() ?? slot.layer
            return (layer?.value(forKeyPath: "sublayerTransform.translation.y") as? CGFloat) ?? 0
        }

        func freeze(clock: CGFloat, hang: CGFloat) {
            slot.layer?.removeAllAnimations()
            stage = nil
            frozen = (clock, hang)
            place(-travel * (1 - PaperFeed.fed(clock, travel: travel)) - hang)
        }

        func go(_ next: Stage) {
            guard next != stage else { return }
            let previous = stage
            stage = next
            switch next {
            case .inSlot:
                place(-(travel + PaperFeed.hang))
            case .still:
                slot.layer?.removeAllAnimations()
                place(0)
            case .running:
                if bounds.height > 0 { startRun() } else { pending = true }
            case .rushing:
                rush()
            case .cut:
                drop(after: previous)
            }
        }

        // MARK: Animations

        private let key = "sublayerTransform.translation.y"

        /// The run: `2n + 1` keyframes for `n` steps — move, hold, move, hold
        /// — eased on the moves and flat on the holds. The model value is set
        /// to where the run ends, so nothing jumps when it is removed.
        private func startRun(resuming: Bool = false) {
            guard let layer = slot.layer else { return }
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            if !resuming { runBegan = now }
            runHeight = bounds.height
            let travel = self.travel
            let n = PaperFeed.steps(travel)
            let y = { (k: Int) -> CGFloat in -travel * (1 - CGFloat(k) / CGFloat(n)) - PaperFeed.hang }
            var values: [CGFloat] = [y(0)]
            var times: [NSNumber] = [0]
            var curves: [CAMediaTimingFunction] = []
            let move = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
            let hold = CAMediaTimingFunction(name: .linear)
            for k in 0..<n {
                let t0 = Double(k) / Double(n)
                let t1 = Double(k + 1) / Double(n)
                values.append(y(k + 1)); times.append(NSNumber(value: t0 + (t1 - t0) * Double(PaperFeed.drive)))
                curves.append(move)
                values.append(y(k + 1)); times.append(NSNumber(value: t1))
                curves.append(hold)
            }
            place(y(n))
            let run = CAKeyframeAnimation(keyPath: key)
            run.values = values.map { NSNumber(value: Double(Self.layerY($0))) }
            run.keyTimes = times
            run.timingFunctions = curves
            run.duration = duration
            // Resumed: begun in the past, so it carries on where it was.
            run.beginTime = runBegan
            run.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, __preferred: 120)
            run.delegate = Ending { [weak self] finished in
                // A run replaced by a rush stops unfinished; the rush ends it.
                if finished, self?.stage == .running { self?.onEnded?() }
            }
            slot.layer?.add(run, forKey: "run")
        }

        /// The rest of the paper out at once, from wherever it is now.
        private func rush() {
            let from = shown
            slot.layer?.removeAnimation(forKey: "run")
            let end = -PaperFeed.hang
            place(end)
            let rush = CABasicAnimation(keyPath: key)
            rush.fromValue = from
            rush.toValue = Self.layerY(end)
            rush.duration = 0.45
            rush.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.2, 1)
            rush.delegate = Ending { [weak self] finished in
                if finished, self?.stage == .rushing { self?.onEnded?() }
            }
            slot.layer?.add(rush, forKey: "run")
        }

        /// The cutter: the slip drops free into its place on the same spring
        /// SwiftUI would use (`Motion.cutSpring`).
        private func drop(after previous: Stage?) {
            let from = previous == nil || previous == .inSlot ? -PaperFeed.hang : shown
            slot.layer?.removeAnimation(forKey: "run")
            place(0)
            let spring = Motion.cutSpring
            let drop = CASpringAnimation(keyPath: key)
            drop.mass = spring.mass
            drop.stiffness = spring.stiffness
            drop.damping = spring.damping
            drop.fromValue = Self.layerY(from)
            drop.toValue = 0
            drop.duration = drop.settlingDuration
            slot.layer?.add(drop, forKey: "drop")
        }
    }

    /// The slot counts down the page like the slip does.
    private final class Flipped: NSView {
        override var isFlipped: Bool { true }
    }

    /// Calls back when an animation stops; CAAnimation retains its delegate.
    private final class Ending: NSObject, CAAnimationDelegate {
        let done: (Bool) -> Void
        init(_ done: @escaping (Bool) -> Void) { self.done = done }
        func animationDidStop(_ animation: CAAnimation, finished: Bool) { done(finished) }
    }
}

/// One moment of the print, for drawing it frame by frame in review.
struct ReceiptFilmFrame: Equatable {
    var clock: CGFloat
    var hang: CGFloat
    var stamp: CGFloat
}

#if DEBUG
private struct ReceiptFilmKey: EnvironmentKey {
    static let defaultValue: ReceiptFilmFrame? = nil
}

extension EnvironmentValues {
    /// Set only by `--print-film`: draw the print at this moment and do not
    /// run it.
    var receiptFilm: ReceiptFilmFrame? {
        get { self[ReceiptFilmKey.self] }
        set { self[ReceiptFilmKey.self] = newValue }
    }
}
#endif

/// The torn-off slip leaving: up and away, turning as a hand pulls it.
private struct TornOff: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(Double(progress) * -7), anchor: .topLeading)
            .offset(x: progress * -30, y: progress * -46)
            .opacity(1 - Double(progress))
    }
}

/// The slip's outline: a cut zigzag along top and bottom (thermal paper torn
/// against the printer's blade), a ticket's punched edge by day, or a
/// scalloped lace edge at night.
struct ReceiptEdges: Shape {
    enum Style { case zigzag, ticket, scallop }
    var style: Style
    var tooth: CGFloat = 8
    var depth: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let n = max(2, Int((rect.width / tooth).rounded()))
        let step = rect.width / CGFloat(n)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + depth))
        // Top edge, left to right.
        for i in 0..<n {
            let x0 = rect.minX + CGFloat(i) * step
            switch style {
            case .zigzag:
                p.addLine(to: CGPoint(x: x0 + step / 2, y: rect.minY))
                p.addLine(to: CGPoint(x: x0 + step, y: rect.minY + depth))
            case .ticket:
                // A round bite out of the edge every other tooth, like the
                // perforation a ticket is torn along.
                if i.isMultiple(of: 2) {
                    p.addLine(to: CGPoint(x: x0 + step * 0.2, y: rect.minY + depth))
                    p.addArc(center: CGPoint(x: x0 + step / 2, y: rect.minY + depth), radius: step * 0.3,
                             startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
                }
                p.addLine(to: CGPoint(x: x0 + step, y: rect.minY + depth))
            case .scallop:
                p.addQuadCurve(to: CGPoint(x: x0 + step, y: rect.minY + depth),
                               control: CGPoint(x: x0 + step / 2, y: rect.minY - depth))
            }
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
        // Bottom edge, right to left.
        for i in 0..<n {
            let x1 = rect.maxX - CGFloat(i) * step
            switch style {
            case .zigzag:
                p.addLine(to: CGPoint(x: x1 - step / 2, y: rect.maxY))
                p.addLine(to: CGPoint(x: x1 - step, y: rect.maxY - depth))
            case .ticket:
                if i.isMultiple(of: 2) {
                    p.addLine(to: CGPoint(x: x1 - step * 0.2, y: rect.maxY - depth))
                    p.addArc(center: CGPoint(x: x1 - step / 2, y: rect.maxY - depth), radius: step * 0.3,
                             startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
                }
                p.addLine(to: CGPoint(x: x1 - step, y: rect.maxY - depth))
            case .scallop:
                p.addQuadCurve(to: CGPoint(x: x1 - step, y: rect.maxY - depth),
                               control: CGPoint(x: x1 - step / 2, y: rect.maxY + depth))
            }
        }
        p.closeSubpath()
        return p
    }
}

private struct DashedRule: View {
    var body: some View {
        DotLeader()
            .stroke(Theme.receiptInk.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

private struct DoubleRule: View {
    var body: some View {
        VStack(spacing: 2) {
            Rectangle().fill(Theme.receiptInk.opacity(0.5)).frame(height: 1)
            Rectangle().fill(Theme.receiptInk.opacity(0.5)).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// A horizontal line across the middle of its frame, for dashed strokes.
private struct DotLeader: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// A barcode whose bars come from the receipt number, so the same slip always
/// prints the same code. Decoration — it encodes nothing a scanner would read.
private struct Barcode: Shape {
    let seed: String

    func path(in rect: CGRect) -> Path {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        var widths: [CGFloat] = []
        for _ in 0..<44 {
            h ^= h << 13; h ^= h >> 7; h ^= h << 17
            widths.append(CGFloat(1 + h % 3))
        }
        let unit = rect.width / widths.reduce(0, +)
        var p = Path()
        var x = rect.minX
        for (i, w) in widths.enumerated() {
            if i.isMultiple(of: 2) { p.addRect(CGRect(x: x, y: rect.minY, width: w * unit, height: rect.height)) }
            x += w * unit
        }
        return p
    }
}

/// 判子 — the seal. Two rings in seal ink, the word across the middle, and the
/// skin's mark (a paw, her flower, or the crescent) above it. Faintly uneven:
/// a real seal never prints solid.
private struct Hanko: View {
    let text: String
    let date: Date
    let skin: Skin

    var body: some View {
        let ink = Theme.receiptStamp
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ZStack {
                Circle().strokeBorder(ink, lineWidth: d * 0.035)
                // The 日付印 band: two rules across the face with the date
                // between them, the mark above and the word below.
                VStack(spacing: d * 0.03) {
                    Group {
                        switch skin {
                        case .observatory: PawMark()
                        case .aubade: IceFlower()
                        case .nocturne: Image(systemName: "moon.fill").resizable().scaledToFit()
                        }
                    }
                    .frame(width: d * 0.17, height: d * 0.17)
                    Rectangle().fill(ink).frame(width: d * 0.8, height: d * 0.022)
                    Text(Self.day(date))
                        .font(.system(size: d * 0.15, weight: .heavy, design: .monospaced))
                    Rectangle().fill(ink).frame(width: d * 0.8, height: d * 0.022)
                    Text(text)
                        .font(.system(size: d * (text.count > 3 ? 0.13 : 0.16), weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: d * 0.62)
                }
                .foregroundStyle(ink)
            }
            .frame(width: d, height: d)
        }
        // Ink that did not take: screentone knocked out of the seal.
        .mask {
            ZStack {
                Rectangle()
                Screentone(color: .black, opacity: 0.55).blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }

    private static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return String(format: "%02d.%02d", c.month ?? 0, c.day ?? 0)
    }
}

/// A few glints in the margins of a day slip — gold like the "!" around her,
/// ice like her element. Static.
private struct DaySprinkle: View {
    var body: some View {
        GeometryReader { g in
            ForEach(Array(Self.spots.enumerated()), id: \.offset) { i, s in
                Sparkle()
                    .fill((i.isMultiple(of: 2) ? Theme.series[3] : Theme.frost).opacity(0.55))
                    .frame(width: s.size, height: s.size)
                    .position(x: g.size.width * s.x, y: g.size.height * s.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let spots: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (0.965, 0.12, 9), (0.035, 0.40, 7), (0.97, 0.62, 8), (0.035, 0.86, 9),
    ]
}

/// A few ice crystals and specks of starlight on a night slip. Static.
private struct FrostSprinkle: View {
    var body: some View {
        GeometryReader { g in
            ForEach(Array(Self.spots.enumerated()), id: \.offset) { _, s in
                FrostBurst()
                    .stroke(Theme.frost.opacity(0.35), lineWidth: 0.8)
                    .frame(width: s.size, height: s.size)
                    .position(x: g.size.width * s.x, y: g.size.height * s.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let spots: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (0.965, 0.10, 10), (0.03, 0.38, 8), (0.97, 0.58, 9), (0.03, 0.84, 10),
    ]
}
