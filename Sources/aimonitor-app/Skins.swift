import AIMonitorCore
import AppKit
import Darwin
import SwiftUI

// MARK: - Skins

/// Which room the page is printed in.
///
///   * **Observatory** — Claude's ivory and clay, the catgirl sticker, manga
///     accents. Follows the system's light/dark setting.
///   * **Aubade** (晨曲) — the morning to Nocturne's night: a pale sunlit
///     ground, sakura pink over ice blue, an ice flower for a mark, the hero a
///     photograph (see `Aubade.swift`). Always light.
///   * **Nocturne** (夜想) — a gothic night: plum-black ground, lilac and rose,
///     gold sparkles, a crescent moon for a mark. Always dark.
///
/// Aubade and Nocturne are each played by a local character pack made for
/// them (see `CharacterPack`), and by the kitten when none is installed.
///
/// Colours are looked up through `Theme` at draw time, so a view never needs
/// to know which skin it is in; only the handful of *motifs* that differ in
/// shape (the mark, the selected-tab pill, the hero's backdrop, the sheet)
/// switch on it explicitly.
enum Skin: String, CaseIterable, Sendable {
    case observatory, aubade, nocturne

    /// Read by every `Theme` colour. Written only on the main actor, by
    /// `MonitorModel` (and the DEBUG review), before the tree re-renders.
    nonisolated(unsafe) static var current: Skin = .observatory

    var palette: Palette {
        switch self {
        case .observatory: return .observatory
        case .aubade: return .aubade
        case .nocturne: return .nocturne
        }
    }

    /// Nocturne is a night and Aubade a morning; neither is printed in the
    /// other's light.
    var forcedScheme: ColorScheme? {
        switch self {
        case .observatory: return nil
        case .aubade: return .light
        case .nocturne: return .dark
        }
    }

    /// Played by a character pack where one is installed for it.
    var hasCharacter: Bool { self != .observatory }
}

/// Every colour a skin defines. `Theme` forwards to the current skin's.
struct Palette {
    var window, surface, sunken, hairline, hairlineStrong: Color
    var text, textSecondary, textMuted, textFaint: Color
    var accent, accentStrong, accentSoft, onAccent: Color
    var live, danger, dangerSoft: Color
    /// Ice. Nocturne's second hue — her element — for frost crystals and the
    /// burst when quota breaks; slate blue in the observatory.
    var frost: Color
    var series: [Color]
    /// The settlement slip: its paper, the ink it is printed in, and the
    /// vermilion (or rose) of the hanko pressed on it when it is settled.
    var receiptPaper: Color
    var receiptInk: Color
    var receiptStamp: Color

