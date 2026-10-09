import AIMonitorCore
import Combine
import SwiftUI

/// 猫娘観測所 — the kitten's observatory.
///
/// Three references, each with one job:
///
///   * **Claude's app** sets the room: warm ivory paper, warm near-black ink,
///     one terracotta ("clay") accent, a serif for anything that is a headline
///     and quiet sans-serif for everything that is a label. Cards are white on
///     ivory with a hairline and the faintest shadow, never a heavy frame.
///   * **Apple's product pages** set the motion: things arrive by rising a few
///     points and settling on a long expo-out curve, sections reveal as they
///     scroll into view, and the hero has a soft spotlight behind its subject.
///   * **The kitten** is the subject. She is printed as a die-cut sticker (see
///     `MascotArt`) and stands in that spotlight, and the small shapes on the
///     page — the paw mark, the ears on the selected tab — are hers.
///   * **The manga page** it grew out of sets the accents and the figures:
///     focus lines on the kitten, drawn lettering for the day's number, an
///     impact burst when quota runs out, screentone, paper grain and crop
///     marks (`MangaAccents`), and numbers in heavy SF Rounded and SF Mono.
///
/// **Lightweight is a design constraint, not a pass at the end.** Nothing here
/// loops. There is no material/blur (a backdrop sample per card per frame was
/// the most expensive thing an earlier version drew), no live texture, and
/// every decorative shape is static. Scroll-linked effects cost nothing while
/// the page is still, and the kitten is the only thing on a clock.
enum Theme {
    // Every colour forwards to the current skin's palette (`Skin`), read at
    // draw time — views never need to know which skin they are printed in.
    private static var p: Palette { Skin.current.palette }

    // MARK: - Surfaces

    /// The window ground.
    static var window: Color { p.window }
    /// Cards.
    static var surface: Color { p.surface }
    /// Tracks, chips, the segmented control's well.
    static var sunken: Color { p.sunken }
    /// Hairlines. Drawn as ink at low alpha so they sit on any surface.
    static var hairline: Color { p.hairline }
    static var hairlineStrong: Color { p.hairlineStrong }

    // MARK: - Ink

    static var text: Color { p.text }
    static var textSecondary: Color { p.textSecondary }
    static var textMuted: Color { p.textMuted }
    static var textFaint: Color { p.textFaint }

    // MARK: - Accent (the one hue that means "look here")

    /// Clay in the observatory, lilac at night. Used for the mark, live rates,
    /// the selected state and the latest bar of the flow — never decoration.
    static var accent: Color { p.accent }
    static var accentStrong: Color { p.accentStrong }
    /// A wash of the accent for tinted grounds.
    static var accentSoft: Color { p.accentSoft }
    /// Text and marks printed *on* the accent.
    static var onAccent: Color { p.onAccent }
    /// Something is live.
    static var live: Color { p.live }
    /// Quota nearly spent.
    static var danger: Color { p.danger }
    static var dangerSoft: Color { p.dangerSoft }
    /// Ice: frost crystals, and the burst when a quota breaks at night.
    static var frost: Color { p.frost }

    // MARK: - The settlement slip
    static var receiptPaper: Color { p.receiptPaper }
    static var receiptInk: Color { p.receiptInk }
    static var receiptStamp: Color { p.receiptStamp }

    /// Series colours for anything split by provider.
    static var series: [Color] { p.series }

    /// One colour per provider, stable across launches and pages. Known tools
    /// get fixed seats; anything new is placed by a deterministic hash of its
    /// name (never `hashValue`, which is reseeded every launch).
    static func color(forProvider name: String) -> Color {
        let series = self.series
        let lower = name.lowercased()
        if lower.hasPrefix("claude") { return series[0] }
        if lower.hasPrefix("codex") { return series[1] }
        if lower.hasPrefix("kimi") { return series[2] }
        if lower.hasPrefix("cursor") { return series[3] }
        var h: UInt32 = 5381
        for b in name.utf8 { h = (h &* 33) &+ UInt32(b) }
        return series[Int(h % 5)]
    }

