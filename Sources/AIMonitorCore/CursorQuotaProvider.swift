import Foundation
import SQLite3

/// Cursor subscription usage from Cursor.app's own local login plus Cursor's
/// official account usage endpoint.
///
/// The local state database is opened SQLITE_OPEN_READONLY. The access token
/// is kept in memory only, is never refreshed, and is sent only to cursor.com
/// after the caller has explicitly enabled live quota collection.
public struct CursorQuotaProvider: Sendable {
    public static let providerName = "Cursor"
    public static let minimumInterval: TimeInterval = 900

    public enum FetchError: Error, Equatable {
        case credentialsUnavailable
        case tokenExpired
        case databaseUnavailable
        case httpStatus(Int)
        case malformed
    }

    public enum CredentialStatus: Equatable, Sendable {
        case unavailable
        case expired(Date)
        case ready(Date)
    }

    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let stateDatabaseURL: URL
    let dataLoader: DataLoader

    public init(stateDatabaseURL: URL? = nil, dataLoader: DataLoader? = nil) {
        self.stateDatabaseURL = stateDatabaseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        self.dataLoader = dataLoader ?? { try await URLSession.shared.data(for: $0) }
    }

    public func credentialStatus(now: Date = Date()) -> CredentialStatus {
        guard let token = try? readAccessToken() else { return .unavailable }
        guard let expiry = Self.jwtPayload(token)?["exp"] as? NSNumber else { return .unavailable }
        let date = Date(timeIntervalSince1970: expiry.doubleValue)
        return date <= now ? .expired(date) : .ready(date)
    }

    public func fetch() async -> Result<[QuotaWindow], FetchError> {
        let token: String
        do {
            guard let value = try readAccessToken() else { return .failure(.credentialsUnavailable) }
            token = value
        } catch {
            return .failure(.databaseUnavailable)
        }

        guard let cookie = Self.sessionCookie(accessToken: token, now: Date()) else {
            if let expiry = Self.jwtPayload(token)?["exp"] as? NSNumber,
               Date(timeIntervalSince1970: expiry.doubleValue) <= Date() {
                return .failure(.tokenExpired)
            }
            return .failure(.malformed)
        }

        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 10

        let data: Data, response: URLResponse
        do {
            (data, response) = try await dataLoader(request)
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

    /// Produces plan, Auto/Composer, and named-model quota windows only when the
    /// API supplies a real percentage or a usable numerator/denominator.
    static func parseWindows(from root: [String: Any], now: Date) -> [QuotaWindow] {
        let start = Timestamps.parse(root.str("billingCycleStart"))
        let end = Timestamps.parse(root.str("billingCycleEnd"))
        let minutes: Int = {
            guard let start, let end else { return 0 }
            return max(0, Int((end.timeIntervalSince(start) / 60).rounded()))
        }()
        let label = minutes > 0 ? QuotaWindow.label(forWindowMinutes: minutes) : "billing cycle"
        let planType = root.str("membershipType")
        let individual = root.dict("individualUsage")
        let plan = individual?.dict("plan")
        let overall = individual?.dict("overall")
        let pooled = root.dict("teamUsage")?.dict("pooled")

        func clamped(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return min(100, max(0, value))
        }
        func ratio(_ detail: [String: Any]?) -> Double? {
            guard let used = detail?.double("used"),
                  let limit = detail?.double("limit"), limit > 0 else { return nil }
            return clamped(used / limit * 100)
        }

        let total = clamped(plan?.double("totalPercentUsed"))
            ?? ratio(plan) ?? ratio(overall) ?? ratio(pooled)
        let auto = clamped(plan?.double("autoPercentUsed"))
        let api = clamped(plan?.double("apiPercentUsed"))

        return [
            total.map { QuotaWindow(id: "cursor-plan", label: label, usedPercent: $0,
                                    windowMinutes: minutes, resetsAt: end, observedAt: now, planType: planType) },
            auto.map { QuotaWindow(id: "cursor-auto", label: "Auto / Composer", usedPercent: $0,
                                   windowMinutes: minutes, resetsAt: end, observedAt: now, planType: planType) },
            api.map { QuotaWindow(id: "cursor-api", label: "named models", usedPercent: $0,
                                  windowMinutes: minutes, resetsAt: end, observedAt: now, planType: planType) },
        ].compactMap { $0 }
    }

    /// Cursor.app stores a JWT in a VS Code-style SQLite state database.
    /// Read-only open means AIMonitor cannot create a DB, journal, or WAL file.
    private func readAccessToken() throws -> String? {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(stateDatabaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close_v2(db) }
            throw FetchError.databaseUnavailable
        }
        defer { sqlite3_close_v2(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key=?1", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { throw FetchError.databaseUnavailable }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "cursorAuth/accessToken", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { return nil }
        let token = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func sessionCookie(accessToken: String, now: Date) -> String? {
        guard let payload = jwtPayload(accessToken),
              let subject = payload["sub"] as? String,
              let userID = subject.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init),
              !userID.isEmpty,
              userID.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.union(.init(charactersIn: "._-")).contains),
              let expiry = payload["exp"] as? NSNumber,
              Date(timeIntervalSince1970: expiry.doubleValue) > now.addingTimeInterval(60)
        else { return nil }
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)"
    }

    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
