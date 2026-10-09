#if DEBUG
import AIMonitorCore
import AppKit
import AVFoundation
import SwiftUI

/// Offline visual fixtures: no production store, provider log scan, or credentials.
@MainActor
enum VisualReview {
    static func render(to directory: String) throws {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for reduced in [true, false] {
            for lowPower in [true, false] {
                let budget = MotionBudget(reduceMotion: reduced, lowPower: lowPower)
                // Low Power Mode keeps readable cross-fades but removes travel
                // (reveals, parallax, springs); Reduce Motion removes both.
                precondition(budget.allowsAnimation == !reduced)
                precondition(budget.allowsTravel == (!reduced && !lowPower))
            }
        }
        let preferenceStore = try EventStore.inMemory()
        let preferences = try MonitorModel(store: preferenceStore, readsSources: false)
        precondition(preferences.animationsEnabled)
        preferences.setAnimationsEnabled(false)
        let reopened = try MonitorModel(store: preferenceStore, readsSources: false)
        precondition(!reopened.animationsEnabled)
        reopened.setAnimationsEnabled(true)
        precondition(preferenceStore.setting("animations_enabled") == "true")
        print("Motion policy and preference persistence: PASS")
        let cases: [(String, CGFloat, String, Language, Page, Bool)] = [
            ("light-480", 480, "light", .zh, .dashboard, false),
            ("light-480-full", 480, "light", .zh, .dashboard, false),
            ("dark-480-full", 480, "dark", .en, .dashboard, false),
            ("dark-480", 480, "dark", .zh, .dashboard, false),
            ("narrow-360", 360, "light", .zh, .dashboard, false),
            ("english-narrow-360", 360, "light", .en, .dashboard, false),
            ("wide-900", 900, "light", .zh, .dashboard, false),
            ("english-480", 480, "light", .en, .dashboard, false),
            ("empty-480", 480, "light", .zh, .dashboard, true),
            ("settings-480", 480, "light", .zh, .settings, false),
            ("settings-dark-480", 480, "dark", .en, .settings, false),
            ("models-480", 480, "light", .zh, .models, false),
            ("timeline-480", 480, "dark", .zh, .timeline, false),
            ("nocturne-480-full", 480, "system", .zh, .dashboard, false),
            ("nocturne-420", 420, "system", .zh, .dashboard, false),
            ("nocturne-empty-480", 480, "system", .zh, .dashboard, true),
            ("nocturne-narrow-360", 360, "system", .en, .dashboard, false),
            ("nocturne-settings-480", 480, "system", .zh, .settings, false),
            ("nocturne-models-480", 480, "system", .zh, .models, false),
            // A long day at the narrowest widths. The seeded figures are short
            // (18m, $0.36, 18), so a layout could fit them and still clip the
            // numbers a heavy user actually sees.
            ("heavy-420", 420, "light", .en, .dashboard, false),
            ("nocturne-heavy-360", 360, "system", .en, .dashboard, false),
            // The settlement slip: both spans, both skins, light and dark,
            // both languages, the narrowest window, and a day with no sales.
            ("receipt-1d-480-full", 480, "light", .zh, .receipt, false),
            ("receipt-7d-480-full", 480, "light", .zh, .receipt, false),
            ("receipt-7d-dark-480-full", 480, "dark", .en, .receipt, false),
            ("receipt-7d-en-360-full", 360, "light", .en, .receipt, false),
            ("receipt-empty-480-full", 480, "light", .zh, .receipt, true),
            ("nocturne-receipt-7d-480-full", 480, "system", .zh, .receipt, false),
            ("nocturne-receipt-1d-360-full", 360, "system", .en, .receipt, false),
            // The morning: the hero's photograph and her chat line, a narrow
            // window, an empty day, settings, a heavy day, and the slip.
            ("aubade-480-full", 480, "system", .zh, .dashboard, false),
            ("aubade-narrow-360", 360, "system", .en, .dashboard, false),
            ("aubade-empty-480", 480, "system", .zh, .dashboard, true),
            ("aubade-settings-480", 480, "system", .zh, .settings, false),
            ("aubade-heavy-420", 420, "system", .en, .dashboard, false),
            ("aubade-receipt-7d-480-full", 480, "system", .zh, .receipt, false),
            ("aubade-receipt-1d-360-full", 360, "system", .en, .receipt, false)
        ]
        for (name, width, appearance, language, page, empty) in cases {
            // "-full" renders the whole scroll so the lower sections are seen.
            let height: CGFloat = name.hasSuffix("-full") ? 1640 : 900
            let store = try EventStore.inMemory()
            let now = Date()
            if !empty { try DemoWindow.seed(store, now: now) }
            if !empty, name.contains("receipt") { try DemoWindow.seedWeek(store, now: now) }
            if name.contains("heavy") {
                // Two readings six hours apart, so the burn-rate engine makes a
                // real projection (~22h). The seed has one reading per window,
                // so no review render ever showed the projection line — which
                // is how its sentence ran off a two-column card unnoticed.
                for (hoursAgo, used) in [(6.0, 1.0), (0.0, 22.0)] {
                    try store.insert(quota: QuotaWindow(
                        id: "demo-burn", label: "weekly · secondary", usedPercent: used,
                        windowMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400),
                        observedAt: now.addingTimeInterval(-hoursAgo * 3600)), provider: "Codex CLI")
                }
            }
            let model = try MonitorModel(store: store, readsSources: false)
            let skin: Skin = name.hasPrefix("nocturne") ? .nocturne : name.hasPrefix("aubade") ? .aubade : .observatory
            let night = skin == .nocturne
            model.setSkin(skin)
            model.language = language
            model.appearance = appearance
            model.animationsEnabled = false
            model.page = page
            model.dashboard = try StoreReport.dashboard(from: store, now: now)
            if name.contains("heavy") {
                model.dashboard?.todayActiveMinutes = 754
                model.dashboard?.todayCostUSD = 123.45
                model.dashboard?.todayRequests = 1234
                model.dashboard?.todayTokens = 187_654_321
            }
            model.live = try store.liveCounters(now: now)
            model.timeline = try store.recentEvents()
            model.models = try store.totalsByModel()
            if page == .receipt {
                model.receipts = [.day: try store.receipt(.day, now: now), .week: try store.receipt(.week, now: now)]
                model.receiptSpan = name.contains("7d") ? .week : .day
            }
            let root = RootView().environmentObject(model)
                .frame(width: width, height: height)
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance == "dark" || night ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                throw CocoaError(.fileWriteUnknown)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
            window.contentView = nil
            print("Rendered \(name) (synthetic data)")
        }