    // MARK: - Metrics

    static let cardCorner: CGFloat = 20
    static let heroCorner: CGFloat = 26
    static let gutter: CGFloat = 14
    /// Claude centres its conversation in a column; so does this page when
    /// the window is wide, rather than stretching cards across a display.
    static let readingWidth: CGFloat = 760

    // MARK: - Type

    /// The headline voice: New York, the system serif — Claude's register.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Section title: a serif heading, sentence case, no rule under it.
    static func title(_ text: String, size: CGFloat = 19) -> some View {
        Text(text)
            .font(serif(size, weight: .medium))
            .foregroundStyle(Theme.text)
    }

    /// Apple's eyebrow: a small, tracked, accent-coloured line above a title.
    static func eyebrow(_ text: String, color: Color = Theme.accent) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(color)
    }

    // MARK: Figures
    //
    // Numbers keep the voice they had on the manga page: headline figures in
    // heavy SF Rounded, like drawn lettering, and figures in rows in SF Mono.
    // A serif numeral was tried here and read as softer than a monitor's
    // numbers should. Only the figures — titles and labels stay in the
    // observatory's serif and sans.

    /// 描き文字 — a headline figure: heavy, rounded, never wrapping.
    static func figure(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Figures that sit in rows and columns: SF Mono, lightly tracked.
    static func mono(_ text: String, size: CGFloat = 12, weight: Font.Weight = .regular,
                     color: Color = Theme.textSecondary) -> Text {
        Text(text)
            .font(.system(size: size, weight: weight, design: .monospaced))
            .tracking(0.2)
            .foregroundStyle(color)
    }
}

// MARK: - 動き / Motion

/// One motion vocabulary for the whole page.
///
/// Apple's pages move on long, decisive ease-outs: fast at the start, a slow
/// settle at the end, and no bounce on anything that carries information. The
/// kitten is the one exception — she is drawn on threes (see `Mascot`) — and
/// the UI never competes with her.
enum Motion {
    /// Apple's expo-out: an arrival. Sections, cards, the hero.
    static let reveal: Animation = .timingCurve(0.16, 1, 0.3, 1, duration: 0.8)
    /// Data settling into place — bars, rings, numbers after a refresh.
    static let settle: Animation = .timingCurve(0.22, 1, 0.36, 1, duration: 0.6)
    /// Direct manipulation — presses, the tab pill. A little spring in it.
    static let press: Animation = .spring(response: 0.32, dampingFraction: 0.72)
    /// One page replacing another.
    static let turn: Animation = .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.28)
    /// A tally rising off the number it belongs to, then gone.
    static let tally: Animation = .easeOut(duration: 0.6)
    /// A real batch of tokens moving through a live row.
    static let consume: Animation = .easeOut(duration: 0.72)

    /// A receipt printing. The paper leaves the slot at a printer's constant
    /// speed — points a second — and the ratchet (see `PaperFeed`) breaks it
    /// into line-sized steps. Deliberately slow: this is the one animation on
    /// the page that is watched rather than glanced at, and a click skips it.
    static let printSpeed: CGFloat = 250
    /// The paper's run: linear, because a motor does not ease. The steps
    /// supply the start and the stop.
    static func print(_ duration: TimeInterval) -> Animation { .linear(duration: duration) }
    /// The rest of a slip fed out at once, after a click.
    static let rushOut: Animation = .timingCurve(0.25, 0.1, 0.2, 1, duration: 0.45)
    /// The cutter firing: the slip drops free and hangs, with a small bounce.
    static let cutSpring = Spring(response: 0.3, dampingRatio: 0.45)
    static let cut: Animation = .spring(cutSpring)
    /// The settlement seal landing. The one bounce on the page, because a
    /// stamp *is* an impact — it overshoots into the paper and settles.
    static let stampSpring = Spring(response: 0.34, dampingRatio: 0.56)
    static let stamp: Animation = .spring(stampSpring)
    /// The seal follows the cutter after this long.
    static let stampDelay: TimeInterval = 0.14
    /// A slip torn off and pulled away: accelerates out, never eases.
    static let tear: Animation = .timingCurve(0.45, 0, 0.9, 0.4, duration: 0.3)

    /// How long the rising tally stays legible before it fades.
    static let tallyHold: TimeInterval = 1.9
    /// Gap between successive sections arriving on first load.
    static let stagger: Double = 0.06
}

