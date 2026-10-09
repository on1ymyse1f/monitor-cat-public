import AppKit

/// Resource lookup for both `swift run` and the hand-assembled `.app` bundle.
///
/// Loading PNGs by URL avoids CoreUI treating SwiftPM's resource-only bundle as
/// an asset catalog. It also gives the menu-bar icon and mascot one shared path.
enum AppResources {
    private static let bundleName = "AIMonitor_aimonitor-app.bundle"

    private static let bundleURL: URL? = {
        var candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.privateFrameworksURL?.appendingPathComponent(bundleName),
        ]
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent(bundleName))
        }
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }()

    static func image(named name: String) -> NSImage? {
        guard let bundleURL else { return nil }
        let candidates = [
            bundleURL.appendingPathComponent("Contents/Resources/\(name).png"),
            bundleURL.appendingPathComponent("Resources/\(name).png"),
            bundleURL.appendingPathComponent("\(name).png"),
        ]
        return candidates.lazy.compactMap(NSImage.init(contentsOf:)).first
    }
}