    private static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let d = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(d ? dark : light, alpha: d ? darkAlpha : lightAlpha)
        })
    }

    private static func fixed(_ hex: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: rgb(hex, alpha: alpha))
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Claude's ivory and clay, and its dark counterpart.
    static let observatory = Palette(
        window: dynamic(0xFAF9F5, 0x262624),
        surface: dynamic(0xFFFFFF, 0x30302E),
        sunken: dynamic(0xF0EEE6, 0x1F1E1D),
        hairline: dynamic(0x1F1E1D, 0xFAF9F5, lightAlpha: 0.10, darkAlpha: 0.10),
        hairlineStrong: dynamic(0x1F1E1D, 0xFAF9F5, lightAlpha: 0.18, darkAlpha: 0.16),
        text: dynamic(0x141413, 0xFAF9F5),
        textSecondary: dynamic(0x3D3D3A, 0xC2C0B6),
        textMuted: dynamic(0x73726C, 0x9C9A92),
        textFaint: dynamic(0xA3A199, 0x6B6A65),
        accent: dynamic(0xD97757, 0xE08A6D),
        accentStrong: dynamic(0xC6613F, 0xEE9F84),
        accentSoft: dynamic(0xF5E3D9, 0x44302A),
        onAccent: fixed(0xFFFFFF),
        live: dynamic(0x6F9A5B, 0x8DB577),
        danger: dynamic(0xBF4D43, 0xE06C62),
        dangerSoft: dynamic(0xF7E1DD, 0x472A27),
        frost: dynamic(0x6A8CAF, 0x86A6C8),
        series: [
            dynamic(0xD97757, 0xE08A6D),   // clay
            dynamic(0x6A8CAF, 0x86A6C8),   // slate blue
            dynamic(0x8A9A5B, 0xA3B374),   // olive
            dynamic(0xD4A27F, 0xDDB08F),   // kraft
            dynamic(0xA77B9A, 0xC095B3),   // plum
            dynamic(0x9C9A92, 0x7E7C75),   // stone — "other"
        ],
        // Thermal paper, warm. In dark mode the slip is a dim sheet under a
        // desk lamp rather than a white rectangle burning a hole in the page.
        receiptPaper: dynamic(0xFFFDF7, 0x34322E),
        receiptInk: dynamic(0x2B2520, 0xF1EBDF),
        receiptStamp: dynamic(0xC6463A, 0xE8705F))   // 朱肉 — seal vermilion

    /// Sampled from her sticker sheet: the pinks of her hair, the navy of her
    /// skirt and line art, the ice blue of her jacket and her element, the
    /// lavender at her hair's tips, the gold of her "!" marks. Pink is
    /// deepened where it marks things, so a mark is not a smudge on white.
    static let aubade = Palette(
        window: fixed(0xFBF8FC),
        surface: fixed(0xFFFFFF),
        sunken: fixed(0xF3EEF6),
        hairline: fixed(0x343240, alpha: 0.10),
        hairlineStrong: fixed(0x343240, alpha: 0.18),
        text: fixed(0x2B2A3A),
        textSecondary: fixed(0x4D5076),     // her skirt
        textMuted: fixed(0x7D7A93),
        textFaint: fixed(0xABA7BE),
        accent: fixed(0xE07AA8),            // hair, deepened
        accentStrong: fixed(0xC9558C),
        accentSoft: fixed(0xFBE6F0),
        onAccent: fixed(0xFFFFFF),
        live: fixed(0x4D8FE0),              // ice blue, deepened
        danger: fixed(0xE04B5F),
        dangerSoft: fixed(0xFDE4E8),
        frost: fixed(0x77A4E3),             // her ice
        series: [
            fixed(0xE07AA8),   // sakura
            fixed(0x77A4E3),   // ice
            fixed(0x5574B1),   // navy
            fixed(0xE8B84A),   // gold
            fixed(0x9C8FD6),   // lavender
            fixed(0xA6A1B5),   // stone — "other"
        ],
        // A slip taped into her album: white paper, navy ink, a pink seal.
        receiptPaper: fixed(0xFFFEFF),
        receiptInk: fixed(0x2E3350),
        receiptStamp: fixed(0xE0659A))

    /// Sampled from the character sheet it was made for — the plum-black of
    /// the cells' ground, lilac hair, crimson roses, the gold of her "!"
    /// marks, the lavender of her "?" and "Zzz" — plus the deep frost blue of
    /// her element (she fights in Ice), which the sheet itself never shows.
    static let nocturne = Palette(
        window: fixed(0x17161C),
        surface: fixed(0x25232C),
        sunken: fixed(0x1C1B22),
        hairline: fixed(0xE4CCE4, alpha: 0.12),
        hairlineStrong: fixed(0xE4CCE4, alpha: 0.24),
        text: fixed(0xF5EEF6),
        textSecondary: fixed(0xD8CAE0),
        textMuted: fixed(0xA294AC),
        textFaint: fixed(0x6F6479),
        accent: fixed(0xE6A6DE),        // hair
        accentStrong: fixed(0xF3C3EC),
        accentSoft: fixed(0x3A2A3D),
        onAccent: fixed(0x241A26),
        live: fixed(0xF2C75E),          // her "!" marks
        danger: fixed(0xE0566E),        // rose
        dangerSoft: fixed(0x3D2129),
        frost: fixed(0x9CC2F0),
        series: [
            fixed(0xE6A6DE),   // lilac
            fixed(0x8FB6EA),   // frost
            fixed(0xD9566C),   // rose
            fixed(0xE9C35F),   // gold
            fixed(0xA99BF0),   // lavender
            fixed(0x7C7486),   // stone — "other"
        ],
        // A night slip: plum paper a shade above the cards, lilac-white ink,
        // and her rose for the seal.
        receiptPaper: fixed(0x2C2734),
        receiptInk: fixed(0xF2E7F4),
        receiptStamp: fixed(0xE0566E))
}

// MARK: - Character packs

