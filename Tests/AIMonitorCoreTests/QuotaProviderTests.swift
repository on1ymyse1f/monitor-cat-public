import XCTest
@testable import AIMonitorCore

// MARK: - Claude quota endpoint parsing + localization

final class ClaudeQuotaProviderTests: XCTestCase {

    /// The documented response shape: every window present.
    func testParsesAllWindows() {
        let json: [String: Any] = [
            "five_hour": ["utilization": 33.0, "resets_at": "2026-08-18T07:00:00.528743+00:00"],
            "seven_day": ["utilization": 13.0, "resets_at": "2026-08-24T00:59:59.951713+00:00"],
            "seven_day_opus": NSNull(),
            "seven_day_sonnet": ["utilization": 1.0, "resets_at": "2026-08-23T03:00:00.951719+00:00"],
            "extra_usage": ["is_enabled": false],
        ]
        let windows = ClaudeQuotaProvider.parseWindows(from: json, now: Date())
        XCTAssertEqual(windows.map(\.id), ["claude-five_hour", "claude-seven_day", "claude-seven_day_sonnet"],
                       "null windows (seven_day_opus) must be absent, not 0%")
        XCTAssertEqual(windows[0].usedPercent, 33)
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertEqual(windows[0].windowMinutes, 300)
        XCTAssertEqual(windows[1].windowMinutes, 10080)
    }

    /// Plans that expose only the 5-hour window: emit exactly that one.
    func testMissingWindowsAreAbsentNotZero() {
        let json: [String: Any] = [
            "five_hour": ["utilization": 4.0, "resets_at": "2026-08-18T11:00:00+00:00"],
        ]
        let windows = ClaudeQuotaProvider.parseWindows(from: json, now: Date())
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].id, "claude-five_hour")
    }

    func testEmptyResponseYieldsNoWindows() {
        XCTAssertTrue(ClaudeQuotaProvider.parseWindows(from: [:], now: Date()).isEmpty)
    }
}

final class L10nTests: XCTestCase {

    func testEveryKeyHasBothLanguages() {
        for key in L10n.Key.allCases {
            let en = L10n.text(key, .en)
            let zh = L10n.text(key, .zh)
            XCTAssertFalse(en.isEmpty, "\(key) missing English")
            XCTAssertFalse(zh.isEmpty, "\(key) missing Chinese")
        }
    }

    func testSystemResolves() {
        XCTAssertNotEqual(Language.system.resolved, .system, "system must resolve to a concrete language")
    }

    func testResetDescriptionLocalized() {
        let soon = Date().addingTimeInterval(2 * 3600 + 14 * 60)
        XCTAssertTrue(StoreReport.resetDescription(soon, lang: .en).contains("resets in"))
        XCTAssertTrue(StoreReport.resetDescription(soon, lang: .zh).contains("后重置"))
        XCTAssertEqual(StoreReport.resetDescription(nil, lang: .zh), "重置时间未知")
    }
}

// MARK: - Claude desktop local usage cache

final class ClaudeDesktopQuotaTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-usage-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The shape verified against the real file: newest sample wins, `fh` is the
    /// 5-hour window and `sd` the weekly one.
    func testReadsNewestSampleAsWindows() throws {
        let now = Date()
        let older = (now.timeIntervalSince1970 - 900) * 1000
        let newest = now.timeIntervalSince1970 * 1000
        let url = try write("""
        {"version":2,"samples":[
          {"t":\(older),"org":"o","u":{"fh":37,"sd":4}},
          {"t":\(newest),"org":"o","u":{"fh":46,"sd":5,"xu":69.3}}
        ]}
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .success(let windows) = ClaudeDesktopQuota(fileURL: url).read(now: now) else {
            return XCTFail("expected windows")
        }
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.first { $0.label == "5h" }?.usedPercent, 46)
        XCTAssertEqual(windows.first { $0.label == "weekly" }?.usedPercent, 5)
    }

    /// `xu` is the dollar-credit meter, not a rate-limit window. Emitting it as
    /// a quota would put a spend percentage on the same board as time windows.
    func testCreditMeterIsNotEmittedAsAQuota() throws {
        let now = Date()
        let url = try write("""
        {"version":2,"samples":[{"t":\(now.timeIntervalSince1970 * 1000),"org":"o","u":{"fh":10,"sd":2,"xu":69.3}}]}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .success(let windows) = ClaudeDesktopQuota(fileURL: url).read(now: now) else {
            return XCTFail("expected windows")
        }
        XCTAssertFalse(windows.contains { $0.usedPercent == 69.3 })
    }

    /// A sample from before the window rolled over must not pose as "now".
    func testStaleSampleIsRejectedRatherThanShownAsLive() throws {
        let now = Date()
        let old = (now.timeIntervalSince1970 - 48 * 3600) * 1000
        let url = try write("""
        {"version":2,"samples":[{"t":\(old),"org":"o","u":{"fh":99,"sd":80}}]}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .failure(let e) = ClaudeDesktopQuota(fileURL: url).read(now: now) else {
            return XCTFail("expected staleness rejection")
        }
        guard case .stale = e else { return XCTFail("expected .stale, got \(e)") }
    }

    /// No desktop app installed is a normal state, not a corrupted one.
    func testAbsentFileReportsAbsence() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("definitely-missing.json")
        guard case .failure(.fileAbsent) = ClaudeDesktopQuota(fileURL: url).read() else {
            return XCTFail("expected .fileAbsent")
        }
    }

    /// The file carries no reset timestamps; this project never invents one.
    func testResetTimeIsAbsentNotGuessed() throws {
        let now = Date()
        let url = try write("""
        {"version":2,"samples":[{"t":\(now.timeIntervalSince1970 * 1000),"org":"o","u":{"fh":46,"sd":5}}]}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .success(let windows) = ClaudeDesktopQuota(fileURL: url).read(now: now) else {
            return XCTFail("expected windows")
        }
        XCTAssertTrue(windows.allSatisfy { $0.resetsAt == nil })
    }
}

// MARK: - Kimi usage endpoint (shape captured from a live 200 response)

final class KimiQuotaShapeTests: XCTestCase {
    /// Verbatim structure of a real response, cross-checked against what the
    /// Kimi TUI displayed at the same moment.
    private let live: [String: Any] = [
        "subType": "TYPE_PURCHASE",
        "limits": [[
            "detail": ["limit": 100, "remaining": 98, "used": 2,
                       "resetTime": "2026-08-18T04:22:54.677068Z"],
            "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
        ]],
        "usage": ["limit": 100, "remaining": 99, "used": 1,
                  "resetTime": "2026-08-24T13:22:54.677068Z"],
    ]

    func testParsesRollingWindowAndPlanWindow() {
        let w = KimiQuotaProvider.parseWindows(from: live, now: Date())
        XCTAssertEqual(w.count, 2)

        let fiveHour = w.first { $0.label == "5h" }
        XCTAssertEqual(fiveHour?.usedPercent, 2)
        XCTAssertEqual(fiveHour?.windowMinutes, 300)
        XCTAssertEqual(fiveHour?.planType, "TYPE_PURCHASE")

        let plan = w.first { $0.label == "weekly" }
        XCTAssertEqual(plan?.usedPercent, 1)
    }

    /// The window label comes from `window.duration`, not from a hardcoded
    /// assumption that the first entry is the 5-hour one.
    func testWindowLabelIsDerivedFromItsOwnDuration() {
        let root: [String: Any] = ["limits": [[
            "detail": ["limit": 200, "used": 50],
            "window": ["duration": 24, "timeUnit": "TIME_UNIT_HOUR"],
        ]]]
        let w = KimiQuotaProvider.parseWindows(from: root, now: Date())
        XCTAssertEqual(w.first?.label, "daily")
        XCTAssertEqual(w.first?.windowMinutes, 1440)
        XCTAssertEqual(w.first?.usedPercent, 25)
    }

    /// Reset instants are taken verbatim, including 6-digit fractional seconds.
    func testResetTimeParsesMicrosecondPrecision() {
        let w = KimiQuotaProvider.parseWindows(from: live, now: Date())
        let plan = w.first { $0.label == "weekly" }
        XCTAssertEqual(plan?.resetsAt, Timestamps.parse("2026-08-24T13:22:54.677068Z"))
        XCTAssertNotNil(plan?.resetsAt)
    }

    /// A limit of zero would make the percentage meaningless, so the window is
    /// dropped rather than reported as 0% used.
    func testWindowWithoutUsableLimitIsSkippedNotZeroed() {
        let root: [String: Any] = [
            "limits": [["detail": ["limit": 0, "used": 5],
                        "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"]]],
            "usage": ["used": 3],
        ]
        XCTAssertTrue(KimiQuotaProvider.parseWindows(from: root, now: Date()).isEmpty)
    }

    func testRemainingRecoversOmittedUsedIncludingRealZeroPercent() {
        let root: [String: Any] = ["limits": [[
            "detail": ["limit": "200", "remaining": "200"],
            "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
        ]]]
        let windows = KimiQuotaProvider.parseWindows(from: root, now: Date())
        XCTAssertEqual(windows.first?.usedPercent, 0)
    }

    func testKimiDesktopWebResponseSelectsCodingScope() {
        let root: [String: Any] = ["usages": [
            ["scope": "FEATURE_CHAT", "detail": ["limit": 1, "used": 1]],
            ["scope": "FEATURE_CODING",
             "detail": ["limit": "2048", "used": "214"],
             "limits": [["window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                         "detail": ["limit": "200", "remaining": "61"]]]],
        ]]
        let normalized = KimiQuotaProvider.normalizedResponse(root, isWeb: true)
        let windows = KimiQuotaProvider.parseWindows(from: normalized, now: Date())
        XCTAssertEqual(try XCTUnwrap(windows.first { $0.label == "weekly" }?.usedPercent),
                       214.0 / 2048.0 * 100, accuracy: 0.0001)
        XCTAssertEqual(windows.first { $0.label == "5h" }?.usedPercent, 69.5)
    }

    /// An unfamiliar time unit must not be silently treated as minutes.
    func testUnknownTimeUnitDoesNotFabricateAScale() {
        XCTAssertNil(KimiQuotaProvider.windowMinutes(from: ["duration": 5, "timeUnit": "TIME_UNIT_FORTNIGHT"]))
    }
}

// MARK: - Cursor local auth + official usage summary

final class CursorQuotaProviderTests: XCTestCase {
    func testParsesRealUsageSummaryFields() {
        let root: [String: Any] = [
            "billingCycleStart": "2026-08-01T00:00:00Z",
            "billingCycleEnd": "2026-09-01T00:00:00Z",
            "membershipType": "pro",
            "individualUsage": ["plan": [
                "used": 2500, "limit": 10000,
                "totalPercentUsed": 25.0,
                "autoPercentUsed": 12.5,
                "apiPercentUsed": 37.5,
            ]],
        ]
        let windows = CursorQuotaProvider.parseWindows(from: root, now: Date())
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.first { $0.id == "cursor-plan" }?.usedPercent, 25)
        XCTAssertEqual(windows.first { $0.id == "cursor-auto" }?.usedPercent, 12.5)
        XCTAssertEqual(windows.first { $0.id == "cursor-api" }?.usedPercent, 37.5)
        XCTAssertEqual(windows.first?.planType, "pro")
    }

    func testFallsBackToRealUsedLimitRatio() {
        let root: [String: Any] = [
            "individualUsage": ["overall": ["used": 7384, "limit": 10000]],
        ]
        let windows = CursorQuotaProvider.parseWindows(from: root, now: Date())
        XCTAssertEqual(try XCTUnwrap(windows.first?.usedPercent), 73.84, accuracy: 0.0001)
    }

    func testJWTBecomesCursorSessionCookieWithoutLeakingPayload() throws {
        func b64url(_ object: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try "x.\(b64url(["sub": "auth0|user_123", "exp": 1_800_003_600])).sig"
        let cookie = try XCTUnwrap(CursorQuotaProvider.sessionCookie(accessToken: token, now: now))
        XCTAssertTrue(cookie.hasPrefix("WorkosCursorSessionToken=user_123%3A%3A"))
        XCTAssertTrue(cookie.hasSuffix(token))
    }
}

// MARK: - Quota staleness scaled to the window

/// "AI Monitor shows Claude's limit when Claude isn't open" is this: the
/// desktop app's cache file survives the app quitting, and the last sample in
/// it was being presented as the current number.
final class QuotaStalenessTests: XCTestCase {

    private func window(_ minutes: Int, ageHours: Double, percent: Double = 40) -> QuotaWindow {
        QuotaWindow(
            id: "w", label: QuotaWindow.label(forWindowMinutes: minutes),
            usedPercent: percent, windowMinutes: minutes, resetsAt: nil,
            observedAt: Date().addingTimeInterval(-ageHours * 3600), planType: "desktop"
        )
    }

    /// The core rule: how long a reading stays meaningful is a fraction of the
    /// window it is a percentage of, not a constant.
    func testFreshnessScalesWithTheWindow() {
        // 5-hour window: 5% of 5h is 15 minutes.
        XCTAssertEqual(window(300, ageHours: 0.2).staleness(), .live)
        if case .aging = window(300, ageHours: 1).staleness() {} else {
            XCTFail("an hour into a five-hour window is aging, not live")
        }
        if case .expired = window(300, ageHours: 3).staleness() {} else {
            XCTFail("three hours into a five-hour window has substantially rolled")
        }

        // Weekly: the same three hours is nothing at all.
        XCTAssertEqual(window(10080, ageHours: 3).staleness(), .live)
        if case .aging = window(10080, ageHours: 24).staleness() {} else {
            XCTFail("a day into a weekly window is aging")
        }
    }

    /// The regression, stated directly: six hours used to pass, and six hours
    /// is longer than the window itself.
    func testAReadingOlderThanItsOwnWindowIsNeverLive() {
        for hours in [5.5, 8.0, 24.0] {
            guard case .expired = window(300, ageHours: hours).staleness() else {
                return XCTFail("\(hours)h-old five-hour reading must not be presentable")
            }
        }
    }

    /// One sample carries both windows, and they do not age together: after
    /// three hours the weekly figure is still good and the 5-hour one is not.
    func testStaleFiveHourWindowIsDroppedWhileWeeklySurvives() throws {
        let dir = TempDir()
        let threeHoursAgo = Int(Date().addingTimeInterval(-3 * 3600).timeIntervalSince1970 * 1000)
        let file = dir.write([
            "{\"version\":2,\"samples\":[{\"t\":\(threeHoursAgo),\"org\":\"o\",\"u\":{\"fh\":46,\"sd\":5}}]}"
        ], to: "plan-usage-history.json")

        let result = ClaudeDesktopQuota(fileURL: file).read()
        guard case .success(let windows) = result else {
            return XCTFail("the weekly figure is still good — the read must not fail wholesale")
        }
        XCTAssertEqual(windows.map(\.label), ["weekly"],
                       "the five-hour window has rolled over; only the weekly one survives")
    }

    /// A fresh sample still yields both, unchanged.
    func testAFreshSampleYieldsBothWindows() throws {
        let dir = TempDir()
        let justNow = Int(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        let file = dir.write([
            "{\"version\":2,\"samples\":[{\"t\":\(justNow),\"org\":\"o\",\"u\":{\"fh\":46,\"sd\":5}}]}"
        ], to: "plan-usage-history.json")

        guard case .success(let windows) = ClaudeDesktopQuota(fileURL: file).read() else {
            return XCTFail("a one-minute-old sample must read cleanly")
        }
        XCTAssertEqual(Set(windows.map(\.label)), ["5h", "weekly"])
        XCTAssertEqual(windows.first(where: { $0.label == "5h" })?.usedPercent, 46)
    }

    /// With Claude closed for a day, nothing at all is presentable — the card
    /// must go to "unavailable", not to a frozen percentage.
    func testAllWindowsExpireWhenTheAppHasBeenClosedForADay() throws {
        let dir = TempDir()
        let longAgo = Int(Date().addingTimeInterval(-3 * 86_400).timeIntervalSince1970 * 1000)
        let file = dir.write([
            "{\"version\":2,\"samples\":[{\"t\":\(longAgo),\"org\":\"o\",\"u\":{\"fh\":46,\"sd\":5}}]}"
        ], to: "plan-usage-history.json")

        guard case .failure(let error) = ClaudeDesktopQuota(fileURL: file).read() else {
            return XCTFail("a three-day-old sample is not the current quota")
        }
        guard case .stale = error else { return XCTFail("expected .stale, got \(error)") }
    }
}

// MARK: - The kitten's state machine

/// Twenty-four drawings are only worth having if each one means something, so
/// every pose has to be reachable from a state the app can observe — and the
/// urgent ones have to outrank the cosy ones.
final class MascotStateTests: XCTestCase {

    private func cast(_ s: MascotState.Situation) -> (mood: MascotState.Mood, says: String?) {
        MascotState.cast(for: s, lang: .en)
    }

    /// A quota about to run out is the one state that needs the reader to look
    /// up, so it outranks everything — including a live session.
    func testCriticalQuotaOutranksEverythingElse() {
        let angry = cast(MascotState.Situation(
            isLive: true, quotaRemaining: 4, storeEmpty: true, todayTokens: 5_000, newlyUnpriced: true
        ))
        XCTAssertEqual(angry.mood, .angry)
        XCTAssertEqual(angry.says, MascotState.Line.critical.text(.en))
    }

    /// How long it has been quiet decides how deeply asleep the cat is. This is
    /// the ladder that makes idleness legible at a glance.
    func testIdleLadderDeepensWithTime() {
        func mood(idleMinutes: Double) -> MascotState.Mood {
            cast(MascotState.Situation(todayTokens: 1_000, idleFor: idleMinutes * 60)).mood
        }
        XCTAssertEqual(mood(idleMinutes: 5), .wash, "just paused — still fussing about")
        XCTAssertEqual(mood(idleMinutes: 30), .curl)
        XCTAssertEqual(mood(idleMinutes: 3 * 60), .sleep)
        XCTAssertEqual(mood(idleMinutes: 10 * 60), .bed, "overnight")
    }

    func testLiveSessionGetsAWorkingPose() {
        let working = cast(MascotState.Situation(isLive: true, todayTokens: 12_345))
        XCTAssertEqual(working.mood, .stalk)
        XCTAssertEqual(working.says, MascotState.Line.working.text(.en))
    }

    /// The two "I cannot see it" states are distinct: no fresh quota reading is
    /// not the same problem as a model with no rate.
    func testBlindAndPuzzledAreDifferentStates() {
        XCTAssertEqual(cast(MascotState.Situation(quotaBlind: true)).mood, .peek)
        XCTAssertEqual(cast(MascotState.Situation(todayTokens: 1, newlyUnpriced: true)).mood, .puzzled)
    }

    func testEmptyStoreIsTheBoxCat() {
        XCTAssertEqual(cast(MascotState.Situation(storeEmpty: true)).mood, .box)
    }

    /// Pose and line are chosen together, so a sleeping cat can never be made
    /// to say it is counting.
    func testASleepingCatNeverClaimsToBeWorking() {
        for idle: TimeInterval in [20 * 60, 3 * 3600, 12 * 3600] {
            let c = cast(MascotState.Situation(todayTokens: 500, idleFor: idle))
            XCTAssertEqual(c.says, MascotState.Line.napping.text(.en), "idle \(idle)s")
            XCTAssertNotEqual(c.says, MascotState.Line.working.text(.en))
        }
    }

    /// Each drawing has to be reachable, or it is an asset nobody ever sees.
    func testEveryMoodHasAMotionAndACycle() {
        for mood in MascotState.Mood.allCases {
            XCTAssertGreaterThan(mood.cycle, 0, "\(mood.rawValue) has no cycle")
            XCTAssertTrue(mood.rawValue.hasPrefix("mascot-"), "\(mood.rawValue) is not an asset name")
        }
        XCTAssertEqual(MascotState.Mood.allCases.count, 24)
    }

    /// The motion is a loop: phase 0 and phase 1 are the same drawing, or the
    /// cat jumps once per cycle.
    func testEveryMotionLoopsCleanly() {
        for mood in MascotState.Mood.allCases {
            let start = MascotState.pose(for: mood.motion, phase: 0)
            let end = MascotState.pose(for: mood.motion, phase: 1)
            XCTAssertEqual(start.breathe, end.breathe, accuracy: 1e-9, "\(mood.rawValue) breathe jumps")
            XCTAssertEqual(start.bounce, end.bounce, accuracy: 1e-9, "\(mood.rawValue) bounce jumps")
            XCTAssertEqual(start.sway, end.sway, accuracy: 1e-9, "\(mood.rawValue) sway jumps")
        }
    }

    /// Each archetype has to actually move, and stay within a range that reads
    /// as a drawing breathing rather than a UI element animating.
    func testMotionAmplitudesAreAliveButRestrained() {
        for mood in MascotState.Mood.allCases {
            let samples = stride(from: 0.0, to: 1.0, by: 0.02)
                .map { MascotState.pose(for: mood.motion, phase: $0) }
            let breatheRange = samples.map(\.breathe)
            let travel = samples.map { abs($0.bounce) + abs($0.sway) }.max() ?? 0
            let tremble = samples.map { abs($0.tremble) }.max() ?? 0

            XCTAssertGreaterThan(
                (breatheRange.max()! - breatheRange.min()!) + travel + tremble, 0.01,
                "\(mood.rawValue) does not move at all"
            )
            XCTAssertLessThan(breatheRange.max()!, 1.06, "\(mood.rawValue) breathes too hard")
            XCTAssertLessThan(travel, 6, "\(mood.rawValue) travels too far for a page mascot")
            XCTAssertLessThan(tremble, 4, "\(mood.rawValue) shakes too hard")
        }
    }
}

// MARK: - Background agent

/// The agent plist is a file launchd *executes*, so nothing that goes into it
/// may be able to escape its own field.
final class BackgroundAgentTests: XCTestCase {

    /// The regression: these values are all filesystem paths, and a path may
    /// legitimately contain XML metacharacters. Templating them into an XML
    /// string produced malformed plists at best and injected launchd keys at
    /// worst.
    func testHostilePathsCannotEscapeTheirField() throws {
        let nasty = "/Users/a&b/</string><key>RunAtLoad</key><false/><string>/x"
        let text = try BackgroundAgent.plist(executable: nasty, dbPath: nasty, everySeconds: 300)

        // It round-trips as a plist, and the value comes back intact...
        let parsed = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(text.utf8), options: [], format: nil
        ) as? [String: Any])
        let argv = try XCTUnwrap(parsed["ProgramArguments"] as? [String])
        XCTAssertEqual(argv, [nasty, "--sync", nasty], "the path must survive verbatim")

        // ...and the key the payload tried to smuggle in did not appear.
        XCTAssertEqual(parsed["RunAtLoad"] as? Bool, true, "an injected RunAtLoad=false must not win")
        XCTAssertEqual(parsed["Label"] as? String, BackgroundAgent.label)
    }

    /// The agent must only ever run this tool's own sync — never a shell, and
    /// never with a command it was handed.
    func testTheAgentOnlyRunsTheSyncSubcommand() throws {
        let config = BackgroundAgent.configuration(
            executable: "/usr/local/bin/aimonitor", dbPath: "/tmp/x.db", everySeconds: 300
        )
        let argv = try XCTUnwrap(config["ProgramArguments"] as? [String])
        XCTAssertEqual(argv.count, 3)
        XCTAssertEqual(argv[1], "--sync")
        XCTAssertFalse(argv[0].contains("sh"), "never a shell")
        XCTAssertNil(config["EnvironmentVariables"], "no environment is injected")
    }

    /// A too-eager interval is a battery complaint, not a feature.
    func testIntervalIsCarriedAsAnIntegerNotAString() throws {
        let config = BackgroundAgent.configuration(executable: "/x", dbPath: "/y", everySeconds: 300)
        XCTAssertEqual(config["StartInterval"] as? Int, 300)
    }
}

// MARK: - Self-audit

/// The audit exists so a sceptical reader can check the claims instead of
/// trusting them. That only works if it is quiet when things are right and
/// loud when they are not — a warning that is always on is furniture.
final class SelfAuditTests: XCTestCase {

    private func store(_ dir: TempDir) throws -> (EventStore, String) {
        let path = dir.url.appendingPathComponent("store.db").path
        return (try EventStore(path: path), path)
    }

    private func add(_ store: EventStore, id: String, model: String?, project: String?) throws {
        try store.insert(usage: AIEvent(
            id: id, timestamp: Date(), provider: "Claude Code", application: "Claude Code",
            model: model, sessionId: UUID().uuidString, project: project,
            tokens: TokenBreakdown(output: 10), costUSD: nil, confidence: .estimated
        ), keepLargest: false)
    }

    /// The regression this check had on its first run: `provider` holds
    /// "Claude Code", `application` holds "Claude Code" — fixed labels that
    /// contain a space. A naive "does it contain a space" test would classify
    /// fixed labels as prose.
    func testFixedLabelsWithSpacesAreNotMistakenForProse() throws {
        let dir = TempDir()
        let (store, path) = try self.store(dir)
        for i in 0..<50 { try add(store, id: "req_\(i)", model: "claude-opus-5", project: "my-project") }

        let shape = try store.textColumnShape()
        let provider = try XCTUnwrap(shape.first { $0.column == "provider" })
        XCTAssertTrue(provider.isVocabulary, "three fixed labels is a vocabulary, not free text")

        let report = SelfAudit.run(storePath: path)
        XCTAssertEqual(report.warnings, 0, "a clean store must produce no warnings")
        XCTAssertTrue(report.findings.contains {
            $0.title.contains("no prompt or response text") && $0.verdict == .pass
        })
    }

    /// And it must still catch the thing it is for.
    func testProseInAFreeTextColumnIsCaught() throws {
        let dir = TempDir()
        let (store, path) = try self.store(dir)
        // A model field carrying a sentence is exactly the leak this guards.
        let sentence = "Please refactor the authentication module and explain "
            + "each change you make in detail so the team can review it properly."
        for i in 0..<40 { try add(store, id: "req_\(i)", model: "\(sentence) \(i)", project: "p") }

        let report = SelfAudit.run(storePath: path)
        XCTAssertGreaterThan(report.warnings, 0, "prose in a free-text column must warn")
        XCTAssertTrue(report.findings.contains {
            $0.title.contains("no prompt or response text") && $0.verdict == .warn
        })
    }

    /// A store other accounts can read is the finding that matters most, and it
    /// has to be derived from the file, not from a flag.
    func testLoosePermissionsAreReported() throws {
        let dir = TempDir()
        let (_, path) = try self.store(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)

        let report = SelfAudit.run(storePath: path)
        XCTAssertTrue(report.findings.contains {
            $0.title.contains("owner-only") && $0.verdict == .warn
        }, "a 0644 store must be called out")
    }

    /// The audit itself must not need anything: no network, no Keychain, no
    /// elevated permission. It runs against a path and reads files.
    func testAuditRunsOnAStoreThatDoesNotExist() {
        let report = SelfAudit.run(storePath: "/nonexistent/store.db")
        XCTAssertFalse(report.findings.isEmpty, "it still reports what it can")
        XCTAssertTrue(report.findings.contains { $0.title.contains("no elevated permissions") })
    }
}

// MARK: - Every drawing has a home

/// Twenty-four drawings are only worth shipping if each one is reachable. A
/// pose nobody can ever see is an asset that rots: it survives refactors
/// unnoticed and misleads whoever reads the enum next.
final class MascotCoverageTests: XCTestCase {

    /// Half the cast is chosen by the state machine. Walking every situation
    /// the app can be in must reach each of those poses.
    func testTheStateMachineCanReachEveryPoseItOwns() {
        var reached: Set<MascotState.Mood> = []
        let idles: [TimeInterval?] = [nil, 60, 20 * 60, 3 * 3600, 12 * 3600]
        for isLive in [true, false] {
            for blind in [true, false] {
                for empty in [true, false] {
                    for unpriced in [true, false] {
                        for remaining in [nil, 5.0, 40.0, 80.0] as [Double?] {
                            for idle in idles {
                                for tokens in [0, 5_000] {
                                    reached.insert(MascotState.cast(for: .init(
                                        isLive: isLive, quotaRemaining: remaining,
                                        quotaBlind: blind, storeEmpty: empty,
                                        todayTokens: tokens, newlyUnpriced: unpriced,
                                        idleFor: idle
                                    ), lang: .en).mood)
                                }
                            }
                        }
                    }
                }
            }
        }
        // The poses the machine is responsible for; the rest are placed by the
        // views (section kickers, empty states) and are covered by the app.
        let owned: Set<MascotState.Mood> = [
            .angry, .box, .peek, .puzzled, .stalk, .alert,
            .bed, .sleep, .curl, .butterfly, .happy, .wash,
        ]
        XCTAssertEqual(owned.subtracting(reached), [], "unreachable pose(s) in cast()")
        XCTAssertEqual(reached.subtracting(owned), [], "cast() returned a pose the views own")
    }

    /// And the two halves must not overlap or leave a gap.
    func testTheCastAndTheViewsTogetherCoverEveryDrawing() {
        let ownedByMachine: Set<MascotState.Mood> = [
            .angry, .box, .peek, .puzzled, .stalk, .alert,
            .bed, .sleep, .curl, .butterfly, .happy, .wash,
        ]
        let placedByViews: Set<MascotState.Mood> = [
            .sit, .loaf, .flop, .blanket, .boxpaws, .pounce,
            .mouse, .play, .groom, .eat, .fish, .mug,
        ]
        XCTAssertTrue(ownedByMachine.isDisjoint(with: placedByViews))
        XCTAssertEqual(
            Set(MascotState.Mood.allCases),
            ownedByMachine.union(placedByViews),
            "every drawing must be reachable from somewhere"
        )
    }
}
