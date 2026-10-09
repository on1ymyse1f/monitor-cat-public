import AppKit
import SwiftUI

// 夜の空気 — the night's moving air, played entirely by Core Animation.
//
// Petals drifting down through the hero, stars twinkling around the mirror,
// light sweeping across its glass. Each is a looping animation handed to the
// render server once: the app process does not wake for a single frame of it,
// which is the only way a page can loop anything and stay lightweight (a
// SwiftUI `repeatForever` pins the app's own render loop — measured at an
// eighth of a core). Every animation also asks for a low frame rate, twelve
// frames a second, which is both the anime cadence and less compositing for
// the window server. When nobody is watching, the layers are stopped outright.

/// Petals and twinkling stars behind the hero's content.
struct NightAmbience: NSViewRepresentable {
    /// Watched and motion allowed. When false the layers stand still.
    var running: Bool

    func makeNSView(context: Context) -> AmbienceView { AmbienceView() }
    func updateNSView(_ view: AmbienceView, context: Context) { view.running = running }

    final class AmbienceView: NSView {
        private var petals: [CAShapeLayer] = []
        private var sparkles: [CAShapeLayer] = []
        private var laidOut = CGSize.zero

        var running = false {
            didSet { if running != oldValue { restart() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            clipsToBounds = true
            for i in 0..<4 {
                let petal = CAShapeLayer()
                petal.path = Self.petalPath(width: [9, 7, 8, 6][i])
                petal.fillColor = NSColor(srgbRed: 0.85, green: 0.34, blue: 0.42, alpha: [0.55, 0.45, 0.5, 0.4][i]).cgColor
                petal.opacity = 0
                layer?.addSublayer(petal)
                petals.append(petal)
            }
            for i in 0..<6 {
                let star = CAShapeLayer()
                let r = CGFloat([4.5, 3.5, 5.5, 3, 4, 3.5][i])
                star.path = Self.sparklePath(radius: r)
                star.bounds = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
                star.fillColor = (i.isMultiple(of: 3)
                    ? NSColor(srgbRed: 0.61, green: 0.76, blue: 0.94, alpha: 1)   // frost
                    : NSColor(srgbRed: 0.95, green: 0.78, blue: 0.37, alpha: 1)   // gold
                ).cgColor
                star.opacity = 0.35
                layer?.addSublayer(star)
                sparkles.append(star)
            }
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            guard bounds.size != laidOut, bounds.width > 0 else { return }
            laidOut = bounds.size
            // Around the mirror, which stands at the right of the hero.
            let spots: [CGPoint] = [
                CGPoint(x: 0.60, y: 0.78), CGPoint(x: 0.93, y: 0.84), CGPoint(x: 0.97, y: 0.40),
                CGPoint(x: 0.62, y: 0.22), CGPoint(x: 0.56, y: 0.52), CGPoint(x: 0.90, y: 0.14),
            ]
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (star, spot) in zip(sparkles, spots) {
                star.position = CGPoint(x: bounds.width * spot.x, y: bounds.height * spot.y)
            }
            CATransaction.commit()
            restart()
        }

        private func restart() {
            (petals + sparkles).forEach { $0.removeAllAnimations() }
            guard running, bounds.width > 0 else { return }
            let now = CACurrentMediaTime()
            let rate = CAFrameRateRange(minimum: 8, maximum: 15, __preferred: 12)

            for (i, petal) in petals.enumerated() {
                let w = bounds.width, h = bounds.height
                // Each falls on its own gentle S from above the card to below
                // it, turning as it goes; staggered so there is always about
                // one in the air, never a flurry.
                let startX = w * [0.18, 0.46, 0.72, 0.32][i]
                let drift = w * [0.22, -0.18, 0.16, -0.12][i]
                let path = CGMutablePath()
                path.move(to: CGPoint(x: startX, y: h + 14))
                path.addCurve(to: CGPoint(x: startX + drift, y: -14),
                              control1: CGPoint(x: startX + drift * 1.4, y: h * 0.62),
                              control2: CGPoint(x: startX - drift * 0.6, y: h * 0.3))
                let move = CAKeyframeAnimation(keyPath: "position")
                move.path = path
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = Double(i) * 0.9
                spin.toValue = Double(i) * 0.9 + (i.isMultiple(of: 2) ? 2.6 : -2.2)
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 1, 0]
                fade.keyTimes = [0, 0.12, 0.8, 1]
                let group = CAAnimationGroup()
                group.animations = [move, spin, fade]
                group.duration = [13, 16, 14.5, 17][i]
                group.repeatCount = .infinity
                group.beginTime = now + [0.5, 4.5, 8.5, 12][i]
                group.fillMode = .backwards
                group.preferredFrameRateRange = rate
                petal.add(group, forKey: "fall")
            }

            for (i, star) in sparkles.enumerated() {
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = [0.2, 1, 0.2]
                let size = CAKeyframeAnimation(keyPath: "transform.scale")
                size.values = [0.55, 1.1, 0.55]
                let group = CAAnimationGroup()
                group.animations = [pulse, size]
                group.duration = [2.6, 3.2, 2.2, 3.6, 2.9, 3.4][i]
                group.repeatCount = .infinity
                group.beginTime = now + Double(i) * 0.45
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                group.preferredFrameRateRange = rate
                star.add(group, forKey: "twinkle")
            }
        }

        private static func petalPath(width w: CGFloat) -> CGPath {
            let h = w * 1.35
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: -h / 2))
            p.addCurve(to: CGPoint(x: 0, y: h / 2), control1: CGPoint(x: -w * 0.7, y: -h * 0.2),
                       control2: CGPoint(x: -w * 0.4, y: h / 2))
            p.addCurve(to: CGPoint(x: 0, y: -h / 2), control1: CGPoint(x: w * 0.4, y: h / 2),
                       control2: CGPoint(x: w * 0.7, y: -h * 0.2))
            return p
        }