/// A character made from an expression sheet by
/// `scripts/make-character-skin.py`, living in
/// `~/Library/Application Support/AIMonitor/Skins/<name>/`.
///
/// **Packs are local by design.** A sheet of a character someone else owns is
/// fine on your own Mac and not ours to ship in a public repository, so the
/// app bundles none and reads only from the per-user folder.
///
/// A pack maps mascot moods to cells. A mood it does not map falls back to the
/// kitten, so a partial sheet still works.
@MainActor
final class CharacterPack {
    /// How the cells were made: feathered portraits that dissolve into a dark
    /// card (night), or die-cut stickers lifted off their ground (day).
    enum Style { case portrait, sticker }

    let name: String
    let title: String
    /// The theme the pack plays in (`skin` in skin.json; packs made before
    /// there were two are Nocturne's).
    let skin: Skin
    let style: Style
    private let directory: URL
    private let moods: [String: Int]
    private var cache: [String: NSImage] = [:]

    private init?(directory: URL) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("skin.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.directory = directory
        name = json["name"] as? String ?? directory.lastPathComponent
        title = json["title"] as? String ?? name
        moods = (json["moods"] as? [String: Int]) ?? [:]
        skin = Skin(rawValue: json["skin"] as? String ?? "") ?? .nocturne
        style = (json["style"] as? String) == "sticker" ? .sticker : .portrait
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIMonitor/Skins", isDirectory: true)
    }

    /// Every installed pack (manifests only — no art is read until drawn),
    /// alphabetically; read once per launch.
    private static let installed: [CharacterPack] = {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return dirs.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap(CharacterPack.init(directory:))
    }()

    /// The character a theme is played by: the first pack installed for it.
    static func pack(for skin: Skin) -> CharacterPack? {
        skin.hasCharacter ? installed.first { $0.skin == skin } : nil
    }

    /// The character on the page now, if the current theme has one.
    static var current: CharacterPack? { pack(for: Skin.current) }

    /// Drop every pack's loaded art (the window closed).
    static func purgeAll() { installed.forEach { $0.purge() } }

    /// Drop the loaded portraits and avatars.
    func purge() { cache.removeAll() }

    /// The art for a mascot: a portrait (or the ringed face, when small) at
    /// night; a sticker (a smaller bake, when small) by day.
    func image(for mood: MascotState.Mood, small: Bool) -> NSImage? {
        guard let cell = moods[mood.rawValue] else { return nil }
        let n = String(format: "%02d", cell)
        switch style {
        case .portrait: return load(small ? "avatar-\(n)" : "portrait-\(n)", ringed: small)
        case .sticker: return load(small ? "sticker-small-\(n)" : "sticker-\(n)", ringed: false)
        }
    }

    /// Her face in a ring — a name plate's or a chat message's avatar.
    func avatar(for mood: MascotState.Mood) -> NSImage? {
        guard let cell = moods[mood.rawValue] else { return nil }
        return load("avatar-\(String(format: "%02d", cell))", ringed: true)
    }

    private func load(_ key: String, ringed: Bool) -> NSImage? {
        let cacheKey = ringed ? key + "-ringed" : key
        if let hit = cache[cacheKey] { return hit }
        guard let art = NSImage(contentsOf: directory.appendingPathComponent(key + ".png")) else { return nil }
        let made = ringed ? Self.ringed(art, style == .sticker ? Self.pinkRing : Self.lilacRing) : art
        cache[cacheKey] = made
        return made
    }

    private static let lilacRing = NSColor(srgbRed: 0.90, green: 0.72, blue: 0.89, alpha: 0.85)
    private static let pinkRing = NSColor(srgbRed: 0.88, green: 0.48, blue: 0.66, alpha: 0.85)

    /// A thin ring around the avatar, baked in once, so a face reads as a
    /// coin on the card rather than a hole cut in it.
    private static func ringed(_ avatar: NSImage, _ color: NSColor) -> NSImage {
        let size = avatar.size
        return NSImage(size: size, flipped: false) { rect in
            avatar.draw(in: rect)
            let inset = max(1, size.width * 0.012)
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            ring.lineWidth = max(1.5, size.width * 0.022)
            color.setStroke()
            ring.stroke()
            return true
        }
    }
}

// MARK: - Motifs

/// The app's mark: the kitten's paw, her ice flower by day, or the long
/// night's crescent moon.
struct BrandMark: View {
    var body: some View {
        switch Skin.current {
        case .observatory: PawMark().fill(Theme.accent)
        case .aubade: IceFlowerMark()
        case .nocturne:
            // A glyph, not a shape: a crescent built by subtracting one path
            // from another re-ran that boolean operation on every render.
            Image(systemName: "moon.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Theme.accent)
        }
    }
}

/// The selected tab's pill: with cat ears in the observatory, her flower
/// pinned to it by day (it turns a sixth of a turn each time the tab
/// changes), and with her ahoge — the single looped strand on top of her
/// head — at night.
struct SkinPill: View {
    /// Changes when the selected tab does; the ahoge boings once each time.
    var trigger: Int = 0

