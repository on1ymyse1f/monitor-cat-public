import Foundation
import SQLite3

/// Kimi Code subscription quota via the provider's coding usage endpoint.
///
/// Ground rules, matching SECURITY.md and the Claude quota provider:
///   * **Opt-in only.** Nothing here runs unless the `kimi_quota_optin`
///     setting is "true". Default is off.
///   * **Read-only.** The access token is selected from the CLI's own
///     `~/.kimi-code/credentials/kimi-code.json`, used for one request, and
///     never stored anywhere. The refresh token is not used, so an active CLI
///     session cannot be invalidated.
///   * **Rare.** Callers must respect `minimumInterval` (15 min).
///   * **Honest failure.** This endpoint's response shape is not officially
///     documented. The parser below accepts several shapes and emits only
///     windows it can fully identify (label + percent); anything unrecognized
///     yields `malformed` → the UI shows "unavailable", never a guessed number.
public struct KimiQuotaProvider: Sendable {
    public static let providerName = "Kimi Code"
    public static let minimumInterval: TimeInterval = 900

    public enum FetchError: Error, Equatable {
        case credentialsUnavailable
        case tokenExpired
        case httpStatus(Int)
        case malformed
    }

    public let credentialsURL: URL
    let desktopCookiesURL: URL

    public init(credentialsURL: URL? = nil, desktopCookiesURL: URL? = nil) {
        self.credentialsURL = credentialsURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        self.desktopCookiesURL = desktopCookiesURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kimi-desktop/Cookies")
    }

