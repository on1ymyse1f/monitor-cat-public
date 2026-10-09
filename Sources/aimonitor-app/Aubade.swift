import AIMonitorCore
import AppKit
import Darwin
import SwiftUI

// MARK: - 晨曲 · Aubade
//
// The morning to Nocturne's night. Nocturne is dressed for 长夜月 — March 7th's
// mirrored self, the moon of a long night — so the day is dressed for the girl
// herself: pink hair over ice-blue, a camera on a strap, a six-petal ice
// flower pinned at her collar, and an album she fills with photographs. The
// skin borrows those *objects* rather than anyone's artwork: the mark is the
// flower, the hero is a photograph she took, the receipt is taped into the
// album, and she talks in chat bubbles. Her art comes only from a local
// character pack (see `CharacterPack`); with none installed the kitten plays
// her part, as at night.
//
// Everything here is static or one-shot. The page has no ambient layer by day:
// a sunny page is a still one.

/// Her flower: six rounded petals, the brooch at her collar and the mark of
/// the skin.
struct IceFlower: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let petal = Path(ellipseIn: CGRect(x: -r * 0.27, y: -r, width: r * 0.54, height: r * 0.84))
        for k in 0..<6 {
            let turn = CGAffineTransform(rotationAngle: CGFloat(k) * .pi / 3)
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            p.addPath(petal.applying(turn))
        }
        return p
    }
}

/// The mark: the flower in her pink, with an ice-blue heart.
struct IceFlowerMark: View {
    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                IceFlower().fill(Theme.accent)
                IceFlower().stroke(Theme.accentStrong.opacity(0.55), lineWidth: max(0.6, d * 0.04))
                Circle().fill(Theme.surface).frame(width: d * 0.34, height: d * 0.34)
                Circle().fill(Theme.frost).frame(width: d * 0.18, height: d * 0.18)
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// A four-pointed sparkle with concave sides — the twinkle drawn around her
/// in every sticker.
struct Sparkle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2, ry = rect.height / 2
        p.move(to: CGPoint(x: c.x, y: c.y - ry))
        p.addQuadCurve(to: CGPoint(x: c.x + rx, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + ry), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x - rx, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - ry), control: c)
        p.closeSubpath()
        return p
    }
}

/// The page by day: morning light washing down from the top over a pale
/// ground, with a few flecks of light, rasterized once into a tile.
struct DaySheet: View {
    var body: some View {
        ZStack {
            Theme.window
            LinearGradient(colors: [Theme.accentSoft.opacity(0.85), Theme.accentSoft.opacity(0)],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
            Stars.sparkleTile(side: 220, count: 9, seed: 0x9E3779B97F4A7C15)
                .resizable(resizingMode: .tile)
                .renderingMode(.template)
                .foregroundStyle(Theme.frost.opacity(0.28))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The hero's backdrop by day: sunlight behind the photograph, gold glints
/// like the "!" marks around her, a few flakes of her ice, and a strip of
/// film along the foot of the card. All static.
struct DayHeroBackdrop: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent.opacity(0.20), Theme.accent.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 130))
                    .frame(width: 260, height: 260)
                    .position(x: geo.size.width - 80, y: geo.size.height * 0.45)
                Stars.field(seed: 0x51ED27)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(Theme.series[3].opacity(0.55))
                Stars.frost(seed: 0x2545F4914F6CDD1D)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(Theme.frost.opacity(0.55))
                VStack {
                    Spacer(minLength: 0)
                    FilmStrip()
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A strip of film along the foot of a card: a band with its sprocket holes
/// punched through, cut with even-odd. Static.
struct FilmStrip: View {
    var body: some View {
        GeometryReader { geo in
            Self.film(geo.size).fill(Theme.textSecondary.opacity(0.09), style: FillStyle(eoFill: true))
        }
        .frame(height: 11)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func film(_ size: CGSize) -> Path {
        var film = Path(CGRect(origin: .zero, size: size))
        var x: CGFloat = 6
        while x + 6 < size.width {
            film.addRoundedRect(in: CGRect(x: x, y: size.height * 0.3, width: 6, height: size.height * 0.4),
                                cornerSize: CGSize(width: 1.5, height: 1.5))
            x += 13
        }
        return film
    }
}

/// A strip of washi tape: translucent pink with a pinked (zigzag) end on each
/// side and pale diagonal stripes.
struct WashiTape: View {
    var body: some View {
        let shape = TapeShape()
        shape
            .fill(Theme.accent.opacity(0.55))
            .overlay {
                GeometryReader { geo in
                    Path { p in
                        var x: CGFloat = -geo.size.height
                        while x < geo.size.width {
                            p.move(to: CGPoint(x: x, y: geo.size.height))
                            p.addLine(to: CGPoint(x: x + geo.size.height, y: 0))
                            x += 7
                        }
                    }
                    .stroke(Color.white.opacity(0.45), lineWidth: 2)
                }
                .clipShape(shape)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private struct TapeShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let teeth = 4
            let step = rect.height / CGFloat(teeth)
            let bite: CGFloat = min(3, rect.width * 0.08)
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            for i in 0..<teeth {
                p.addLine(to: CGPoint(x: rect.maxX - bite, y: rect.minY + step * (CGFloat(i) + 0.5)))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + step * CGFloat(i + 1)))
            }
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            for i in (0..<teeth).reversed() {
                p.addLine(to: CGPoint(x: rect.minX + bite, y: rect.minY + step * (CGFloat(i) + 0.5)))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + step * CGFloat(i)))
            }
            p.closeSubpath()
            return p
        }
    }
}