    var body: some View {
        switch Skin.current {
        case .observatory:
            EarCapsule(ear: 5)
                .fill(Theme.surface)
                .overlay(EarCapsule(ear: 5).stroke(Theme.hairlineStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        case .aubade:
            Capsule(style: .continuous)
                .fill(Theme.surface)
                .overlay(Capsule(style: .continuous).stroke(Theme.accent.opacity(0.45), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    IceFlowerMark()
                        .frame(width: 11, height: 11)
                        .keyframeAnimator(initialValue: 0.0, trigger: trigger) { flower, angle in
                            flower.rotationEffect(.degrees(angle))
                        } keyframes: { _ in
                            SpringKeyframe(72, duration: 0.3)
                            SpringKeyframe(60, duration: 0.35)
                        }
                        .offset(x: 2, y: -4)
                }
        case .nocturne:
            Capsule(style: .continuous)
                .fill(Theme.surface)
                .overlay(Capsule(style: .continuous).stroke(Theme.hairlineStrong, lineWidth: 1))
                .overlay(alignment: .top) {
                    Ahoge()
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 12, height: 11)
                        .keyframeAnimator(initialValue: 0.0, trigger: trigger) { strand, angle in
                            strand.rotationEffect(.degrees(angle), anchor: .bottom)
                        } keyframes: { _ in
                            SpringKeyframe(-22, duration: 0.12)
                            SpringKeyframe(14, duration: 0.16)
                            SpringKeyframe(-6, duration: 0.16)
                            SpringKeyframe(0, duration: 0.3)
                        }
                        .offset(x: 3, y: -9)
                }
        }
    }
}

/// One looped strand: up from the crown, round, and back down across itself.
struct Ahoge: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: rect.minX + w * 0.30, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.50, y: rect.minY),
                   control1: CGPoint(x: rect.minX + w * 0.10, y: rect.minY + h * 0.55),
                   control2: CGPoint(x: rect.minX + w * 0.10, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.55, y: rect.maxY - h * 0.05),
                   control1: CGPoint(x: rect.minX + w * 1.05, y: rect.minY),
                   control2: CGPoint(x: rect.minX + w * 1.00, y: rect.minY + h * 0.70))
        return p
    }
}

/// The window's ground for the current skin: the manga sheet, morning light,
/// or a night sky.
struct SkinSheet: View {
    var body: some View {
        switch Skin.current {
        case .observatory: MangaSheet()
        case .aubade: DaySheet()
        case .nocturne: NightSheet()
        }
    }
}

/// A plum-black sky with the faintest stars, rasterized once into a tile.
struct NightSheet: View {
    var body: some View {
        ZStack {
            Theme.window
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.19).opacity(0.9), .clear],
                           startPoint: .top, endPoint: .center)
            Stars.tile(side: 180, count: 26, seed: 0x5DEECE66D)
                .resizable(resizingMode: .tile)
                .renderingMode(.template)
                .foregroundStyle(Theme.textSecondary.opacity(0.35))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The hero's backdrop at night: moonlight behind her, sparkles in the gold of
/// her "!" marks, and a few fallen rose petals. All static.
struct NightHeroBackdrop: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Moonlight where she stands: the pack's portraits dissolve
                // into this rather than into flat card.
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 130))
                    .frame(width: 260, height: 260)
                    .position(x: geo.size.width - 80, y: geo.size.height * 0.5)
                Stars.field(seed: 0x2545F491)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(Theme.live.opacity(0.55))
                // Her element: a few six-armed frost crystals among the stars.
                Stars.frost(seed: 0x9E3779B9)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(Theme.frost.opacity(0.6))
                // Mist pooling at the foot of the card — the fog candlelight
                // fades into in the halls of memory.
                LinearGradient(colors: [Theme.accent.opacity(0.10), .clear],
                               startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.55))
                ForEach(Array(Self.petals.enumerated()), id: \.offset) { _, p in
                    Petal()
                        .fill(Theme.danger.opacity(p.opacity))
                        .frame(width: p.size, height: p.size * 1.35)
                        .rotationEffect(.degrees(p.angle))
                        .position(x: geo.size.width * p.x, y: geo.size.height * p.y)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let petals: [(x: CGFloat, y: CGFloat, size: CGFloat, angle: Double, opacity: Double)] = [
        (0.06, 0.88, 9, -30, 0.55), (0.13, 0.95, 6, 40, 0.4), (0.52, 0.93, 7, 110, 0.35),
        (0.93, 0.12, 8, 20, 0.45), (0.86, 0.9, 6, -70, 0.35),
    ]
}

