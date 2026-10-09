import AIMonitorCore
import AppKit

// The executable entry point intentionally stays tiny. App lifecycle,
// observable state, and SwiftUI composition live in focused source files.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    do {
#if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-review"), CommandLine.arguments.count > index + 1 {
            try VisualReview.render(to: CommandLine.arguments[index + 1])
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--print-film"), CommandLine.arguments.count > index + 1 {
            try VisualReview.film(to: CommandLine.arguments[index + 1])
            exit(0)
        }
        if CommandLine.arguments.contains("--demo-window") {
            try DemoWindow.run()
        }
#endif
        let model = try MonitorModel()
        // `delegate` is a local, but `app.run()` never returns, so it lives as
        // long as the process. NSApplication.delegate is weak — do not shorten it.
        let delegate = AppDelegate(model: model)
        app.delegate = delegate
        app.run()
    } catch {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "AI Monitor could not start / AI Monitor 无法启动"
        alert.informativeText = "The local database could not be opened:\n\(error)\n\n无法打开本地数据库。"
        alert.addButton(withTitle: "Quit / 退出")
        alert.runModal()
    }
}