/// Whether decorative motion should run at all.
///
/// Three switches with different meanings. **Reduce Motion** is an
/// accessibility request and is absolute. The app's own **Animations** switch
/// is the user saying the same thing about this app only. **Low Power Mode**
/// is a budget: travel goes (springs, parallax, reveals), but a plain
/// cross-fade stays, because a number changing in place is information.
struct MotionBudget {
    var reduceMotion: Bool
    var lowPower: Bool

    /// Movement across the page — travel, parallax, staggered entrances.
    var allowsTravel: Bool { !reduceMotion && !lowPower }
    /// Any animation at all, including a plain cross-fade.
    var allowsAnimation: Bool { !reduceMotion }

    func animation(_ base: Animation) -> Animation? { allowsAnimation ? base : nil }
}

private struct AppAnimationsKey: EnvironmentKey {
    static let defaultValue = true
}

private struct AttendedKey: EnvironmentKey {
    static let defaultValue = true
}

private struct LowPowerKey: EnvironmentKey {
    static var defaultValue: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}

extension EnvironmentValues {
    /// The Settings switch, injected once at the root.
    var appAnimations: Bool {
        get { self[AppAnimationsKey.self] }
        set { self[AppAnimationsKey.self] = newValue }
    }

    /// Whether anyone is plausibly looking at the window (see `Attention`).
    /// Anything on a clock asks this before ticking.
    var isAttended: Bool {
        get { self[AttendedKey.self] }
        set { self[AttendedKey.self] = newValue }
    }

    /// Low Power Mode, as a value the view tree is re-rendered for when it
    /// flips — reading `ProcessInfo` directly would never be re-read.
    var lowPowerMode: Bool {
        get { self[LowPowerKey.self] }
        set { self[LowPowerKey.self] = newValue }
    }

    /// The page's motion budget, assembled from the accessibility setting, the
    /// app's own switch and the power state, so call sites ask one question.
    var motionBudget: MotionBudget {
        MotionBudget(
            reduceMotion: accessibilityReduceMotion || !appAnimations,
            lowPower: lowPowerMode
        )
    }
}

// MARK: - Attention

/// Whether anyone is plausibly looking at the page, tracked once for the
/// whole window.
///
/// **A monitor must cost less than the thing it monitors.** Anything that
/// ticks — the kitten's 8fps cels, a live row's "12s ago" — is worth paying for
/// while it is watched and worth exactly zero otherwise. Occlusion alone is
/// not the test: the common case is the window left in view on a second
/// display while the user works in their editor, so this tracks *attention* —
/// the app frontmost and its window not hidden or covered.
///
/// One object for the page rather than a set of observers per view. The kitten
/// used to subscribe to six notifications per instance, and there are a dozen
/// of her on a page: every occlusion change of any window, the menu-bar item's
/// included, re-rendered all of them.
@MainActor
final class Attention: ObservableObject {
    @Published private(set) var attended: Bool
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var appActive: Bool
    private var visible = true
    private var bag: Set<AnyCancellable> = []