/// A single rose petal: a rounded teardrop.
struct Petal: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                   control1: CGPoint(x: rect.minX - rect.width * 0.2, y: rect.maxY - rect.height * 0.3),
                   control2: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                   control1: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.minY),
                   control2: CGPoint(x: rect.maxX + rect.width * 0.2, y: rect.maxY - rect.height * 0.3))
        return p
    }
}

/// Star images, drawn once and cached: dots of a few sizes and, in the field,
/// a handful of four-pointed sparkles like the ones around her in the sheet.
@MainActor
enum Stars {
    private static var cache: [String: NSImage] = [:]

    static func purge() { cache.removeAll() }

    private static func random(_ seed: inout UInt64) -> CGFloat {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return CGFloat(seed % 10_000) / 10_000
    }

    static func tile(side: CGFloat, count: Int, seed start: UInt64) -> Image {
        let key = "tile-\(side)-\(count)-\(start)"
        if let hit = cache[key] { return Image(nsImage: hit) }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            var seed = start
            NSColor.black.setFill()
            for _ in 0..<count {
                let r = 0.4 + random(&seed) * 0.9
                NSColor(white: 0, alpha: 0.4 + random(&seed) * 0.6).setFill()
                NSBezierPath(ovalIn: NSRect(x: random(&seed) * side, y: random(&seed) * side,
                                            width: r * 2, height: r * 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return Image(nsImage: image)
    }

    /// A tile of small four-pointed sparkles, for the day's ground.
    static func sparkleTile(side: CGFloat, count: Int, seed start: UInt64) -> Image {
        let key = "sparkles-\(side)-\(count)-\(start)"
        if let hit = cache[key] { return Image(nsImage: hit) }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            var seed = start
            for _ in 0..<count {
                let c = CGPoint(x: random(&seed) * side, y: random(&seed) * side)
                let r = 2 + random(&seed) * 3.5
                let p = NSBezierPath()
                p.move(to: CGPoint(x: c.x, y: c.y + r))
                p.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint1: c, controlPoint2: c)
                p.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint1: c, controlPoint2: c)
                p.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint1: c, controlPoint2: c)
                p.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint1: c, controlPoint2: c)
                NSColor(white: 0, alpha: 0.5 + random(&seed) * 0.5).setFill()
                p.fill()
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return Image(nsImage: image)
    }