    /// Selects the access token from the CLI's credential file. Other fields,
    /// including any refresh token, are not selected or used.
    func readAccessToken() -> (token: String, expiresAt: Date?)? {
        guard let data = try? Data(contentsOf: credentialsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty
        else { return nil }
        var expires: Date?
        if let t = json.int("expires_at") { expires = Date(timeIntervalSince1970: TimeInterval(t)) }
        return (token, expires)
    }

    /// Fetches current quota windows. Async; one request; token held in memory
    /// for the duration of the call only.
    public func fetch() async -> Result<[QuotaWindow], FetchError> {
        let codeCredential = readAccessToken()
        let codeIsFresh = codeCredential.map { $0.expiresAt == nil || $0.expiresAt! > Date() } == true
        let desktopToken = readDesktopAuthToken()

        let resolvedRequest: URLRequest
        let isWeb: Bool
        if let (token, _) = codeCredential, codeIsFresh {
            var value = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/usages")!)
            value.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            value.setValue("kimi-code", forHTTPHeaderField: "User-Agent")
            resolvedRequest = value
            isWeb = false
        } else if let token = desktopToken {
            var value = URLRequest(url: URL(string:
                "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!)
            value.httpMethod = "POST"
            value.httpBody = try? JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])
            value.setValue("application/json", forHTTPHeaderField: "Content-Type")
            value.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            value.setValue("kimi-auth=\(token)", forHTTPHeaderField: "Cookie")
            value.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
            value.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
            value.setValue("1", forHTTPHeaderField: "connect-protocol-version")
            resolvedRequest = value
            isWeb = true
        } else {
            return codeCredential?.expiresAt.map { $0 <= Date() } == true
                ? .failure(.tokenExpired) : .failure(.credentialsUnavailable)
        }
        var request = resolvedRequest
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
        let normalized = Self.normalizedResponse(root, isWeb: isWeb)
        let windows = Self.parseWindows(from: normalized, now: Date())
        return windows.isEmpty ? .failure(.malformed) : .success(windows)
    }

    /// Kimi Desktop currently stores `kimi-auth` as plaintext in its Chromium
    /// Cookies DB. Open it read-only; encrypted or absent values are simply not
    /// available, never decrypted by reaching into the browser Keychain.
    func readDesktopAuthToken() -> String? {
        guard FileManager.default.isReadableFile(atPath: desktopCookiesURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(desktopCookiesURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if db != nil { sqlite3_close_v2(db) }
            return nil
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 250)
        var stmt: OpaquePointer?
        let sql = """
            SELECT value FROM cookies
            WHERE name='kimi-auth' AND host_key IN ('www.kimi.com','.www.kimi.com','.kimi.com','kimi.com')
            ORDER BY last_access_utc DESC LIMIT 1
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { return nil }
        let token = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func normalizedResponse(_ root: [String: Any], isWeb: Bool) -> [String: Any] {
        guard isWeb,
              let usages = root["usages"] as? [[String: Any]],
              let coding = usages.first(where: { $0.str("scope") == "FEATURE_CODING" }),
              let detail = coding.dict("detail")
        else { return root }
        var normalized: [String: Any] = ["usage": detail]
        if let limits = coding["limits"] as? [[String: Any]] { normalized["limits"] = limits }
        return normalized
    }

    /// Parses the endpoint's response.
    ///
    /// The shape was captured from a live 200 response rather than guessed, and
    /// cross-checked against what `kimi`'s own TUI printed at the same moment
    /// (5-hour: 2% used, resets in ~35m; plan: resets in 6d 9h):
    ///
    /// ```json
    /// { "limits": [ { "detail": { "limit": 100, "remaining": 98, "used": 2,
    ///                             "resetTime": "2026-08-18T04:22:54.677068Z" },
    ///                 "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" } } ],
    ///   "usage":  { "limit": 100, "remaining": 99, "used": 1,
    ///               "resetTime": "2026-08-24T13:22:54.677068Z" },
    ///   "subType": "TYPE_PURCHASE" }
    /// ```
    ///
    /// Two families:
    ///   * `limits[]` — rolling windows that **describe themselves**
    ///     (`window.duration` + `window.timeUnit`), so the label is derived,
    ///     never assumed.
    ///   * `usage` — the plan-period quota. It carries a reset time but **no
    ///     period**, so nothing here computes one; the reset instant is taken
    ///     verbatim and the label mirrors the vocabulary Kimi's own client uses
    ///     for this same field ("weekly limit").
    ///
    /// A window without both a usable count and a limit is skipped rather than
    /// emitted at zero.
    static func parseWindows(from root: [String: Any], now: Date) -> [QuotaWindow] {
        let container = root.dict("data") ?? root
        let planType = container.str("subType")
        var windows: [QuotaWindow] = []

        if let limits = container["limits"] as? [[String: Any]] {
            for entry in limits {
                guard let detail = entry.dict("detail"),
                      let percent = percentUsed(detail) else { continue }
                let minutes = entry.dict("window").flatMap(windowMinutes(from:)) ?? 0
                windows.append(QuotaWindow(
                    id: "kimi-window-\(minutes)",
                    label: minutes > 0 ? QuotaWindow.label(forWindowMinutes: minutes) : "window",
                    usedPercent: percent,
                    windowMinutes: minutes,
                    resetsAt: Timestamps.parse(detail.str("resetTime")),
                    observedAt: now,
                    planType: planType
                ))
            }
        }

        if let usage = container.dict("usage"), let percent = percentUsed(usage) {
            windows.append(QuotaWindow(
                id: "kimi-plan",
                label: "weekly",
                usedPercent: percent,
                windowMinutes: 10080,
                resetsAt: Timestamps.parse(usage.str("resetTime")),
                observedAt: now,
                planType: planType
            ))
        }

        return windows
    }

    /// `used` against `limit`, as a percentage. Kimi sometimes omits `used`
    /// while still returning the authoritative `remaining`; that shape is
    /// recovered as `limit - remaining`. A missing denominator is still never
    /// turned into a number.
    static func percentUsed(_ detail: [String: Any]) -> Double? {
        guard let limit = detail.double("limit"), limit > 0 else { return nil }
        if let used = detail.double("used"), used >= 0 {
            return min(100, max(0, used / limit * 100))
        }
        if let remaining = detail.double("remaining"), (0...limit).contains(remaining) {
            return (limit - remaining) / limit * 100
        }
        return nil
    }

    /// `{duration, timeUnit}` → minutes. An unrecognized unit yields nil rather
    /// than a number in the wrong scale.
    static func windowMinutes(from window: [String: Any]) -> Int? {
        guard let duration = window.int("duration") else { return nil }
        switch window.str("timeUnit") {
        case "TIME_UNIT_MINUTE": return duration
        case "TIME_UNIT_HOUR": return duration * 60
        case "TIME_UNIT_DAY": return duration * 1440
        case "TIME_UNIT_SECOND": return duration / 60
        default: return nil
        }
    }
}

// MARK: - Credential freshness

extension KimiQuotaProvider {
    /// What the credential file says about the token, without ever returning
    /// the token itself.
    ///
    /// This exists because of a timing trap that made Kimi quota look broken.
    /// The CLI's access token carries `expires_in: 900` — it lives **fifteen
    /// minutes** — and the app's fetch was on its own fifteen-minute timer.
    /// Two unsynchronised fifteen-minute cycles means the fetch almost always
    /// lands on a token that has already died, so the quota that had been
    /// collected fine while Kimi was running simply stopped appearing.
    ///
    /// Kimi is also the one provider whose quota cannot be read any other way:
    /// unlike Codex, the collector does not extract quota from its usage logs,
    /// so there is no credential-free log path to fall back to. The provider
    /// fetches when the CLI has just refreshed the token — which is exactly
    /// when the user is running Kimi and the number is worth having.
    public enum CredentialState: Sendable, Equatable {
        case absent
        /// Present but past its expiry. Fetching would spend a request to be
        /// told what the file already says.
        case expired(since: Date)
        /// Usable. `issuedHint` is the file's modification time, which moves
        /// every time the CLI writes a fresh token.
        case valid(expiresAt: Date, issuedHint: Date)

        public var isUsable: Bool {
            if case .valid = self { return true }
            return false
        }
    }

    public func credentialState(now: Date = Date()) -> CredentialState {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: credentialsURL.path),
              let mtime = attrs[.modificationDate] as? Date
        else { return .absent }
        guard let (_, expiresAt) = readAccessToken() else { return .absent }
        guard let expiresAt else {
            // No expiry stated: treat the file's own age as the clock, using
            // the observed 15-minute lifetime rather than assuming it is good
            // forever.
            return now.timeIntervalSince(mtime) < 900
                ? .valid(expiresAt: mtime.addingTimeInterval(900), issuedHint: mtime)
                : .expired(since: mtime.addingTimeInterval(900))
        }
        return expiresAt > now
            ? .valid(expiresAt: expiresAt, issuedHint: mtime)
            : .expired(since: expiresAt)
    }
}