    init() {
        appActive = NSApp?.isActive ?? true
        attended = appActive || Self.forceAttended
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ handle: @escaping @MainActor (Notification) -> Void) {
            center.publisher(for: name)
                .sink { note in MainActor.assumeIsolated { handle(note) } }
                .store(in: &bag)
        }
        // The one that matters day to day: you switched to your editor.
        on(NSApplication.didBecomeActiveNotification) { [weak self] _ in self?.appActive = true; self?.update() }
        on(NSApplication.didResignActiveNotification) { [weak self] _ in self?.appActive = false; self?.update() }
        on(NSApplication.didHideNotification) { [weak self] _ in self?.visible = false; self?.update() }
        on(NSApplication.didUnhideNotification) { [weak self] _ in self?.visible = true; self?.update() }
        // Only a window that can be main is the page; the menu-bar item's
        // window reports occlusion too and says nothing about this one.
        on(NSWindow.didChangeOcclusionStateNotification) { [weak self] note in
            guard let window = note.object as? NSWindow, window.canBecomeMain else { return }
            self?.visible = window.occlusionState.contains(.visible)
            self?.update()
        }
        on(.NSProcessInfoPowerStateDidChange) { [weak self] _ in
            let now = ProcessInfo.processInfo.isLowPowerModeEnabled
            if self?.lowPower != now { self?.lowPower = now }
        }
    }

    private func update() {
        let now = (appActive && visible) || Self.forceAttended
        if attended != now { attended = now }
    }

    /// DEBUG profiling only (`--demo-window --attended`): measure the watched
    /// page without depending on whether macOS grants the demo focus.
    static var forceAttended = false
}

/// The house button feel: a small dip on press, a hair of lift on hover.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration)
    }

    private struct PressableBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.motionBudget) private var motion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.96 : (hovering && motion.allowsTravel ? 1.02 : 1))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .onHover { hovering = $0 }
                .animation(motion.animation(Motion.press), value: configuration.isPressed)
                .animation(motion.animation(Motion.turn), value: hovering)
        }
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Cards

/// A card: white on ivory, a hairline, and a shadow you notice only when it
/// is gone. `tone` tints the ground for the two states that need to be seen
/// from across the room.
struct Card: ViewModifier {
    enum Tone { case plain, accent, danger }
    var corner: CGFloat = Theme.cardCorner
    var tone: Tone = .plain

    private var ground: Color {
        switch tone {
        case .plain: return Theme.surface
        case .accent: return Theme.accentSoft
        case .danger: return Theme.dangerSoft
        }
    }

    private var edge: Color {
        switch tone {
        case .plain: return Theme.hairline
        case .accent: return Theme.accent.opacity(0.28)
        case .danger: return Theme.danger.opacity(0.35)
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return content
            .background {
                ZStack {
                    CardShadow(corner: corner)
                    shape.fill(ground)
                }
            }
            .overlay(shape.strokeBorder(edge, lineWidth: 1))
            // At night, moonlight catches the top edge of every card.
            .overlay {
                if Skin.current == .nocturne {
                    shape.strokeBorder(LinearGradient(colors: [Theme.text.opacity(0.16), .clear],
                                                      startPoint: .top, endPoint: .center),
                                       lineWidth: 1)
                }
            }
    }
}

/// Claude's input-box lift — a contact line and a wide, faint shadow — as a
/// nine-slice image drawn **once per corner radius** and stretched.
///
/// SwiftUI's `.shadow` blurs its shape into an offscreen texture per card and
/// keeps it. Measured on the dashboard's dozen cards: about 20 MB of memory and
/// over a second of CPU at launch, for a shadow at 4.5% opacity. The same
/// shadow as a stretched bitmap is a few kilobytes and costs nothing to draw.
private struct CardShadow: View {
    let corner: CGFloat

    var body: some View {
        let inset = ShadowArt.pad + corner + 2
        Image(nsImage: ShadowArt.image(corner: corner))
            .resizable(capInsets: EdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset),
                       resizingMode: .stretch)
            .padding(-ShadowArt.pad)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@MainActor
private enum ShadowArt {
    /// Room around the card for the blur to fall off in.
    static let pad: CGFloat = 30
    private static var cache: [CGFloat: NSImage] = [:]

