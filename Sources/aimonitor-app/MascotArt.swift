import AIMonitorCore
import AppKit

/// シール — the kitten's sketches, printed as die-cut stickers.
///
/// The bundled art is black ink on transparency: a line drawing with nothing
/// inside it. On a coloured card that reads as a doodle, not a character, so
/// each drawing is given a body the way a sticker sheet gives one:
///
///   1. **塗り (fill)** — the inside of the outline, found by closing the gaps
///      in the linework and flood-filling the outside. What the flood cannot
///      reach is the character.
///   2. **白フチ (die-cut border)** — that silhouette grown a few pixels and
///      printed white, with one soft shadow under it.
///   3. **線 (line)** — the original drawing on top, in a warm ink.
///
/// All three are baked into **one bitmap per pose, once**, and cached. The
/// 8fps mascot then moves a single image, exactly as it did when the art was a
/// bare line drawing: no live blur, no mask, no extra layers per frame. No new
/// files ship either — the stickers are derived from the sketches already in
/// the bundle, so a new pose is still one PNG and one enum case.
///
/// The sticker is printed the same in light and dark mode, as a real sticker
/// would be: cream body, warm ink, white edge.
@MainActor
enum MascotArt {
    /// Warm near-black for the linework — Claude's text ink, not pure black.
    static let ink = NSColor(red: 0.196, green: 0.169, blue: 0.157, alpha: 1)      // #322B28
    /// The body: a cream with a trace of warmth, so the cat is not a hole cut
    /// in the card.
    static let body = NSColor(red: 1.0, green: 0.980, blue: 0.957, alpha: 1)       // #FFFAF4
    static let edge = NSColor.white

    private struct Key: Hashable {
        let mood: MascotState.Mood
        let output: CGFloat
    }

    private static var stickers: [Key: NSImage] = [:]
    private static var lines: [MascotState.Mood: NSImage] = [:]

    /// The finished sticker for a pose, sized for where it is shown. Baked on
    /// first use; a few milliseconds in a release build, then free.
    ///
    /// Two sizes, because most cats on the page are marks at the end of a
    /// heading: a 34pt sticker drawn from a 480px bitmap holds ~0.8 MB for
    /// nothing. Small uses get a 200px bake (~0.13 MB); the hero and the
    /// exported card get the full one.
    static func sticker(_ mood: MascotState.Mood, pointWidth: CGFloat = 200) -> NSImage {
        // By day and at night the theme's character pack plays the mascot,
        // where it maps this mood; anything it leaves out is still the kitten.
        if let art = CharacterPack.current?.image(for: mood, small: pointWidth <= 80) {
            return art
        }
        let key = Key(mood: mood, output: pointWidth <= 80 ? 200 : 480)
        if let hit = stickers[key] { return hit }
        let made = bake(mood, output: key.output) ?? line(mood)
        stickers[key] = made
        return made
    }

    /// Forget every baked sticker. Called when the window closes: the menu bar
    /// draws no mascot, so a window-less app has no reason to hold them.
    static func purge() {
        stickers.removeAll()
        lines.removeAll()
    }

    /// The bare drawing as a template image, for places that want only a line
    /// (tiny sizes, or a tint of their own).
    static func line(_ mood: MascotState.Mood) -> NSImage {
        if let hit = lines[mood] { return hit }
        let image = AppResources.image(named: mood.rawValue) ?? NSImage(size: .init(width: 1, height: 1))
        image.isTemplate = true
        lines[mood] = image
        return image
    }

    // MARK: - Baking

