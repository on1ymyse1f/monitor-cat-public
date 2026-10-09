import Foundation

/// The kitten's state machine, kept out of the view layer.
///
/// Which drawing to show and what it says is a **policy** decision made from
/// observable facts, not a presentation detail — so it lives here, next to the
/// numbers it reacts to and where it can be tested. The SwiftUI `Mascot` view
/// owns only the drawing and the timing.
public enum MascotState {

    /// Every drawing the kitten has. The raw value is the asset name.
    ///
    /// Three shipped first (`sit`, `angry`, `pounce`); the rest came from two
    /// sketch sheets in the same hand. Adding a pose is one case here plus one
    /// PNG — the motion comes from the archetype, not from new code.
    public enum Mood: String, CaseIterable, Sendable {
        // Resting
        case sit = "mascot-sit"
        case loaf = "mascot-loaf"
        case flop = "mascot-flop"
        case curl = "mascot-curl"
        case sleep = "mascot-sleep"
        case bed = "mascot-bed"
        case blanket = "mascot-blanket"
        // Attending to something
        case alert = "mascot-alert"
        case peek = "mascot-peek"
        case box = "mascot-box"
        case boxpaws = "mascot-boxpaws"
        case butterfly = "mascot-butterfly"
        // Working at something
        case stalk = "mascot-stalk"
        case pounce = "mascot-pounce"
        case mouse = "mascot-mouse"
        case play = "mascot-play"
        // Fussing over itself
        case groom = "mascot-groom"
        case wash = "mascot-wash"
        case eat = "mascot-eat"
        case fish = "mascot-fish"
        // Feeling something
        case angry = "mascot-angry"
        case puzzled = "mascot-puzzled"
        case happy = "mascot-happy"
        case mug = "mascot-mug"

        /// How a pose moves.
        ///
        /// Seven archetypes cover twenty-four drawings, and that ratio is the
        /// design: a bespoke animation per pose would be twenty-four chances
        /// for the page to grow a second tempo, and the whole motion vocabulary
        /// here rests on there being exactly one.
        public enum Motion: Sendable {
            /// Slow vertical swell — a cat at rest, breathing.
            case breathing
            /// Slower and deeper, settling at the bottom of the breath.
            case sleeping
            /// Fast small jitter — cross, or thinking too hard.
            case trembling
            /// Springy bounce — about to move, or moving.
            case springing
            /// Quick small head-dip — eating, washing, worrying at something.
            case nibbling
            /// Almost still, with an occasional ear-flick of a twitch.
            case perked
            /// Gentle sway — content, drifting.
            case floating
        }

        public var motion: Motion {
            switch self {
            case .sit, .loaf, .flop: return .breathing
            case .sleep, .curl, .bed, .blanket: return .sleeping
            case .angry, .puzzled: return .trembling
            case .pounce, .stalk, .mouse: return .springing
            case .eat, .wash, .groom, .play, .fish: return .nibbling
            case .alert, .peek, .box, .boxpaws: return .perked
            case .butterfly, .happy, .mug: return .floating
            }
        }

        /// Seconds per full cycle. Anger is quick and jittery; a sleeping cat
        /// breathes slowest of all.
        public var cycle: Double {
            switch motion {
            case .breathing: return 3.6
            case .sleeping: return 5.2
            case .trembling: return 0.5
            case .springing: return 1.4
            case .nibbling: return 0.9
            case .perked: return 4.4
            case .floating: return 4.0
            }
        }
    }

    // MARK: - The motion itself

    /// How far the drawing is displaced at one point in its cycle.
    public struct Pose: Sendable, Equatable {
        public var breathe: Double = 1
        public var bounce: Double = 0
        public var sway: Double = 0
        public var tremble: Double = 0
        public init() {}
    }

    /// One property per archetype carries the feeling; the rest stay at their
    /// neutral value, so two motions never fight over the same drawing.
    public static func pose(for motion: Mood.Motion, phase: Double) -> Pose {
        let wave = sin(phase * 2 * .pi)
        var p = Pose()
        p.tremble = wave * 1.1

        switch motion {
        case .breathing:
            p.breathe = 1 + wave * 0.028
        case .sleeping:
            // Settles at the bottom of the breath rather than bobbing — a
            // sleeping cat sinks into whatever it is lying on.
            p.breathe = 1 + wave * 0.042
            p.bounce = max(0, -wave) * 1.5
            p.tremble = wave * 0.4
        case .trembling:
            p.tremble = wave * 3.5
        case .springing:
            p.bounce = abs(wave) * -5
        case .nibbling:
            // Two dips per cycle: the head goes down twice as often as the body
            // moves, which is what reads as nibbling rather than nodding.
            p.bounce = abs(sin(phase * 4 * .pi)) * -2.2
            p.tremble = wave * 0.8
        case .perked:
            // Almost still. The twitch lives in the last fifth of the cycle, so
            // the cat holds a pose and then flicks instead of undulating.
            p.tremble = (phase > 0.8 ? sin((phase - 0.8) * 5 * .pi) : 0) * 2.6
            p.breathe = 1 + wave * 0.012
        case .floating:
            p.sway = wave * 2.4
            p.breathe = 1 + wave * 0.02
        }
        return p
    }