/// 写真 — by day the hero shows her in a square instant photograph, the kind
/// she takes of everything: a white card with a deeper margin at the foot for
/// the date, a morning sky behind her, taped onto the card at a slant.
///
/// Static apart from the portrait inside, which moves on the render server
/// (see `MascotCels`) exactly as the night's mirror portrait does.
struct InstantPhoto<Portrait: View>: View {
    var caption: String?
    @ViewBuilder let portrait: () -> Portrait

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.99, green: 0.89, blue: 0.94),
                                        Color(red: 0.87, green: 0.92, blue: 0.99)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { geo in
                    ForEach(Array(Self.glints.enumerated()), id: \.offset) { _, g in
                        Sparkle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: g.size, height: g.size)
                            .position(x: geo.size.width * g.x, y: geo.size.height * g.y)
                    }
                }
                portrait()
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .padding([.top, .horizontal], 7)
            Text(caption ?? " ")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accentStrong)
                .lineLimit(1)
                .frame(height: 24)
        }
        .background {
            ZStack {
                // A hard contact shadow, not a blurred layer.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.black.opacity(0.08))
                    .offset(x: 1, y: 2)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
        }
        .overlay(alignment: .top) {
            WashiTape()
                .frame(width: 48, height: 14)
                .rotationEffect(.degrees(-7))
                .offset(y: -7)
        }
        .rotationEffect(.degrees(-3))
    }

    private static var glints: [(x: CGFloat, y: CGFloat, size: CGFloat)] {
        [(0.14, 0.18, 9), (0.86, 0.14, 7), (0.9, 0.58, 6), (0.1, 0.66, 5)]
    }
}

/// By day she talks in chat messages: her face in a ring, her name, and a
/// bubble — with a beat of "typing" before each new line arrives. One-shot
/// per line; nothing ticks while it is shown.
struct ChatBubble: View {
    let name: String?
    let avatar: NSImage?
    let line: String
    @State private var typing = false
    @Environment(\.motionBudget) private var motion

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Group {
                if let avatar {
                    Image(nsImage: avatar).resizable().interpolation(.high)
                } else {
                    ZStack {
                        Circle().fill(Theme.accentSoft)
                        IceFlowerMark().padding(5)
                    }
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if let name {
                    Text(name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                }
                ZStack(alignment: .leading) {
                    // The line holds the width while the dots show, so the
                    // bubble does not change size when the words arrive.
                    Text(line).opacity(typing ? 0 : 1)
                    Text("• • •")
                        .foregroundStyle(Theme.accent)
                        .opacity(typing ? 1 : 0)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.surface, in: BubbleShape())
                .overlay(BubbleShape().stroke(Theme.accent.opacity(0.5), lineWidth: 1))
            }
            Spacer(minLength: 0)
        }
        .task(id: line) {
            guard motion.allowsAnimation else { typing = false; return }
            typing = true
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(Motion.turn) { typing = false }
        }
        .accessibilityElement(children: .combine)
    }

    /// A rounded bubble with a small tail at the top left, toward her face.
    private struct BubbleShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path(roundedRect: rect, cornerRadius: 10, style: .continuous)
            p.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 7))
            p.addLine(to: CGPoint(x: rect.minX - 5, y: rect.minY + 5))
            p.addLine(to: CGPoint(x: rect.minX + 1, y: rect.minY + 13))
            p.closeSubpath()
            return p
        }
    }
}

/// A section title's flourish by day: a small sparkle and a pink hairline
/// that fades out to the right.
struct DayFlourish: View {
    var body: some View {
        HStack(spacing: 4) {
            Sparkle()
                .fill(Theme.accent.opacity(0.85))
                .frame(width: 8, height: 8)
            LinearGradient(colors: [Theme.accent.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 48, height: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Her voice by day. The *state* behind each line is the kitten's (see
/// `MascotState.castLine`); only the wording changes — a cheerful girl with a
/// camera keeping a photo diary of your day, in original words.
enum AubadeVoice {
    static func text(_ line: MascotState.Line, _ lang: Language) -> String {
        switch line {
        case .idle: return L10n.text(.dayIdle, lang)
        case .quiet: return L10n.text(.dayQuiet, lang)
        case .critical: return L10n.text(.dayCritical, lang)
        case .napping: return L10n.text(.dayNapping, lang)
        case .working: return L10n.text(.dayWorking, lang)
        case .blind: return L10n.text(.dayBlind, lang)
        case .fresh: return L10n.text(.dayFresh, lang)
        }
    }

    static func greeting(hour: Int, _ lang: Language) -> String {
        switch hour {
        case 5..<12: return L10n.text(.dayMorning, lang)
        case 12..<18: return L10n.text(.dayAfternoon, lang)
        case 18..<23: return L10n.text(.dayEvening, lang)
        default: return L10n.text(.dayLate, lang)
        }
    }
}
