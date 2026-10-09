import AIMonitorCore
import AppKit
import SwiftUI

/// 三コマ撮り — the kitten, animated the way hand-drawn anime is animated.
///
/// Japanese TV animation is famously drawn *on threes*: one drawing held for
/// three frames of 24fps, i.e. **8 distinct images a second**. That constraint
/// is the aesthetic — the slight stutter is what reads as hand-drawn rather
/// than computer-tweened — and it is also the cheap way to do this.
///
/// The cels are played by Core Animation (`MascotCels`), not by SwiftUI. A
/// `TimelineView` at 8fps woke the app eight times a second to update the view
/// graph, render and commit — about a tenth of a core whenever the window was
/// watched. A discrete keyframe animation is handed to the render server once;
/// it steps the cels itself and the app sleeps.
///
/// The art is bundled as black-ink sketches and printed here as die-cut
/// stickers (`MascotArt`): cream body, warm ink, white edge, one soft shadow,
/// all baked into a single bitmap per pose. The 8fps clock therefore moves one
/// image, exactly as cheaply as the bare line drawing it replaced.
struct Mascot: View {
    typealias Mood = MascotState.Mood
    typealias Line = MascotState.Line
    typealias Situation = MascotState.Situation

    let mood: Mood
    var width: CGFloat
    var tilt: Double = -2
    /// Face the other way. The art is one drawing per mood, so mirroring is how
    /// the same kitten sits on the left of one panel and on the right of
    /// another without pretending to be a second cat.
    var mirrored: Bool = false
    /// The kitten's line, shown in a speech bubble above it.
    var says: String?
    /// How she is printed. A sticker everywhere she is a character; a bare,
    /// tinted line where she is only a mark (very small, or on a tinted chip).
    var style: Style = .sticker
    /// Size to the proposed width, up to `width`, instead of exactly `width` —
    /// for the hero, whose layout gives her less room in a narrow window.
    var flexible: Bool = false
    /// Mask her to a circle — the glass of the night hero's moon mirror. The
    /// mask stays still while she moves, so she moves *inside* the mirror.
    var mirror: Bool = false
    /// A painted character floats — interpolated, with a slow drift — rather
    /// than being held on threes like the line-drawn kitten.
    var floats: Bool = false
    /// Off for anything rendered to a still image. `ImageRenderer` captures one
    /// moment and cannot draw an AppKit layer at all, so a still cel is the
    /// only thing that belongs in a snapshot.
    var animated: Bool = true

    /// Whether anyone is looking (`Attention`), and whether motion is wanted
    /// at all: Reduce Motion, the app's Animations switch and Low Power Mode
    /// each hold her still. A still drawing is a perfectly good sticker.
    @Environment(\.isAttended) private var attended
    @Environment(\.motionBudget) private var motion

    private var shouldAnimate: Bool {
        animated && attended && motion.allowsTravel
    }

    /// 8fps — on threes, from a 24fps sensibility.
    private static let framesPerSecond: Double = 8