    // MARK: - What it says

    /// Every line is tied to a state the code can detect. None is filler: a
    /// mascot that comments at random stops being read within a day.
    public enum Line: Sendable {
        case idle, quiet, critical
        /// Nothing has written a log in a while.
        case napping
        /// A session is live right now.
        case working
        /// A quota exists but no reading is fresh enough to show.
        case blind
        /// The store is empty — first run, before any sync.
        case fresh

        public func text(_ lang: Language) -> String {
            let zh = lang.resolved == .zh
            switch self {
            case .idle: return zh ? "在看着呢" : "watching"
            case .quiet: return zh ? "今天好闲" : "quiet day"
            case .critical: return zh ? "快没啦！" : "almost out!"
            case .napping: return zh ? "打个盹…" : "napping…"
            case .working: return zh ? "在数着呢" : "counting…"
            case .blind: return zh ? "看不到啦" : "can't see it"
            case .fresh: return zh ? "还没数据" : "nothing yet"
            }
        }
    }

    // MARK: - Which cat, and why

    /// Everything the page knows that the kitten is allowed to react to.
    ///
    /// The cast is the point: twenty-four drawings are only worth having if
    /// each one *means* something, so every pose below is reachable from a
    /// state the app can actually observe. A pose with no state behind it is
    /// decoration on a rotation, and a reader stops looking at that.
    public struct Situation: Sendable {
        /// A session has written a log inside the live window.
        public var isLive: Bool
        /// The **tightest** quota window's remaining percent, when readable.
        public var quotaRemaining: Double?
        /// A quota exists but nothing fresh enough to show.
        public var quotaBlind: Bool
        /// Nothing in the store at all — first run.
        public var storeEmpty: Bool
        /// The day's tokens, for telling a quiet day from a busy one.
        public var todayTokens: Int
        /// A model turned up that the rate table does not cover.
        public var newlyUnpriced: Bool
        /// How long since the last event. Nil when nothing has ever arrived.
        public var idleFor: TimeInterval?

        public init(
            isLive: Bool = false,
            quotaRemaining: Double? = nil,
            quotaBlind: Bool = false,
            storeEmpty: Bool = false,
            todayTokens: Int = 0,
            newlyUnpriced: Bool = false,
            idleFor: TimeInterval? = nil
        ) {
            self.isLive = isLive
            self.quotaRemaining = quotaRemaining
            self.quotaBlind = quotaBlind
            self.storeEmpty = storeEmpty
            self.todayTokens = todayTokens
            self.newlyUnpriced = newlyUnpriced
            self.idleFor = idleFor
        }
    }

    /// Picks the pose and the line **together** — they are one decision, and
    /// splitting them is how a cat ends up asleep while saying "counting…".
    ///
    /// Ordered by urgency: the first true thing wins. A critical quota outranks
    /// everything, because that is the one state where the page needs the
    /// reader to look up from what they were doing.
    public static func cast(for s: Situation, lang: Language) -> (mood: Mood, says: String?) {
        let pick = castLine(for: s)
        return (pick.mood, pick.line?.text(lang))
    }

    /// The same decision as `cast`, with the line left as a `Line` so a skin
    /// can voice it in its own words — the *state* is policy and lives here;
    /// the wording is presentation.
    public static func castLine(for s: Situation) -> (mood: Mood, line: Line?) {
        if let remaining = s.quotaRemaining, remaining < 10 {
            return (.angry, .critical)
        }
        if s.storeEmpty {
            return (.box, .fresh)
        }
        if s.quotaBlind {
            return (.peek, .blind)
        }
        if s.newlyUnpriced {
            return (.puzzled, .blind)
        }
        if s.isLive {
            return s.todayTokens > 0 ? (.stalk, .working) : (.alert, .idle)
        }
        // Not live. How long it has been quiet decides how deeply asleep.
        if let idle = s.idleFor {
            if idle > 8 * 3600 { return (.bed, .napping) }
            if idle > 2 * 3600 { return (.sleep, .napping) }
            if idle > 15 * 60 { return (.curl, .napping) }
        }
        if s.todayTokens == 0 { return (.butterfly, .quiet) }
        // Recently active with plenty of headroom: pleased with itself.
        if let remaining = s.quotaRemaining, remaining > 60 { return (.happy, nil) }
        return (.wash, nil)
    }
}
