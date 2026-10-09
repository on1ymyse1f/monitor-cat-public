import Foundation

/// Claude subscription quota via the official (undocumented) usage endpoint —
/// the same one Claude Code's own /usage UI reads.
///
/// Ground rules, matching SECURITY.md:
///   * **Opt-in only.** Nothing here runs unless the `claude_quota_optin`
///     setting is "true". Default is off.
///   * **Read-only.** The OAuth access token is read from the user's own
///     Keychain (item "Claude Code-credentials"), used for one GET, and never
///     stored anywhere. The refresh token is never touched, so an active CLI
///     session cannot be invalidated.
///   * **Rare.** The endpoint is rate-limited independently; callers must
///     respect `minimumInterval` (15 min) between fetches.
///   * **Honest failure.** Expired token, network error, 429 — all produce
///     `unavailable` with a reason, never a stale number presented as fresh.
public struct ClaudeQuotaProvider: Sendable {
    public static let providerName = "Claude"
    public static let minimumInterval: TimeInterval = 900

    public enum FetchError: Error, Equatable {
        case keychainUnavailable
        case tokenExpired
        case httpStatus(Int)
        case malformed
    }

    public init() {}

    /// Reads the Claude Code OAuth access token from the login keychain.
    /// Uses the `security` CLI rather than SecItem APIs: the CLI respects the
    /// user's Keychain prompt ("allow once / always") without embedding an
    /// entitlement dance into an unsigned SPM binary.
    func readAccessToken() -> (token: String, expiresAt: Date?)? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double { expires = Date(timeIntervalSince1970: ms / 1000) }
        return (token, expires)
    }

    /// Fetches current quota windows. Async; one request; token held in memory
    /// for the duration of the call only.
    public func fetch() async -> Result<[QuotaWindow], FetchError> {
        guard let (token, expiresAt) = readAccessToken() else { return .failure(.keychainUnavailable) }
        if let expiresAt, expiresAt < Date() { return .failure(.tokenExpired) }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Without the claude-code UA the endpoint serves an aggressively
        // rate-limited bucket (persistent 429s) — documented community finding.
        request.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.malformed)
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.malformed) }
        guard http.statusCode == 200 else { return .failure(.httpStatus(http.statusCode)) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.malformed)
        }
        let windows = Self.parseWindows(from: root, now: Date())
        return windows.isEmpty ? .failure(.malformed) : .success(windows)
    }

    /// Parses the endpoint's response. Any window may be null or absent
    /// depending on the plan — emit only what's actually present.
    static func parseWindows(from root: [String: Any], now: Date) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        for (key, label, minutes) in [
            ("five_hour", "5h", 300),
            ("seven_day", "weekly", 10080),
            ("seven_day_opus", "weekly · Opus", 10080),
            ("seven_day_sonnet", "weekly · Sonnet", 10080),
        ] {
            guard let w = root[key] as? [String: Any],
                  let utilization = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
            var resets: Date?
            if let s = w["resets_at"] as? String { resets = Timestamps.parse(s) }
            windows.append(QuotaWindow(
                id: "claude-\(key)", label: label, usedPercent: utilization,
                windowMinutes: minutes, resetsAt: resets, observedAt: now, planType: "oauth"
            ))
        }
        return windows
    }
}