    /// Long side of the analysis grid. The silhouette only has to be right to
    /// within the width of the ink line that covers its edge, so it is found
    /// on a small grid and scaled up; the line itself is drawn from the source.
    private static let grid = 288
    private static func bake(_ mood: MascotState.Mood, output: CGFloat) -> NSImage? {
        guard let source = AppResources.image(named: mood.rawValue),
              let art = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let aspect = CGFloat(art.width) / CGFloat(art.height)
        let gw = aspect >= 1 ? grid : max(1, Int(CGFloat(grid) * aspect))
        let gh = aspect >= 1 ? max(1, Int(CGFloat(grid) / aspect)) : grid
        let unit = Double(grid) / 256          // parameters were tuned at 256
        let border = Int((3.2 * unit).rounded())
        let margin = border + Int((10 * unit).rounded())   // room for edge + shadow
        let w = gw + 2 * margin, h = gh + 2 * margin

        // 1. Ink coverage on the grid.
        guard var coverage = alpha(of: art, width: gw, height: gh, margin: margin, canvas: (w, h)) else { return nil }
        let ink = coverage.map { $0 > 60 }

        // 2. Close the gaps, flood the outside, give back what closing took.
        //    The radius is adaptive: most sketches close at a small radius,
        //    but the looser early drawings (angry, pounce) need a wider one.
        //    Growing only when it buys real area keeps tight drawings from
        //    webbing over the gaps between an arm and the body.
        func silhouette(radius r: Int) -> [Bool] {
            let closed = dilateSquare(ink, w, h, r)
            let inside = fillHoles(closed, w, h)
            var body = erodeSquare(inside, w, h, max(0, r - 1))
            for i in body.indices where ink[i] { body[i] = true }
            return body
        }
        let small = silhouette(radius: Int((4 * unit).rounded()))
        let wide = silhouette(radius: Int((7 * unit).rounded()))
        let areaSmall = small.lazy.filter { $0 }.count
        let areaWide = wide.lazy.filter { $0 }.count
        let body = Double(areaWide) > Double(areaSmall) * 1.15 ? wide : small

        // 3. The die-cut edge: an octagonal growth reads as a round-cornered
        //    cut, where a square growth would chamfer every outward point.
        let edge = dilateOctagon(body, w, h, border)

        // Soften both masks one pixel so they scale up without stair-steps.
        let bodyAlpha = blur3(body, w, h)
        let edgeAlpha = blur3(edge, w, h)
        coverage.removeAll()

        guard let bodyImage = solid(MascotArt.body, alpha: bodyAlpha, w, h),
              let edgeImage = solid(MascotArt.edge, alpha: edgeAlpha, w, h) else { return nil }

        // 4. Compose at output resolution: edge (with its shadow), body, line.
        let scale = output / CGFloat(max(w, h))
        let ow = Int((CGFloat(w) * scale).rounded()), oh = Int((CGFloat(h) * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let full = CGRect(x: 0, y: 0, width: ow, height: oh)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3 * scale),
                      blur: 7 * scale,
                      color: NSColor(red: 0.25, green: 0.16, blue: 0.12, alpha: 0.22).cgColor)
        ctx.draw(edgeImage, in: full)
        ctx.restoreGState()
        ctx.draw(bodyImage, in: full)

        let artRect = CGRect(x: CGFloat(margin) * scale, y: CGFloat(margin) * scale,
                             width: CGFloat(gw) * scale, height: CGFloat(gh) * scale)
        if let tinted = tint(art, MascotArt.ink, size: artRect.size) {
            ctx.draw(tinted, in: artRect)
        }

        guard let baked = ctx.makeImage() else { return nil }
        // Points at 2×, so `scaledToFit` sizes it like any other image.
        return NSImage(cgImage: baked, size: NSSize(width: CGFloat(ow) / 2, height: CGFloat(oh) / 2))
    }