    static func image(corner: CGFloat) -> NSImage {
        if let hit = cache[corner] { return hit }
        // Card body = two corners plus a 2pt stretchable middle.
        let body = 2 * (corner + 2) + 2
        let side = body + 2 * pad
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let card = CGPath(roundedRect: rect.insetBy(dx: pad, dy: pad),
                              cornerWidth: corner, cornerHeight: corner, transform: nil)
            // Wide, faint lift, then the contact line. CG shadow offsets are in
            // base space, so negative y is downward here.
            for (blur, y, alpha) in [(CGFloat(26), CGFloat(-6), 0.05), (2, -1, 0.05)] {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: y), blur: blur,
                              color: NSColor.black.withAlphaComponent(alpha).cgColor)
                ctx.addPath(card)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }
            // Keep only what falls outside the card; the card itself is drawn
            // on top in its own colour.
            ctx.setBlendMode(.clear)
            ctx.addPath(card)
            ctx.fillPath()
            return true
        }
        cache[corner] = image
        return image
    }
}

extension View {
    func card(corner: CGFloat = Theme.cardCorner, tone: Card.Tone = .plain) -> some View {
        modifier(Card(corner: corner, tone: tone))
    }
}

// MARK: - Scroll reveal

/// Apple's scroll-linked reveal: a section entering from the bottom of the
/// window rises, grows and fades in *with the scroll*, rather than on a timer.
///
/// `scrollTransition` is evaluated only while the scroll position changes, so
/// a still page pays nothing for it. Reduce Motion, the app switch and Low
/// Power Mode all turn it off (travel), leaving plain content.
struct ScrollReveal: ViewModifier {
    @Environment(\.motionBudget) private var motion

    func body(content: Content) -> some View {
        if motion.allowsTravel {
            content.scrollTransition(.interactive(timingCurve: .easeOut), axis: .vertical) { view, phase in
                let entering = max(0, phase.value)      // 0 on screen → 1 below
                let leaving = max(0, -phase.value)      // 0 on screen → 1 above
                return view
                    .opacity(1 - entering * 0.7 - leaving * 0.25)
                    .scaleEffect(1 - entering * 0.05 - leaving * 0.02, anchor: .top)
                    .offset(y: entering * 26)
            }
        } else {
            content
        }
    }
}

/// First-load arrival: sections rise into place one after another, the way a
/// product page lays its story out.
struct Arrival: ViewModifier {
    let shown: Bool
    let index: Int
    @Environment(\.motionBudget) private var motion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || !motion.allowsTravel ? 0 : 18)
            .animation(motion.animation(Motion.reveal.delay(Double(index) * Motion.stagger)), value: shown)
    }
}

extension View {
    func scrollReveal() -> some View { modifier(ScrollReveal()) }
    func arrival(_ shown: Bool, index: Int) -> some View { modifier(Arrival(shown: shown, index: index)) }
}

// MARK: - The kitten's marks

/// 肉球 — the app's mark. Where Claude has its spark, the observatory has a
/// paw: one main pad and four toe beans, drawn as a shape so it inks itself in
/// whatever colour it is given.
struct PawMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2, oy = rect.midY - s / 2
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }
        var p = Path()
        // Main pad: a soft, wide heart-ish oval.
        p.addRoundedRect(in: r(0.22, 0.46, 0.56, 0.44), cornerSize: CGSize(width: 0.24 * s, height: 0.22 * s),
                         style: .continuous)
        // Toe beans, fanned.
        p.addEllipse(in: r(0.02, 0.30, 0.19, 0.24))
        p.addEllipse(in: r(0.22, 0.06, 0.20, 0.26))
        p.addEllipse(in: r(0.58, 0.06, 0.20, 0.26))
        p.addEllipse(in: r(0.79, 0.30, 0.19, 0.24))
        return p
    }
}