    enum Style: Equatable {
        case sticker
        case line(Color)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let says {
                SpeechBubble(text: says)
                    .transition(.scale(scale: 0.7, anchor: .bottomTrailing).combined(with: .opacity))
            }
            Group {
                if shouldAnimate, case .sticker = style {
                    let sticker = MascotArt.sticker(mood, pointWidth: width)
                    MascotCels(image: sticker, mood: mood, tilt: tilt, mirrored: mirrored,
                               framesPerSecond: Self.framesPerSecond, circular: mirror,
                               // A painted portrait floats; a line drawing is
                               // animated on threes.
                               smooth: mirror || floats)
                        .aspectRatio(sticker.size.width / max(1, sticker.size.height), contentMode: .fit)
                        .accessibilityLabel("cat girl")
                } else if mirror {
                    drawing(phase: 0).clipShape(Circle())
                } else {
                    drawing(phase: 0)
                }
            }
            .frame(width: flexible ? nil : width)
            .frame(maxWidth: flexible ? width : nil)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: says)
    }

    private func drawing(phase: Double) -> some View {
        let p = MascotState.pose(for: mood.motion, phase: phase)
        return art
            // Mirror before the breathing scale so the two compose rather than
            // cancelling, and mirror the tilt and sway with it — a flipped cat
            // leaning the same way looks like it is falling over.
            .scaleEffect(x: mirrored ? -1 : 1, y: CGFloat(p.breathe), anchor: .bottom)
            .offset(x: CGFloat(mirrored ? -p.sway : p.sway), y: CGFloat(p.bounce))
            .rotationEffect(.degrees((mirrored ? -tilt : tilt) + p.tremble), anchor: .bottom)
            .accessibilityLabel("cat girl")
    }

    @ViewBuilder
    private var art: some View {
        switch style {
        case .sticker:
            Image(nsImage: MascotArt.sticker(mood, pointWidth: width))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        case .line(let color):
            Image(nsImage: MascotArt.line(mood))
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(color)
        }
    }
}

// MARK: - Empty state

/// An empty screen is where a mascot earns its keep: the kitten curled up
/// asleep says "nothing here yet" faster, and more kindly, than a sentence
/// does. One shared component so every empty screen says it the same way.
struct MascotEmptyState: View {
    let text: String
    let lang: Language
    /// Which emptiness this is. Each empty screen gets its own pose so the cat
    /// is saying *which* nothing you are looking at, not repeating one shrug.
    var mood: MascotState.Mood = .sit
    var says: MascotState.Line = .quiet

    var body: some View {
        VStack(spacing: 12) {
            // Still: an empty screen is the last place worth spending a timer.
            Mascot(mood: mood, width: 190, tilt: -3, says: says.text(lang), animated: false)
            Text(text)
                .font(Theme.serif(15))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 54)
    }
}

/// `Mascot.cast` and the situation it reads live in `MascotState` (AIMonitorCore):
/// choosing the pose is policy about observed state, and belongs where it can
/// be tested rather than in a view.
extension Mascot {
    static func cast(for s: Situation, lang: Language) -> (mood: Mood, says: String?) {
        MascotState.cast(for: s, lang: lang)
    }
}

// MARK: - Cels

/// The kitten's on-threes animation, as a Core Animation keyframe track.
///
/// The poses are the same ones `MascotState.pose` gives the still drawing, one
/// per 1/8 s across the mood's cycle, played with `.discrete` timing so each
/// cel is *held* rather than tweened into the next — the stutter is the point.
/// The transform composes exactly as the SwiftUI modifiers do: scale (mirror,
/// breath) about the feet, then the offset (sway, bounce), then the rotation
/// (tilt, tremble) about the feet.
struct MascotCels: NSViewRepresentable {
    let image: NSImage
    let mood: MascotState.Mood
    let tilt: Double
    let mirrored: Bool
    let framesPerSecond: Double
    var circular = false
    /// Interpolated motion with a gentle float, for painted portraits; a
    /// sketch keeps its held cels. Trembling moods stay on threes either way —
    /// the stutter *is* the anime shake.
    var smooth = false

    func makeNSView(context: Context) -> CelView { CelView() }

    func updateNSView(_ view: CelView, context: Context) {
        view.circular = circular
        view.play(image: image, mood: mood, tilt: tilt, mirrored: mirrored, fps: framesPerSecond, smooth: smooth)
    }