    /// Six-armed frost crystals, drawn as strokes with a short branch on each
    /// arm; scattered toward the right, around her.
    static func frost(seed start: UInt64) -> Image {
        let key = "frost-\(start)"
        if let hit = cache[key] { return Image(nsImage: hit) }
        let size = NSSize(width: 520, height: 300)
        let image = NSImage(size: size, flipped: false) { rect in
            var seed = start
            NSColor.black.setStroke()
            for _ in 0..<6 {
                let c = CGPoint(x: rect.width * (0.40 + random(&seed) * 0.56),
                                y: rect.height * (0.10 + random(&seed) * 0.80))
                let r = 4 + random(&seed) * 5
                let turn = random(&seed) * .pi / 3
                let p = NSBezierPath()
                p.lineWidth = 1.1
                p.lineCapStyle = .round
                for k in 0..<6 {
                    let a = turn + CGFloat(k) * .pi / 3
                    let tip = CGPoint(x: c.x + Darwin.cos(a) * r, y: c.y + Darwin.sin(a) * r)
                    p.move(to: c); p.line(to: tip)
                    let mid = CGPoint(x: c.x + Darwin.cos(a) * r * 0.55, y: c.y + Darwin.sin(a) * r * 0.55)
                    for side in [-1.0, 1.0] {
                        let b = a + CGFloat(side) * .pi / 4
                        p.move(to: mid)
                        p.line(to: CGPoint(x: mid.x + Darwin.cos(b) * r * 0.3, y: mid.y + Darwin.sin(b) * r * 0.3))
                    }
                }
                p.stroke()
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return Image(nsImage: image)
    }

    static func field(seed start: UInt64) -> Image {
        let key = "field-\(start)"
        if let hit = cache[key] { return Image(nsImage: hit) }
        let size = NSSize(width: 520, height: 300)
        let image = NSImage(size: size, flipped: false) { rect in
            var seed = start
            for _ in 0..<34 {
                let r = 0.6 + random(&seed) * 1.2
                NSColor(white: 0, alpha: 0.25 + random(&seed) * 0.5).setFill()
                NSBezierPath(ovalIn: NSRect(x: random(&seed) * rect.width, y: random(&seed) * rect.height,
                                            width: r * 2, height: r * 2)).fill()
            }
            // Sparkles gather toward the right, where she stands.
            for _ in 0..<7 {
                let c = CGPoint(x: rect.width * (0.45 + random(&seed) * 0.52),
                                y: rect.height * (0.08 + random(&seed) * 0.84))
                let r = 4 + random(&seed) * 5
                let p = NSBezierPath()
                p.move(to: CGPoint(x: c.x, y: c.y + r))
                p.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint1: CGPoint(x: c.x, y: c.y),
                        controlPoint2: CGPoint(x: c.x, y: c.y))
                p.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint1: CGPoint(x: c.x, y: c.y),
                        controlPoint2: CGPoint(x: c.x, y: c.y))
                p.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint1: CGPoint(x: c.x, y: c.y),
                        controlPoint2: CGPoint(x: c.x, y: c.y))
                p.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint1: CGPoint(x: c.x, y: c.y),
                        controlPoint2: CGPoint(x: c.x, y: c.y))
                NSColor(white: 0, alpha: 0.9).setFill()
                p.fill()
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return Image(nsImage: image)
    }
}

// MARK: - 长夜月's own details

/// Her voice at night. The *state* behind each line is the kitten's (see
/// `MascotState.castLine`); only the wording changes — a guardian keeping
/// watch through a long night, in original words.
enum NocturneVoice {
    static func text(_ line: MascotState.Line, _ lang: Language) -> String {
        switch line {
        case .idle: return L10n.text(.nightIdle, lang)
        case .quiet: return L10n.text(.nightQuiet, lang)
        case .critical: return L10n.text(.nightCritical, lang)
        case .napping: return L10n.text(.nightNapping, lang)
        case .working: return L10n.text(.nightWorking, lang)
        case .blind: return L10n.text(.nightBlind, lang)
        case .fresh: return L10n.text(.nightFresh, lang)
        }
    }

    static func greeting(hour: Int, _ lang: Language) -> String {
        switch hour {
        case 5..<12: return L10n.text(.nightMorning, lang)
        case 12..<18: return L10n.text(.nightAfternoon, lang)
        case 18..<23: return L10n.text(.nightEvening, lang)
        default: return L10n.text(.nightLate, lang)
        }
    }
}

/// Tonight's moon, from the mean synodic month — accurate to within about a
/// day, which is all an eight-step icon can show anyway.
enum MoonPhase: Int, CaseIterable {
    case new, waxingCrescent, firstQuarter, waxingGibbous, full, waningGibbous, lastQuarter, waningCrescent

    static func at(_ date: Date) -> MoonPhase {
        // A reference new moon: 2000-01-06 18:14 UTC.
        let reference = Date(timeIntervalSince1970: 947_182_440)
        let synodic = 29.530588853 * 86_400
        var age = date.timeIntervalSince(reference).truncatingRemainder(dividingBy: synodic)
        if age < 0 { age += synodic }
        return MoonPhase(rawValue: Int((age / synodic * 8).rounded()) % 8) ?? .new
    }

    var symbol: String {
        switch self {
        case .new: return "moonphase.new.moon"
        case .waxingCrescent: return "moonphase.waxing.crescent"
        case .firstQuarter: return "moonphase.first.quarter"
        case .waxingGibbous: return "moonphase.waxing.gibbous"
        case .full: return "moonphase.full.moon"
        case .waningGibbous: return "moonphase.waning.gibbous"
        case .lastQuarter: return "moonphase.last.quarter"
        case .waningCrescent: return "moonphase.waning.crescent"
        }
    }

    var name: L10n.Key {
        switch self {
        case .new: return .moonNew
        case .waxingCrescent: return .moonWaxingCrescent
        case .firstQuarter: return .moonFirstQuarter
        case .waxingGibbous: return .moonWaxingGibbous
        case .full: return .moonFull
        case .waningGibbous: return .moonWaningGibbous
        case .lastQuarter: return .moonLastQuarter
        case .waningCrescent: return .moonWaningCrescent
        }
    }
}

