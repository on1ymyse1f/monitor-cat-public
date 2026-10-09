import Foundation

/// A launchd agent that keeps the store current without the app being open.
///
/// The dashboard is not the only way to want this data, and it is a poor way to
/// want it constantly: keeping a SwiftUI app running so that a number stays
/// fresh costs a dock icon, a menu-bar item and a process, for a job that is
/// one `stat` sweep and an incremental parse.
///
/// This installs a `launchd` LaunchAgent that runs `aimonitor --sync` on an
/// interval. Afterwards the CLI answers instantly and correctly with nothing
/// else running, and the app — when it is opened — finds the work already done.
///
/// It stays inside the project's rules: the agent runs the same read-only
/// collectors, writes the same local SQLite file, and makes no network request
/// (the quota fetches are app-side and opt-in). Nothing is added to login items
/// and nothing is hidden — the plist is a readable file at a documented path,
/// and `--uninstall-agent` removes it.
public enum BackgroundAgent {
    public static let label = "com.aimonitor.sync"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIMonitor/sync-agent.log")
    }

    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// The agent's configuration, as a property list object.
    ///
    /// **Built as data, never as text.** An earlier version templated these
    /// values into an XML string, which is an injection hole: every one of them
    /// is a filesystem path, and a path may legitimately contain `&` or `<`. A
    /// home directory with an `&` in it produced malformed XML and launchd
    /// silently declined to load the job — and a directory named, say,
    /// `</string><key>RunAtLoad</key>…` would have injected arbitrary keys into
    /// a file that launchd executes. `PropertyListSerialization` encodes the
    /// values rather than pasting them, so no path can escape its own field.
    ///
    /// `RunAtLoad` plus `StartInterval` rather than `WatchPaths` on the log
    /// directories: watching would fire on every line an agent writes, which is
    /// thousands of wake-ups an hour for work that is only interesting every
    /// few minutes. The sync is incremental, so a periodic run usually costs a
    /// fingerprint check and stops there.
    public static func configuration(
        executable: String, dbPath: String, everySeconds: Int
    ) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable, "--sync", dbPath],
            "RunAtLoad": true,
            "StartInterval": everySeconds,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 5,
        ]
    }

    /// The plist as text, for showing the user before anything is written.
    public static func plist(executable: String, dbPath: String, everySeconds: Int) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: configuration(executable: executable, dbPath: dbPath, everySeconds: everySeconds),
            format: .xml, options: 0
        )
        return String(decoding: data, as: UTF8.self)
    }

    public static func write(executable: String, dbPath: String, everySeconds: Int) throws -> URL {
        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // The agent's log records sync counts against this person's projects.
        // Create it owner-only rather than letting launchd make it with the
        // default umask.
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(
                atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
            )
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: configuration(executable: executable, dbPath: dbPath, everySeconds: everySeconds),
            format: .xml, options: 0
        )
        try data.write(to: url, options: .atomic)
        // launchd reads this as the user; nobody else needs it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        return url
    }

    public static func remove() throws -> Bool {
        guard isInstalled() else { return false }
        try FileManager.default.removeItem(at: plistURL)
        return true
    }
}
