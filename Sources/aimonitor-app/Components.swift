import AIMonitorCore
import SwiftUI

// MARK: - Shared components

/// A section title in the serif voice, optionally with the kitten sitting at
/// the end of it.
///
/// The cat here is **always a still sticker**. Only the hero kitten is on a
/// clock; every additional 8fps timer would be another thing competing for the
/// same frame, and a sticker at the end of a heading costs nothing.
struct SectionHeader: View {
    let text: String
    var cat: MascotState.Mood?

    init(_ t: String, cat: MascotState.Mood? = nil) {
        self.text = t
        self.cat = cat
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Theme.title(text)
            if let cat {
                Mascot(mood: cat, width: 34, tilt: 2, animated: false)
                    .frame(width: 34, height: 24, alignment: .bottom)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            switch Skin.current {
            case .observatory: EmptyView()
            case .aubade:
                DayFlourish()
                    .alignmentGuide(.lastTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            case .nocturne:
                NightFlourish()
                    .alignmentGuide(.lastTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            }
            Spacer(minLength: 0)
        }
    }
}

/// An empty state with the kitten in it.
///
/// An empty card is where a mascot earns its keep: "nothing here" lands faster
/// and more kindly as a drawing than as a sentence. Each empty place gets its
/// *own* pose, so the cat is telling you which emptiness this is.
struct EmptyNote: View {
    let text: String
    var cat: MascotState.Mood?

    init(text: String, cat: MascotState.Mood? = nil) {
        self.text = text
        self.cat = cat
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let cat {
                Mascot(mood: cat, width: 64, tilt: -2, animated: false)
                    .frame(width: 64, height: 48, alignment: .bottom)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .card()
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

/// A slim capsule bar on a sunken track that fills in from empty on appear.
struct TrackBar: View {
    let fraction: Double
    var color: Color = Theme.accent
    var track: Color = Theme.sunken
    var height: CGFloat = 6

    @State private var shown: Double = 0
    @Environment(\.motionBudget) private var motion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(track)
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: max(height, geo.size.width * min(1, max(0, shown))))
            }
        }
        .frame(height: height)
        .onAppear { shown = fraction }
        .onChange(of: fraction) { shown = fraction }
        .animation(motion.animation(Motion.settle), value: shown)
    }
}

// MARK: - Rising tally

/// The tokens that just arrived, rising off the running total and fading.
///
/// The hero number rolls to its new value, but a roll shows the *result* and
/// hides the *increment* — 1.20M becoming 1.24M reads as almost nothing, when
/// what happened is 40,000 tokens. It only ever draws on an **increase it can
/// attribute**: a first load, a range switch or midnight never print one.
struct RisingTally: View {
    let text: String
    @Environment(\.motionBudget) private var motion
    @State private var lifted = false