        /// A four-pointed sparkle with pinched sides, like the ones drawn
        /// around her in the sheet.
        static func sparklePath(radius r: CGFloat) -> CGPath {
            let p = CGMutablePath()
            let pinch = r * 0.18
            p.move(to: CGPoint(x: 0, y: r))
            p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: pinch, y: pinch))
            p.addQuadCurve(to: CGPoint(x: 0, y: -r), control: CGPoint(x: pinch, y: -pinch))
            p.addQuadCurve(to: CGPoint(x: -r, y: 0), control: CGPoint(x: -pinch, y: -pinch))
            p.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: -pinch, y: pinch))
            return p
        }
    }
}

/// A band of light sweeping across the mirror's glass every few seconds — the
/// glint anime draws on anything made of glass. Masked to the glass.
struct MirrorGlint: NSViewRepresentable {
    var running: Bool

    func makeNSView(context: Context) -> GlintView { GlintView() }
    func updateNSView(_ view: GlintView, context: Context) { view.running = running }

    final class GlintView: NSView {
        private let band = CAGradientLayer()
        private let glass = CAShapeLayer()
        private var laidOut = CGSize.zero

        var running = false {
            didSet { if running != oldValue { restart() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            band.colors = [NSColor.white.withAlphaComponent(0).cgColor,
                           NSColor.white.withAlphaComponent(0.34).cgColor,
                           NSColor.white.withAlphaComponent(0).cgColor]
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            band.opacity = 0
            layer?.addSublayer(band)
            layer?.mask = glass
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            guard bounds.size != laidOut, bounds.width > 0 else { return }
            laidOut = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glass.path = CGPath(ellipseIn: bounds, transform: nil)
            band.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.32, height: bounds.height * 1.6)
            band.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 7))
            band.position = CGPoint(x: -bounds.width * 0.4, y: bounds.midY)
            CATransaction.commit()
            restart()
        }

        private func restart() {
            band.removeAllAnimations()
            guard running, bounds.width > 0 else { return }
            // Sweep across in a little over a second, then rest: the glint is
            // an event, not a shimmer.
            let sweep = CAKeyframeAnimation(keyPath: "position.x")
            sweep.values = [-bounds.width * 0.4, bounds.width * 1.4, bounds.width * 1.4]
            sweep.keyTimes = [0, 0.17, 1]
            let show = CAKeyframeAnimation(keyPath: "opacity")
            show.values = [1, 1, 0, 0]
            show.keyTimes = [0, 0.17, 0.18, 1]
            let group = CAAnimationGroup()
            group.animations = [sweep, show]
            group.duration = 7.5
            group.repeatCount = .infinity
            group.beginTime = CACurrentMediaTime() + 1.5
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, __preferred: 24)
            band.add(group, forKey: "glint")
        }
    }
}

// MARK: - 二次元 details shared by both skins

/// Hearts rising from her when she is petted — once per pat, then gone.
struct HeartBurst: View {
    /// Changes once per pat; each change plays the burst.
    let trigger: Int

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: "heart.fill")
                    .font(.system(size: [11, 15, 9][i]))
                    .foregroundStyle(i == 1 ? Theme.danger : Theme.accent)
                    .keyframeAnimator(initialValue: HeartFrame(), trigger: trigger) { heart, f in
                        heart.opacity(f.opacity).offset(x: CGFloat([-20, 2, 22][i]), y: f.rise)
                            .scaleEffect(f.scale)
                    } keyframes: { _ in
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(1, duration: 0.12)
                            LinearKeyframe(1, duration: 0.5 + Double(i) * 0.08)
                            LinearKeyframe(0, duration: 0.45)
                        }
                        KeyframeTrack(\.rise) {
                            CubicKeyframe(-54 - CGFloat(i) * 8, duration: 1.1)
                        }
                        KeyframeTrack(\.scale) {
                            SpringKeyframe(1.15, duration: 0.25)
                            CubicKeyframe(0.9, duration: 0.8)
                        }
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    struct HeartFrame {
        var opacity: Double = 0
        var rise: CGFloat = 0
        var scale: CGFloat = 0.6
    }
}

/// A galgame dialogue window: a name plate and her line, typed out a
/// character at a time when the line changes, with the ▼ that says she has
/// finished speaking. The typing is a one-off per line, not a loop.
struct DialogueBox: View {
    let name: String?
    let line: String
    @State private var shown = 0
    @Environment(\.motionBudget) private var motion

    var body: some View {
        let characters = Array(line)
        let done = shown >= characters.count
        HStack(alignment: .center, spacing: 8) {
            if let name {
                Text(name)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent, in: Capsule(style: .continuous))
                    .fixedSize()
            }
            // The full line holds the width, so the box does not grow as the
            // characters arrive.
            ZStack(alignment: .leading) {
                Text("「" + line + "」").opacity(0)
                Text("「" + String(characters.prefix(shown)) + (done ? "」" : ""))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 7))
                .foregroundStyle(Theme.accent)
                .opacity(done ? 1 : 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.sunken.opacity(0.88), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
        .task(id: line) {
            guard motion.allowsAnimation else { shown = characters.count; return }
            shown = 0
            for i in 1...max(1, characters.count) {
                try? await Task.sleep(nanoseconds: 38_000_000)
                if Task.isCancelled { return }
                shown = i
            }
        }
    }
}