    /// The drawing's alpha on the grid, centred with `margin` on every side.
    private static func alpha(of art: CGImage, width: Int, height: Int, margin: Int,
                              canvas: (Int, Int)) -> [UInt8]? {
        let (w, h) = canvas
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(art, in: CGRect(x: margin, y: margin, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var out = [UInt8](repeating: 0, count: w * h)
        // Row order does not matter: every mask is built and drawn back in
        // the same orientation.
        for i in 0..<(w * h) { out[i] = bytes[i * 4 + 3] }
        return out
    }

    /// A flat colour with the given coverage, as an image.
    private static func solid(_ color: NSColor, alpha: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Double(rgb.redComponent), g = Double(rgb.greenComponent), b = Double(rgb.blueComponent)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = Double(alpha[i])
            px[i * 4] = UInt8(r * a)
            px[i * 4 + 1] = UInt8(g * a)
            px[i * 4 + 2] = UInt8(b * a)
            px[i * 4 + 3] = alpha[i]
        }
        return px.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    /// The line art recoloured to `color`, keeping its own anti-aliasing.
    private static func tint(_ art: CGImage, _ color: NSColor, size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(art, in: rect)
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
        return ctx.makeImage()
    }

    // MARK: - Binary morphology on a w×h grid

    /// Separable max filter: a (2r+1)² square in two passes.
    private static func dilateSquare(_ m: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] {
        guard r > 0 else { return m }
        var tmp = [Bool](repeating: false, count: m.count)
        m.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let row = y * w
                    // Running count of set pixels inside the window.
                    var count = 0
                    for x in 0..<min(r, w) where src[row + x] { count += 1 }
                    for x in 0..<w {
                        let add = x + r, drop = x - r - 1
                        if add < w, src[row + add] { count += 1 }
                        if drop >= 0, src[row + drop] { count -= 1 }
                        dst[row + x] = count > 0
                    }
                }
            }
        }
        var out = [Bool](repeating: false, count: m.count)
        tmp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for x in 0..<w {
                    var count = 0
                    for y in 0..<min(r, h) where src[y * w + x] { count += 1 }
                    for y in 0..<h {
                        let add = y + r, drop = y - r - 1
                        if add < h, src[add * w + x] { count += 1 }
                        if drop >= 0, src[drop * w + x] { count -= 1 }
                        dst[y * w + x] = count > 0
                    }
                }
            }
        }
        return out
    }

    private static func erodeSquare(_ m: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] {
        // Erosion is dilation of the complement.
        dilateSquare(m.map { !$0 }, w, h, r).map { !$0 }
    }

    /// Alternating 3×3 square and plus-shaped steps: an octagon, which is as
    /// round as a cut line needs to look at this size.
    private static func dilateOctagon(_ m: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] {
        var cur = m
        for step in 0..<r {
            if step.isMultiple(of: 2) {
                cur = dilateSquare(cur, w, h, 1)
            } else {
                var next = cur
                cur.withUnsafeBufferPointer { src in
                    next.withUnsafeMutableBufferPointer { dst in
                        for y in 0..<h {
                            for x in 0..<w where !src[y * w + x] {
                                let i = y * w + x
                                if (x > 0 && src[i - 1]) || (x < w - 1 && src[i + 1])
                                    || (y > 0 && src[i - w]) || (y < h - 1 && src[i + w]) {
                                    dst[i] = true
                                }
                            }
                        }
                    }
                }
                cur = next
            }
        }
        return cur
    }

    /// Everything the outside cannot reach. The grid has a clear margin, so
    /// the flood starts from the whole border.
    private static func fillHoles(_ wall: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var outside = [Bool](repeating: false, count: wall.count)
        var stack: [Int] = []
        stack.reserveCapacity(w * h / 4)
        func push(_ i: Int) {
            if !wall[i] && !outside[i] { outside[i] = true; stack.append(i) }
        }
        for x in 0..<w { push(x); push((h - 1) * w + x) }
        for y in 0..<h { push(y * w); push(y * w + w - 1) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0 { push(i - 1) }
            if x < w - 1 { push(i + 1) }
            if y > 0 { push(i - w) }
            if y < h - 1 { push(i + w) }
        }
        return outside.map { !$0 }
    }

    /// 3×3 box blur of a mask into 0…255 coverage.
    private static func blur3(_ m: [Bool], _ w: Int, _ h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: m.count)
        for y in 0..<h {
            for x in 0..<w {
                var n = 0
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < h else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx >= 0, xx < w, m[yy * w + xx] { n += 1 }
                    }
                }
                out[y * w + x] = UInt8(n * 255 / 9)
            }
        }
        return out
    }
}