    var body: some View {
        HStack(spacing: 2) {
            Text("+").font(Theme.figure(10, weight: .black))
            Text(text).font(Theme.figure(13))
        }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.accent, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).stroke(Theme.text, lineWidth: 1.2))
            .rotationEffect(.degrees(-6))
            .fixedSize()
            // Travel is what Low Power Mode gives up; the figure still appears
            // and still fades, because it is the only place the increment is
            // ever stated.
            .offset(y: lifted && motion.allowsTravel ? -20 : 0)
            .opacity(lifted ? 0 : 1)
            .onAppear {
                guard motion.allowsAnimation else { return }
                withAnimation(Motion.tally.delay(0.9)) { lifted = true }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Token activity trail

/// A brief streak of clay marks emitted only when a live row's total grows.
///
/// Event-driven, never a forever-running shimmer: the source writes usage in
/// batches, so one pass means one real batch landed.
private struct TokenActivityTrail: View {
    @State private var progress: Double = 0
    @Environment(\.motionBudget) private var motion

    private let lanes: [CGFloat] = [-7, 3, -2, 7, 0]

    var body: some View {
        GeometryReader { geo in
            ForEach(lanes.indices, id: \.self) { i in
                let delay = Double(i) * 0.075
                let local = min(1, max(0, (progress - delay) / (1 - delay)))
                Capsule(style: .continuous)
                    .fill(Theme.accent.opacity(0.22 + Double(i % 2) * 0.12))
                    .frame(width: i.isMultiple(of: 2) ? 10 : 5, height: 2)
                    .position(
                        x: 14 + (geo.size.width - 28) * local,
                        y: geo.size.height / 2 + lanes[i]
                    )
                    .opacity(local == 0 || local == 1 ? 0 : 1 - local * 0.72)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .onAppear {
            guard motion.allowsTravel else { return }
            withAnimation(Motion.consume) { progress = 1 }
        }
    }
}

// MARK: - Live session row

/// One live conversation: what it has spent, what that cost, how fast it is
/// going, and how long ago it last wrote.
///
/// Deliberately step-wise. The underlying number arrives in bursts — a tool
/// writes its log per assistant message, not per token — so a counter that
/// glided between readings would be drawing tokens it has not been told
/// about. When nothing is running it does not print a rate of zero: an idle
/// machine has no tokens-per-minute, and zero is a measurement.
///
/// **Every number on the row is this session's.** Running Claude Code and
/// Codex together once printed one session's total beside the whole machine's
/// rate; one scope per row is the fix.
struct LiveSessionRow: View {
    let session: EventStore.LiveSession
    /// Everything on screen beside it, for deciding whether the project slug
    /// is carrying information or just taking width.
    let peers: [EventStore.LiveSession]
    let lang: Language
    @Environment(\.motionBudget) private var motion
    @State private var burstSerial = 0
    @State private var visibleBurst: Int?

    private var rateText: String? {
        guard session.isLive, let rate = session.tokensPerMinute, rate >= 1 else { return nil }
        return CardReport.compact(Int(rate), lang: lang) + "/min"
    }

    var body: some View {
        ZStack {
            if let visibleBurst {
                TokenActivityTrail()
                    .id(visibleBurst)
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    // 呼吸 — the live dot is *drawn*, not animated. A
                    // `repeatForever` pulse pins SwiftUI's render loop to the
                    // display link and measured 14.5% of a core idle, against
                    // 2.0% without. A solid sage dot with a still halo carries
                    // the same state for free; idle is a hollow ring.
                    ZStack {
                        Circle()
                            .fill(Theme.live.opacity(0.2))
                            .frame(width: 14, height: 14)
                            .opacity(session.isLive ? 1 : 0)
                        Circle()
                            .fill(session.isLive ? Theme.live : Color.clear)
                            .overlay(Circle().stroke(session.isLive ? Color.clear : Theme.textFaint, lineWidth: 1.3))
                            .frame(width: 7, height: 7)
                    }
                    .frame(width: 14, height: 14)

                    Text(session.provider)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .layoutPriority(2)
                    if let m = session.model {
                        Text(TimelineRow.shortModel(m, max: 16))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }

                    // Only when another row shares this provider, and dropped
                    // when the clock caption needs the room — both are optional
                    // trailing detail and the line has space for one.
                    if let project = StoreReport.liveRowProject(of: session, among: peers),
                       !session.clockDisagrees {
                        Text(project)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 6)

                    // An age this row cannot honestly state — stamped in the
                    // future by more than drift explains — shows the skew.
                    Group {
                        if session.clockDisagrees {
                            Theme.mono(
                                L10n.text(.clockAhead, lang)
                                    .replacingOccurrences(of: "%@", with: StoreReport.shortDuration(session.clockSkew)),
                                size: 10.5, color: Theme.textMuted)
                        } else {
                            AgeText(since: session.lastEventAt)
                        }
                    }
                    .fixedSize()
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Theme.mono(CardReport.compact(session.billable, lang: lang), size: 15, weight: .semibold,
                               color: Theme.text)
                        .contentTransition(.numericText())
                        .animation(motion.animation(Motion.settle), value: session.billable)

                    Text(L10n.text(.thisSession, lang))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textMuted)

                    // Tokens are the measurement; money is what the reader
                    // feels. The tilde: rates are a published table, not an
                    // invoice.
                    if let cost = session.costUSD, cost > 0 {
                        Theme.mono("~" + ReportFormatter.money(Decimal(cost)), size: 11, color: Theme.textMuted)
                    }

                    Spacer(minLength: 6)

                    if let rateText {
                        Theme.mono(rateText, size: 11, weight: .medium, color: Theme.accentStrong)
                            .contentTransition(.numericText())
                            .animation(motion.animation(Motion.settle), value: rateText)
                    } else {
                        Text(L10n.text(.idle, lang))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .padding(.leading, 23)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .card(corner: 16)
        .onChange(of: session.billable) { previous, current in
            guard current > previous else { return }
            burstSerial &+= 1
            let serial = burstSerial
            visibleBurst = serial
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if visibleBurst == serial { visibleBurst = nil }
            }
        }
        .animation(motion.animation(Motion.turn), value: visibleBurst)
    }
}

/// "12s", "4m": how long since a session last wrote, counting up on its own.
///
/// Scoped to its own clock so the tick re-evaluates this one label rather than
/// the whole row — the row used to hold a one-second timer and redraw its
/// card every second. The cadence follows the unit on display (seconds every
/// second, minutes every ten, hours every minute), and the clock **stops while
/// nobody is looking**: a second-by-second count in a window behind your
/// editor was a layout pass a second for no one. It is right again the moment
/// the window is looked at, because it is recomputed then.
private struct AgeText: View {
    let since: Date
    @Environment(\.isAttended) private var attended

    var body: some View {
        if attended {
            let age = StoreReport.age(of: since)
            let step: TimeInterval = age < 60 ? 1 : (age < 3600 ? 10 : 60)
            SwiftUI.TimelineView(.periodic(from: .now, by: step)) { context in
                label(now: context.date)
            }
        } else {
            label(now: Date())
        }
    }

    /// A fixed box: the ticking text changes width ("9s" → "10s" → "1m"),
    /// and a label that resizes every second made the whole page lay out
    /// again every second — the quota grid, the hero row, all of it. A fixed
    /// box keeps each tick inside the label.
    private func label(now: Date) -> some View {
        Theme.mono(StoreReport.ageText(of: since, now: now), size: 11, color: Theme.textMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 52, alignment: .trailing)
    }
}

/// What the list of live rows is not showing. A cap that says nothing is
/// indistinguishable from "this is all of it".
struct HiddenSessionsNote: View {
    let hidden: Int
    let lang: Language

    var body: some View {
        Text(L10n.text(.moreSessions, lang).replacingOccurrences(of: "%d", with: "\(hidden)"))
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textMuted)
            .padding(.leading, 14)
    }
}

// MARK: - Token flow

/// Rounded clay bars, no axis chrome. The most recent bar is solid, history
/// is a wash of the same colour.
struct FlowChart: View {
    let flow: [(bucket: Date, billable: Int)]
    let hourly: Bool

    /// Bars grow from the baseline when the chart first draws, staggered left
    /// to right, and re-settle when the range changes.
    @State private var drawn = false
    @Environment(\.motionBudget) private var motion

    /// The store returns only buckets that had usage. Drawn as-is, a day
    /// with two busy hours was two fat bars and no sense of *when*; padded,
    /// "today" reads as a clock from midnight to now, and a week as seven
    /// days. Very long spans ("all") are left sparse rather than drawn as a
    /// thousand hairlines.
    private var series: [(bucket: Date, billable: Int)] {
        guard let first = flow.first?.bucket, let last = flow.last?.bucket else { return flow }
        let cal = Calendar.current
        let unit: Calendar.Component = hourly ? .hour : .day
        let start = hourly ? cal.startOfDay(for: first) : first
        let now = hourly ? (cal.dateInterval(of: .hour, for: Date())?.start ?? last) : cal.startOfDay(for: Date())
        let end = max(last, cal.isDate(now, inSameDayAs: last) || !hourly ? now : last)
        let span = (cal.dateComponents([unit], from: start, to: end).value(for: unit) ?? 0) + 1
        guard span > flow.count, span <= 120 else { return flow }
        let byBucket = Dictionary(flow.map { ($0.bucket, $0.billable) }, uniquingKeysWith: +)
        return (0..<span).compactMap { i in
            cal.date(byAdding: unit, value: i, to: start).map { ($0, byBucket[$0] ?? 0) }
        }
    }

    var body: some View {
        let flow = series
        let maxV = max(1, flow.map(\.billable).max() ?? 1)
        VStack(spacing: 10) {
            GeometryReader { geo in
                let n = max(flow.count, 1)
                let slot = geo.size.width / CGFloat(n)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(flow.enumerated()), id: \.offset) { i, b in
                        // An empty bucket keeps a stub on the baseline, so
                        // the axis is visible as time rather than as a gap.
                        let bar = max(2, geo.size.height * CGFloat(b.billable) / CGFloat(maxV))
                        UnevenRoundedRectangle(
                            topLeadingRadius: min(4, slot * 0.3), bottomLeadingRadius: 1.5,
                            bottomTrailingRadius: 1.5, topTrailingRadius: min(4, slot * 0.3),
                            style: .continuous)
                            .fill(i == n - 1 ? Theme.accent
                                  : (b.billable == 0 ? Theme.sunken : Theme.accent.opacity(0.32)))
                            .frame(width: max(2, slot * 0.62), height: drawn ? bar : 3)
                            .frame(width: slot, alignment: .center)
                            .animation(motion.allowsTravel
                                       ? Motion.settle.delay(Double(i) * 0.015)
                                       : motion.animation(Motion.settle), value: drawn)
                            .animation(motion.animation(Motion.settle), value: b.billable)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 64)

            HStack {
                Text(label(flow.first!.bucket))
                Spacer()
                Text(label(flow.last!.bucket))
            }
            .font(.system(size: 9.5, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(Theme.textFaint)
        }
        .onAppear { drawn = true }
    }

    private func label(_ d: Date) -> String {
        let f = DateFormatter()
        // POSIX keeps "HH:mm" at 24-hour on a Mac set to 12-hour time.
        f.locale = hourly ? Locale(identifier: "en_US_POSIX") : .current
        f.dateFormat = hourly ? "HH:mm" : "MMM d"
        return f.string(from: d)
    }
}

// MARK: - Cost ring

/// A donut in the series colours. Sweeps in once on appear, then re-settles
/// when the data refreshes.
struct CostRing: View {
    /// Ranked descending; at most `CostRing.slots` slices. The caller groups
    /// any tail into an "other" slice, which lands on the neutral stone.
    let slices: [(label: String, value: Double)]
    let centerTitle: String
    let centerCaption: String
    var lineWidth: CGFloat = 14

    static let slots = 5

    /// Rank → colour: named models take the series in order, the last seat
    /// ("other") is always the neutral.
    static func color(rank: Int, of count: Int, hasOther: Bool) -> Color {
        if hasOther && rank == count - 1 { return Theme.series[5] }
        return Theme.series[min(rank, 4)]
    }

    var hasOther = false

    @State private var progress: Double = 0
    @Environment(\.motionBudget) private var motion

    private var total: Double { slices.map(\.value).reduce(0, +) }

    private func start(of index: Int) -> Double {
        slices.prefix(index).map(\.value).reduce(0, +) / max(total, 0.01)
    }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.sunken, lineWidth: lineWidth)
            ForEach(Array(slices.enumerated()), id: \.offset) { i, s in
                RingSlice(start: start(of: i),
                          fraction: s.value / max(total, 0.01),
                          gap: slices.count > 1 ? 0.012 : 0,
                          progress: progress,
                          lineWidth: lineWidth)
                    .stroke(Self.color(rank: i, of: slices.count, hasOther: hasOther),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            VStack(spacing: 1) {
                Text(centerTitle)
                    .font(Theme.figure(19))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(centerCaption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, lineWidth + 4)
        }
        .onAppear { progress = 1 }
        .animation(motion.animation(Motion.reveal), value: progress)
        .animation(motion.animation(Motion.settle), value: total)
    }
}

/// One arc of the ring, measured in turns clockwise from twelve o'clock.
/// All three values ride `animatableData` so the sweep-in and any later
/// re-settle draw as one continuous stroke.
private struct RingSlice: Shape {
    var start: Double
    var fraction: Double
    var gap: Double
    var progress: Double
    var lineWidth: CGFloat

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { .init(start, .init(fraction, progress)) }
        set { start = newValue.first; fraction = newValue.second.first; progress = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let shown = fraction * progress
        let halfGap = min(gap / 2, shown / 2)
        let a0 = start * progress + halfGap
        let a1 = start * progress + shown - halfGap
        guard a1 > a0 else { return Path() }
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                 radius: (min(rect.width, rect.height) - lineWidth) / 2,
                 startAngle: .degrees(-90 + a0 * 360),
                 endAngle: .degrees(-90 + a1 * 360),
                 clockwise: false)
        return p
    }
}