    final class CelView: NSView {
        private let cel = CALayer()
        /// Holds the cel so a one-shot pop can scale her without touching the
        /// looping track on the cel itself.
        private let stage = CALayer()
        private var playing: String?
        /// A still circle over the moving cel (the mirror's glass).
        private let glass = CAShapeLayer()
        var circular = false {
            didSet { if circular != oldValue { needsLayout = true } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            clipsToBounds = false
            cel.contentsGravity = .resizeAspect
            // Feet: every pose pivots and breathes from the bottom centre.
            cel.anchorPoint = CGPoint(x: 0.5, y: 0)
            stage.anchorPoint = CGPoint(x: 0.5, y: 0)
            stage.addSublayer(cel)
            layer?.addSublayer(stage)
        }

        required init?(coder: NSCoder) { nil }

        /// Clicks belong to SwiftUI (petting her is a tap on the stage).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stage.bounds = CGRect(origin: .zero, size: bounds.size)
            stage.position = CGPoint(x: bounds.midX, y: bounds.minY)
            cel.bounds = CGRect(origin: .zero, size: bounds.size)
            cel.position = CGPoint(x: bounds.midX, y: 0)
            glass.path = CGPath(ellipseIn: bounds, transform: nil)
            layer?.mask = circular ? glass : nil
            CATransaction.commit()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            cel.contentsScale = window?.backingScaleFactor ?? 2
        }

        func play(image: NSImage, mood: MascotState.Mood, tilt: Double, mirrored: Bool, fps: Double, smooth: Bool) {
            let key = "\(mood.rawValue)|\(tilt)|\(mirrored)|\(smooth)|\(ObjectIdentifier(image).hashValue)"
            guard key != playing else { return }
            let firstCel = playing == nil
            playing = key

            // Held cels at 8fps, or — for a floating portrait — 24 poses a
            // second, interpolated, with a slow drift up and down in the glass.
            let held = !smooth || mood.motion == .trembling
            let rate = held ? fps : 24
            let cycle = held ? mood.cycle : max(mood.cycle, 4.2)
            let frames = max(2, Int((cycle * rate).rounded()))
            let track = (0..<frames).map { i -> NSValue in
                let phase = Double(i) / Double(frames)
                var pose = MascotState.pose(for: mood.motion, phase: phase)
                if !held { pose.bounce -= 2.4 * sin(phase * 2 * .pi) }
                return NSValue(caTransform3D: Self.transform(pose, tilt: tilt, mirrored: mirrored))
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cel.contents = image
            cel.removeAllAnimations()
            cel.transform = track[0].caTransform3DValue
            CATransaction.commit()

            let animation = CAKeyframeAnimation(keyPath: "transform")
            animation.values = held ? track : track + [track[0]]
            animation.calculationMode = held ? .discrete : .linear
            animation.duration = Double(frames) / rate
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            // Ask the render server for no more frames than the motion has:
            // eight for held cels, twenty-four for a drift.
            animation.preferredFrameRateRange = held
                ? CAFrameRateRange(minimum: 6, maximum: 12, __preferred: 8)
                : CAFrameRateRange(minimum: 15, maximum: 30, __preferred: 24)
            cel.add(animation, forKey: "cels")

            // A new expression arrives with a pop — the anime beat of a face
            // changing — but not the very first one, which the page's own
            // arrival already introduces.
            guard smooth, !firstCel else { return }
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0.9, 1.06, 0.98, 1.0]
            pop.keyTimes = [0, 0.45, 0.75, 1]
            pop.duration = 0.45
            pop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                                   CAMediaTimingFunction(name: .easeInEaseOut)]
            stage.add(pop, forKey: "pop")
        }

        /// Layer space is y-up and rotates counter-clockwise, SwiftUI is y-down
        /// and rotates clockwise — hence the two sign flips.
        private static func transform(_ p: MascotState.Pose, tilt: Double, mirrored: Bool) -> CATransform3D {
            let lean = (mirrored ? -tilt : tilt) + p.tremble
            var t = CATransform3DMakeRotation(-CGFloat(lean) * .pi / 180, 0, 0, 1)
            t = CATransform3DTranslate(t, CGFloat(mirrored ? -p.sway : p.sway), -CGFloat(p.bounce), 0)
            t = CATransform3DScale(t, mirrored ? -1 : 1, CGFloat(p.breathe), 1)
            return t
        }
    }
}