/// Tonight's moon beside the date in the header; its name on hover.
struct MoonPhaseBadge: View {
    let lang: Language

    var body: some View {
        let phase = MoonPhase.at(Date())
        Image(systemName: phase.symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.accent)
            .help(L10n.text(phase.name, lang))
            .accessibilityLabel(L10n.text(phase.name, lang))
    }
}

/// 镜中人 — she is March 7th's mirrored self, and the moon of the long night:
/// so at night the hero shows her inside a round hand-mirror that is also a
/// full moon. Moonlit glass behind her, a silver rim, and four diamond studs
/// cut like the charms that hang from her hairpin.
///
/// All of it is static; only the portrait inside moves, on the render server
/// (see `MascotCels`), masked to the glass so she moves *within* the mirror.
struct MoonMirror<Portrait: View>: View {
    @ViewBuilder let portrait: () -> Portrait

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                // A glow cast by the moon itself, on a shape of its own so the
                // blur is rendered once and never re-rendered with her.
                Circle()
                    .fill(Theme.surface)
                    .shadow(color: Theme.accent.opacity(0.35), radius: d * 0.08)
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(red: 0.93, green: 0.86, blue: 0.95).opacity(0.30),
                                 Theme.accent.opacity(0.12), Theme.sunken],
                        center: UnitPoint(x: 0.42, y: 0.36), startRadius: 0, endRadius: d * 0.62))
                portrait()
                    .frame(width: d * 0.98, height: d * 0.98)
                // A sheen across the glass.
                Circle()
                    .trim(from: 0.58, to: 0.70)
                    .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: d * 0.025, lineCap: .round))
                    .padding(d * 0.09)
                // The rim: silver outer band, a thin lilac inner line.
                Circle()
                    .strokeBorder(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.55), Color(white: 0.85)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: max(2, d * 0.02))
                Circle()
                    .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 0.8)
                    .padding(max(2, d * 0.02) + 2)
                // A crimson ribbon tied at the top of the frame — the bow from
                // her sheet's pillow and cuffs — in place of the top stud.
                RibbonBow()
                    .frame(width: d * 0.34, height: d * 0.2)
                    .offset(y: -d / 2 - d * 0.02)
                ForEach(Array(Self.studs.enumerated()), id: \.offset) { _, stud in
                    Diamond()
                        .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.6)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Diamond().stroke(Theme.sunken.opacity(0.6), lineWidth: 0.6))
                        .frame(width: d * stud.w, height: d * stud.h)
                        .offset(x: d / 2 * Darwin.sin(stud.angle), y: -d / 2 * Darwin.cos(stud.angle))
                }
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private static var studs: [(angle: CGFloat, w: CGFloat, h: CGFloat)] {
        [(.pi, 0.06, 0.10), (.pi / 2, 0.05, 0.075), (-.pi / 2, 0.05, 0.075)]
    }
}

/// An elongated diamond — her hairpin's charm, and the studs on the mirror.
struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

/// When quota breaks at night: a burst of ice instead of a comic's impact —
/// six long arms and six short, like a frost crystal flaring.
struct FrostBurst: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let steps = 24
        for i in 0..<steps {
            let angle = Double(i) / Double(steps) * 2 * .pi - .pi / 2
            let r: CGFloat
            switch i % 4 {
            case 0: r = outer
            case 2: r = outer * 0.62
            default: r = outer * 0.34
            }
            let pt = CGPoint(x: c.x + Darwin.cos(angle) * r, y: c.y + Darwin.sin(angle) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Cracks running across a card from its bottom-right corner: the mirror
/// giving way when a quota does. Seeded, so the same card cracks the same way.
struct MirrorCracks: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let origin = CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.maxY - rect.height * 0.14)
        let rays: [(angle: Double, length: CGFloat)] = [
            (-2.9, 0.55), (-2.45, 0.42), (-2.05, 0.6), (-1.7, 0.38), (-1.35, 0.5), (2.8, 0.3),
        ]
        for (k, ray) in rays.enumerated() {
            var point = origin
            p.move(to: point)
            let total = min(rect.width, rect.height) * ray.length * 1.05
            for step in 1...4 {
                let jitter = Darwin.sin(Double(k * 7 + step) * 1.7) * 0.28
                let a = ray.angle + jitter
                let len = total / 4
                point = CGPoint(x: point.x + Darwin.cos(a) * len, y: point.y + Darwin.sin(a) * len)
                p.addLine(to: point)
            }
        }
        return p
    }
}