        // The exported share image goes through `ImageRenderer`, which captures
        // one frame before `onAppear` — rings and bars must already be drawn.
        let store = try EventStore.inMemory()
        let now = Date()
        try DemoWindow.seed(store, now: now)
        let dashboard = try StoreReport.dashboard(from: store, now: now)
        for skin in Skin.allCases {
            Skin.current = skin
            let renderer = ImageRenderer(content: ShareCardView(d: dashboard, lang: .zh))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: output.appendingPathComponent("share-card-\(skin.rawValue).png"))
            print("Rendered share-card-\(skin.rawValue) (synthetic data)")
        }
        Skin.current = .observatory
    }

    // MARK: - The print, frame by frame

    /// `--print-film <dir> [--week] [--nocturne | --aubade]`: the receipt's print drawn
    /// a frame at a time — the motor's run, the cutter, the seal — into an
    /// MP4 at 60fps, a strip of six moments, and the moments as PNGs.
    ///
    /// `cacheDisplay` draws a view's final state, not its presentation, so a
    /// live window cannot be photographed mid-animation. Each frame here is
    /// instead the slip told exactly which moment to draw, with the same
    /// timing functions the live print uses (`PaperFeed.fed`, the cutter's
    /// and the seal's springs). Synthetic data only.
    static func film(to directory: String) throws {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let week = CommandLine.arguments.contains("--week")
        let night = CommandLine.arguments.contains("--nocturne")
        let day = CommandLine.arguments.contains("--aubade")
        let store = try EventStore.inMemory()
        let now = Date()
        try DemoWindow.seed(store, now: now)
        try DemoWindow.seedWeek(store, now: now)
        let model = try MonitorModel(store: store, readsSources: false)
        model.setSkin(night ? .nocturne : day ? .aubade : .observatory)
        model.language = .zh
        model.animationsEnabled = false
        model.page = .receipt
        model.receipts = [.day: try store.receipt(.day, now: now), .week: try store.receipt(.week, now: now)]
        model.receiptSpan = week ? .week : .day
        let slip = model.receipts[model.receiptSpan]!

        final class Clock: ObservableObject { @Published var frame = ReceiptFilmFrame(clock: 0, hang: PaperFeed.hang, stamp: 0) }
        struct Film: View {
            @ObservedObject var clock: Clock
            let model: MonitorModel
            var body: some View {
                RootView().environmentObject(model).environment(\.receiptFilm, clock.frame)
            }
        }
        let size = CGSize(width: 420, height: 720)
        let clock = Clock()
        let hosting = NSHostingView(rootView: Film(clock: clock, model: model).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: night ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        // The run, as the live print times it, between a beat of the idle
        // printer before and the sealed slip held after.
        let fps = 60.0
        let lead = 0.3
        let run = ReceiptSlip.printDuration(slip)
        let total = lead + run + 1.6
        func moment(_ t: Double) -> ReceiptFilmFrame {
            let clockValue = CGFloat(max(0, min(1, (t - lead) / run)))
            let after = t - lead - run
            guard after > 0 else { return ReceiptFilmFrame(clock: clockValue, hang: PaperFeed.hang, stamp: 0) }
            let drop: Double = Motion.cutSpring.value(target: 1.0, time: after)
            let seal: Double = after > Motion.stampDelay
                ? Motion.stampSpring.value(target: 1.0, time: after - Motion.stampDelay) : 0
            return ReceiptFilmFrame(clock: 1, hang: PaperFeed.hang * CGFloat(1 - drop), stamp: CGFloat(seal))
        }

        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        let movie = output.appendingPathComponent(week ? "print-7d.mp4" : "print-1d.mp4")
        try? FileManager.default.removeItem(at: movie)
        // The six moments of the strip: idle, early, mid, nearly out, the
        // drop, sealed.
        let marks = [0.2, lead + run * 0.18, lead + run * 0.45, lead + run * 0.8,
                     lead + run + 0.06, total - 0.05]
        var stills: [NSBitmapImageRep] = []
        let count = Int(total * fps)
        for i in 0..<count {
            let t = Double(i) / fps
            clock.frame = moment(t)
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let image = rep.cgImage else { continue }
            if writer == nil {
                let w = try AVAssetWriter(outputURL: movie, fileType: .mp4)
                let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264,
                                               AVVideoWidthKey: image.width, AVVideoHeightKey: image.height]
                let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                inp.expectsMediaDataInRealTime = false
                let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: image.width, kCVPixelBufferHeightKey as String: image.height])
                w.add(inp)
                w.startWriting()
                w.startSession(atSourceTime: .zero)
                writer = w; input = inp; adaptor = ad
            }
            while input?.isReadyForMoreMediaData == false { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
            if let pool = adaptor?.pixelBufferPool {
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                if let buffer {
                    CVPixelBufferLockBaseAddress(buffer, [])
                    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                    ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    adaptor?.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
                }
            }
            if let next = marks.dropFirst(stills.count).first, t >= next {
                stills.append(rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: output.appendingPathComponent(String(format: "moment-%d.png", stills.count)))
            }
        }
        input?.markAsFinished()
        var done = false
        writer?.finishWriting { done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if let error = writer?.error { throw error }

        // The strip: the six moments side by side at half size.
        if let first = stills.first {
            let w = first.pixelsWide / 2, h = first.pixelsHigh / 2, gap = 12
            let strip = NSImage(size: NSSize(width: (w + gap) * stills.count - gap, height: h))
            strip.lockFocus()
            NSColor(white: 0.5, alpha: 1).setFill()
            NSRect(origin: .zero, size: strip.size).fill()
            for (n, rep) in stills.enumerated() {
                rep.draw(in: NSRect(x: n * (w + gap), y: 0, width: w, height: h))
            }
            strip.unlockFocus()
            if let tiff = strip.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent(week ? "print-7d-strip.png" : "print-1d-strip.png"))
            }
        }
        window.orderOut(nil)
        print(String(format: "Filmed %@: %d frames, run %.2fs, steps of %.0fpt", movie.lastPathComponent, count, run, PaperFeed.pitch))
    }
}
#endif
