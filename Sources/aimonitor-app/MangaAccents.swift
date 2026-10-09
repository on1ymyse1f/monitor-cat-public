import AppKit
import SwiftUI

// 漫画の演出 — manga accents on the observatory.
//
// The room is Claude's; the *effects* are a comic book's. Each accent here is
// something a printed manga page does to direct the eye — focus lines to the
// character, drawn lettering for the one number, an impact burst when
// something goes wrong, screentone for shadow, paper grain and crop marks for
// the sheet itself — and each is used once, where it means something.
//
// All of it is as cheap as the manga page it comes from: every repeating
// texture is rasterized **once** into an image and reused, and the only
// motion is event-driven (the burst slams in when a quota turns critical).
// Nothing here is on a clock.

// MARK: - 集中線 / Focus lines

/// Concentration lines converging on the kitten: the manga way of saying
/// "this is who the page is about".
///
/// Tapered wedges — thin at the inner end, a hair wider at the edge — with
/// seeded, uneven start radii so the ring they leave around her reads as
/// inked by hand rather than drawn by a compass. Rays near the horizontal are
/// left out, so the hero number to her left never sits on a line.
///
/// Drawn once at a fixed size and stretched to the card. Stretching skews the
/// angles slightly, which only adds to the hand-inked look.
struct FocusLines: View {
    /// Where the lines converge, as a fraction of the view (the kitten).
    var focus: UnitPoint = UnitPoint(x: 0.8, y: 0.56)
    var opacity: Double = 0.075

    private static var cache: [String: NSImage] = [:]

    @MainActor
    private static func image(focus: UnitPoint) -> NSImage {
        let key = "\(focus.x),\(focus.y)"
        if let hit = cache[key] { return hit }
        let size = NSSize(width: 520, height: 300)
        let image = NSImage(size: size, flipped: true) { rect in
            let c = CGPoint(x: rect.width * focus.x, y: rect.height * focus.y)
            let reach = rect.width * 1.4
            var seed: UInt64 = 0x2545F4914F6CDD1D
            func next() -> Double {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                return Double(seed % 10_000) / 10_000
            }
            NSColor.black.setFill()
            let rays = 96
            for i in 0..<rays {
                let angle = (Double(i) + next() * 0.8) / Double(rays) * 2 * .pi
                // A clear corridor along the horizontal, toward the number.
                guard abs(sin(angle)) > 0.22 || cos(angle) > 0 else { continue }
                let inner = rect.height * (0.36 + next() * 0.22)
                let half = 0.004 + next() * 0.006          // wedge half-width, radians
                let dx = cos(angle), dy = sin(angle)
                let path = NSBezierPath()
                path.move(to: CGPoint(x: c.x + dx * inner, y: c.y + dy * inner))
                path.line(to: CGPoint(x: c.x + cos(angle - half) * reach, y: c.y + sin(angle - half) * reach))
                path.line(to: CGPoint(x: c.x + cos(angle + half) * reach, y: c.y + sin(angle + half) * reach))
                path.close()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    var body: some View {
        Image(nsImage: Self.image(focus: focus))
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(Theme.text.opacity(opacity))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - スクリーントーン / Screentone

/// The halftone dot fill every manga shadow uses. One dot in a tile, as a
/// template image, repeated by the image pipeline — never a live `Canvas`.
struct Screentone: View {
    var color: Color = Theme.text
    var opacity: Double = 0.3

    @MainActor
    private static let tile: NSImage = {
        let gap: CGFloat = 5, dot: CGFloat = 2.1
        let image = NSImage(size: NSSize(width: gap, height: gap), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: (gap - dot) / 2, y: (gap - dot) / 2, width: dot, height: dot)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.tile)
            .resizable(resizingMode: .tile)
            .renderingMode(.template)
            .foregroundStyle(color.opacity(opacity))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - 原稿用紙 / The sheet

/// The window's ground as a sheet of manuscript paper: Claude's ivory with a
/// faint, irregular tooth, and トンボ — the crop marks a printer trims to — in
/// the corners. Both in the page's own ink at very low opacity: felt, not read.
struct MangaSheet: View {
    var body: some View {
        ZStack {
            Theme.window
            PaperGrain()
            CropMarks()
                .stroke(Theme.text.opacity(0.18), lineWidth: 1.1)
                .padding(9)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Irregular paper tooth, as a tiled template image built once. Seeded, so the
/// grain is identical every launch.
struct PaperGrain: View {
    /// The grain is ink; the slip prints it in its own ink colour.
    var color: Color = Theme.text
    var opacity: Double = 0.13

    @MainActor
    private static let tile: NSImage = {
        let side: CGFloat = 64
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(seed % 1000) / 1000
        }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            for _ in 0..<170 {
                let x = next() * side, y = next() * side
                NSColor(white: 0, alpha: 0.10 + next() * 0.16).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1, height: 1)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.tile)
            .resizable(resizingMode: .tile)
            .renderingMode(.template)
            .foregroundStyle(color.opacity(opacity))
    }
}

/// Corner crop marks — an L at each corner of the sheet.
private struct CropMarks: Shape {
    var arm: CGFloat = 13

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (corner, sx, sy) in corners {
            p.move(to: CGPoint(x: corner.x, y: corner.y + sy * arm))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x + sx * arm, y: corner.y))
        }
        return p
    }
}

// MARK: - 集中線の破裂 / Impact burst

/// The jagged burst a comic puts behind anything that just went wrong. Radii
/// wobble by a fixed, seeded amount so the spikes are uneven — a regular star
/// reads as a rating widget, not as ink.
struct Starburst: Shape {
    var spikes: Int = 13
    var innerRatio: CGFloat = 0.58

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let steps = spikes * 2
        for i in 0..<steps {
            let angle = Double(i) / Double(steps) * 2 * .pi - .pi / 2
            let wobble = 0.86 + 0.14 * abs(sin(Double(i) * 2.399963))
            let radius = (i.isMultiple(of: 2) ? outer : outer * innerRatio) * wobble
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - 描き文字 / Drawn lettering

/// A number lettered the way a comic draws a sound effect: the heavy rounded
/// face with a keyline of the ground colour around it, so it stays the most
/// legible thing in the panel while focus lines pass behind it.
///
/// The keyline is four offset copies rather than a stroke — SwiftUI has no
/// text stroke, and at this weight four copies is indistinguishable from one.
/// Each copy carries the numeric roll, or the keyline rolls out of step with
/// the face it is behind.
struct DrawnLettering: View {
    let text: String
    var size: CGFloat
    var fill: Color = Theme.text
    var keyline: Color = Theme.surface
    var outline: CGFloat = 2.2

    private var face: some View {
        Text(text)
            .font(Theme.figure(size, weight: .black))
            .tracking(-0.5)
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .contentTransition(.numericText())
    }

    var body: some View {
        ZStack {
            ForEach(Array([(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)].enumerated()), id: \.offset) { _, o in
                face.foregroundStyle(keyline)
                    .offset(x: outline * o.0, y: outline * o.1)
            }
            face.foregroundStyle(fill)
        }
    }
}