/// Twelve ticks around a quota ring: the ring counts down to a reset, so at
/// night it is dressed as the clock it is.
struct ClockTicks: View {
    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ForEach(0..<12, id: \.self) { i in
                Capsule()
                    .fill(Theme.textFaint.opacity(i % 3 == 0 ? 0.9 : 0.55))
                    .frame(width: i % 3 == 0 ? 1.4 : 1, height: i % 3 == 0 ? 3.5 : 2.5)
                    .offset(y: -d / 2 + 1.5)
                    .rotationEffect(.degrees(Double(i) * 30))
                    .frame(width: d, height: d)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A crimson ribbon bow: two loops, two tails and a knot, with a darker ink
/// line — the gothic-lolita bow from her cuffs and pillow.
struct RibbonBow: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let fill = LinearGradient(colors: [Color(red: 0.80, green: 0.20, blue: 0.29),
                                               Color(red: 0.55, green: 0.10, blue: 0.18)],
                                      startPoint: .top, endPoint: .bottom)
            let ink = Color(red: 0.25, green: 0.05, blue: 0.09)
            ZStack {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    // Tail.
                    Path { p in
                        p.move(to: CGPoint(x: w / 2 + side * w * 0.04, y: h * 0.5))
                        p.addLine(to: CGPoint(x: w / 2 + side * w * 0.22, y: h * 1.05))
                        p.addLine(to: CGPoint(x: w / 2 + side * w * 0.12, y: h * 0.92))
                        p.addLine(to: CGPoint(x: w / 2 + side * w * 0.05, y: h * 1.0))
                        p.closeSubpath()
                    }
                    .fill(fill)
                    .overlay(Path { p in
                        p.move(to: CGPoint(x: w / 2 + side * w * 0.04, y: h * 0.5))
                        p.addLine(to: CGPoint(x: w / 2 + side * w * 0.22, y: h * 1.05))
                    }.stroke(ink.opacity(0.6), lineWidth: 0.6))
                    // Loop.
                    Ellipse()
                        .fill(fill)
                        .overlay(Ellipse().stroke(ink.opacity(0.7), lineWidth: 0.7))
                        .frame(width: w * 0.44, height: h * 0.58)
                        .rotationEffect(.degrees(side * 18))
                        .offset(x: side * w * 0.23, y: -h * 0.06)
                }
                Capsule()
                    .fill(fill)
                    .overlay(Capsule().stroke(ink.opacity(0.8), lineWidth: 0.7))
                    .frame(width: w * 0.16, height: h * 0.42)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Lace along the foot of a card: a band with scalloped edges and a row of
/// eyelets, like the frilled white cuffs of her dress. Static.
struct LaceTrim: Shape {
    var scallop: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let band = scallop * 1.2
        let top = rect.maxY - band
        p.addRect(CGRect(x: rect.minX, y: top, width: rect.width, height: band))
        var x = rect.minX + scallop
        while x < rect.maxX {
            p.addEllipse(in: CGRect(x: x - scallop, y: top - scallop, width: scallop * 2, height: scallop * 2))
            x += scallop * 2
        }
        return p
    }

    /// The eyelets punched through the lace, drawn as their own shape so the
    /// lace can be filled and the holes cut with even-odd.
    static func eyelets(in rect: CGRect, scallop: CGFloat = 5) -> Path {
        var p = Path()
        var x = rect.minX + scallop
        let y = rect.maxY - scallop * 1.2 - scallop * 0.2
        while x < rect.maxX {
            p.addEllipse(in: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4))
            x += scallop * 2
        }
        return p
    }
}

/// The lace, with its eyelets cut out.
struct LaceBand: View {
    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            var lace = LaceTrim().path(in: rect)
            let _ = lace.addPath(LaceTrim.eyelets(in: rect))
            lace.fill(Theme.textSecondary.opacity(0.10), style: FillStyle(eoFill: true))
        }
        .frame(height: 12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A section title's flourish at night: a small diamond and a hairline that
/// fades out to the right.
struct NightFlourish: View {
    var body: some View {
        HStack(spacing: 4) {
            Diamond()
                .fill(Theme.accent.opacity(0.8))
                .frame(width: 5, height: 8)
            LinearGradient(colors: [Theme.accent.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 48, height: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