/// A capsule with two small ears — the selected tab is the kitten's head
/// peeking up out of the segmented control.
struct EarCapsule: Shape {
    var ear: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: rect, cornerRadius: rect.height / 2, style: .continuous)
        let inset = min(rect.width * 0.22, rect.height * 0.9)
        for x in [rect.minX + inset, rect.maxX - inset] {
            // Each ear leans outward a touch, as cat ears do.
            let lean: CGFloat = x < rect.midX ? -1.2 : 1.2
            p.move(to: CGPoint(x: x - ear, y: rect.minY + 1.5))
            p.addQuadCurve(to: CGPoint(x: x + lean, y: rect.minY - ear),
                           control: CGPoint(x: x - ear * 0.6 + lean, y: rect.minY - ear * 0.35))
            p.addQuadCurve(to: CGPoint(x: x + ear, y: rect.minY + 1.5),
                           control: CGPoint(x: x + ear * 0.6 + lean, y: rect.minY - ear * 0.35))
            p.closeSubpath()
        }
        return p
    }
}

// MARK: - 吹き出し / Speech bubble

/// The kitten's voice, as a manga speech balloon: paper inside, an ink line
/// around it, bold lettering, and a pointed tail angled down toward the one
/// who said it — the way a comic hands a line to a character.
struct SpeechBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .padding(.bottom, 5)
            .background(
                BubbleShape()
                    .fill(Theme.surface)
                    .overlay(BubbleShape().stroke(Theme.text, lineWidth: 1.4))
            )
            .fixedSize()
    }

    private struct BubbleShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 5)
            p.addRoundedRect(in: body, cornerSize: CGSize(width: body.height / 2, height: body.height / 2))
            // Tail: a small triangle off the bottom-right, angled like a nib.
            let tx = rect.maxX - 20
            p.move(to: CGPoint(x: tx, y: body.maxY - 1))
            p.addLine(to: CGPoint(x: tx + 8, y: rect.maxY + 2))
            p.addLine(to: CGPoint(x: tx + 12, y: body.maxY - 1))
            p.closeSubpath()
            return p
        }
    }
}

/// A small rounded chip: an SF Symbol, a figure, a quiet label.
struct StatChip: View {
    let symbol: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            Theme.mono(value, size: 11.5, weight: .semibold, color: Theme.text)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textMuted)
        }
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.sunken, in: Capsule(style: .continuous))
    }
}

/// The hero's three supporting figures as spec callouts — value over caption,
/// the product-page grammar the hero already borrows.
///
/// These were a wrapping row of `StatChip`s. Three chips need about 261pt in
/// Chinese and 286pt in English, and beside the kitten the headline gets about
/// 200pt at the default 420pt window — so the row always broke two-and-one,
/// leaving "18 requests" alone on a second line, and it was one line shorter
/// on an empty day than on a busy one, so the hero jumped when data arrived.
/// A column is only as wide as the longer of its value and its caption, so
/// the row fits on one line almost everywhere at full size.
///
/// **Never clipped.** The tightest case — Nocturne's larger portrait, English,
/// the 360pt minimum window, a 12-hour, $100-plus day — leaves about 147pt
/// for roughly 188pt of figures. Per-text `minimumScaleFactor` could not
/// settle it: an `HStack` hands the squeeze unevenly, and the first column
/// came out as "12h 3…". So the row is offered at three sizes and the first
/// that fits wins; only the last may scale further.
///
/// `ViewThatFits` is fine *here*. The hero avoids it for the row that holds
/// the kitten, because every candidate kept an 8fps cat alive and each cel
/// re-measured the page (see `HeroRow`). These candidates are text only.
struct HeroStats: View {
    let items: [(value: String, label: String)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(value: 13, label: 10.5, gap: 8, fixed: true)
            row(value: 11.5, label: 9.5, gap: 6, fixed: true)
            row(value: 10.5, label: 9, gap: 5, fixed: false)
        }
    }

    private func row(value: CGFloat, label: CGFloat, gap: CGFloat, fixed: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(width: 1, height: value * 2)
                        .padding(.horizontal, gap)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Theme.mono(item.value, size: value, weight: .semibold, color: Theme.text)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(fixed ? 1 : 0.7)
                    Text(item.label)
                        .font(.system(size: label))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(fixed ? 1 : 0.7)
                }
                // Ideal width for the fitting candidates, so `ViewThatFits`
                // measures the real row instead of a pre-truncated one.
                .fixedSize(horizontal: fixed, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
