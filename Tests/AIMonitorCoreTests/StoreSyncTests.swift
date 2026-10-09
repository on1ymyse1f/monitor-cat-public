import XCTest
@testable import AIMonitorCore

// MARK: - Store dedup

final class EventStoreTests: XCTestCase {

    private func event(id: String, billable: Int, provider: String = "Claude Code", model: String? = "claude-opus-5") -> AIEvent {
        AIEvent(
            id: id, timestamp: Date(timeIntervalSince1970: 1_787_000_000),
            provider: provider, model: model,
            tokens: TokenBreakdown(output: billable),   // billable == output here
            costUSD: nil, confidence: .estimated
        )
    }

    /// Claude Code's progressive snapshots share a requestId; the fold keeps the
    /// largest regardless of arrival order — the invariant the CLI collector
    /// proved in memory, now enforced by the schema.
    func testKeepLargestIsOrderIndependent() throws {
        let store = try EventStore.inMemory()
        try store.insert(usage: event(id: "req_1", billable: 800), keepLargest: true)
        try store.insert(usage: event(id: "req_1", billable: 2), keepLargest: true)
        try store.insert(usage: event(id: "req_1", billable: 410), keepLargest: true)
        let t = try XCTUnwrap(store.tokenBreakdown(provider: "Claude Code"))
        XCTAssertEqual(t.billableEquivalent, 800, "smaller snapshots must never overwrite the completed one")
        XCTAssertEqual(try store.eventCount(provider: "Claude Code"), 1)
    }

    /// Hourly buckets come back from SQLite as "yyyy-MM-dd HH:00:00" and
    /// must parse whatever the Mac's 12/24-hour setting is. With a
    /// locale-dependent formatter, a 12-hour Mac dropped every bucket and the
    /// dashboard's "today" flow chart was always empty.
    func testHourlyTokenFlowParsesAfternoonBuckets() throws {
        let store = try EventStore.inMemory()
        let cal = Calendar.current
        let afternoon = cal.date(bySettingHour: 15, minute: 20, second: 0, of: Date())!
        try store.insert(usage: AIEvent(
            id: "flow-1", timestamp: afternoon, provider: "Claude Code", model: "claude-opus-5",
            tokens: TokenBreakdown(output: 1234), costUSD: nil, confidence: .estimated), keepLargest: false)
        let flow = try store.tokenFlow(since: cal.startOfDay(for: afternoon),
                                       until: cal.startOfDay(for: afternoon).addingTimeInterval(86_400))
        XCTAssertEqual(flow.count, 1)
        XCTAssertEqual(flow.first?.1, 1234)
        XCTAssertEqual(flow.first.map { cal.component(.hour, from: $0.0) }, 15)
    }

    /// Codex positional ids replay identically: re-syncing a file is a no-op.
    func testPositionalIdsIgnoreReplays() throws {
        let store = try EventStore.inMemory()
        try store.insert(usage: event(id: "codex:rollout-a@0", billable: 100, provider: "Codex CLI", model: nil), keepLargest: false)
        try store.insert(usage: event(id: "codex:rollout-a@0", billable: 100, provider: "Codex CLI", model: nil), keepLargest: false)
        let t = try XCTUnwrap(store.tokenBreakdown(provider: "Codex CLI"))
        XCTAssertEqual(t.billableEquivalent, 100)
    }

    func testRetentionDeletesOldEvents() throws {
        let store = try EventStore.inMemory()
        var old = event(id: "old", billable: 10)
        old.timestamp = Date(timeIntervalSince1970: 1_000_000)   // 1970
        try store.insert(usage: old, keepLargest: true)
        try store.insert(usage: event(id: "new", billable: 10), keepLargest: true)
        try store.applyRetention()   // default 90 days
        XCTAssertEqual(try store.eventCount(provider: "Claude Code"), 1)
        try store.setSetting("retention_days", "0")   // forever
        try store.applyRetention()
        XCTAssertEqual(try store.eventCount(provider: "Claude Code"), 1, "forever must delete nothing")
    }

    func testDeleteAllData() throws {
        let store = try EventStore.inMemory()
        try store.insert(usage: event(id: "a", billable: 10), keepLargest: true)
        let quota = QuotaWindow(id: "weekly", label: "weekly", usedPercent: 20,
                                windowMinutes: 10080, resetsAt: nil, observedAt: Date())
        try store.insert(quota: quota, provider: "Codex CLI")
        XCTAssertNotNil(store.quotaConfirmedAt(provider: "Codex CLI", windowID: "weekly"))
        try store.deleteAllData()
        XCTAssertEqual(try store.eventCount(provider: "Claude Code"), 0)
        XCTAssertNil(try store.tokenBreakdown(provider: "Claude Code"))
        XCTAssertNil(store.quotaConfirmedAt(provider: "Codex CLI", windowID: "weekly"))
    }

    func testCumulativeBillableHasAStableWholeStoreScope() throws {
        let store = try EventStore.inMemory()
        try store.insert(usage: event(id: "claude", billable: 100), keepLargest: true)
        try store.insert(usage: event(id: "codex", billable: 300,
                                      provider: "Codex CLI"), keepLargest: false)
        XCTAssertEqual(try store.cumulativeBillable(), 400)

        try store.insert(usage: event(id: "codex-2", billable: 1,
                                      provider: "Codex CLI"), keepLargest: false)
        XCTAssertEqual(try store.cumulativeBillable(), 401,
                       "one new token remains +1 regardless of which live rows are visible")
    }

    /// The app reads on the main thread while syncs write from background
    /// queues — a race that once segfaulted inside sqlite3BtreeInsert.
    /// The Database's recursive lock must make this interleaving safe.
    func testConcurrentReadWriteDoesNotCrash() throws {
        let store = try EventStore.inMemory()
        let group = DispatchGroup()
        for n in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<200 {
                    try? store.insert(usage: self.event(id: "t\(n)-\(i)", billable: i), keepLargest: true)
                    try? store.setSetting("k\(n)", "\(i)")
                    _ = try? store.totalsByProvider()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(try store.eventCount(provider: "Claude Code"), 1600)
    }
}

// MARK: - Incremental sync

final class SyncEngineTests: XCTestCase {

    private func claudeRecord(requestID: String, ts: String, output: Int) -> String {
        """
        {"requestId":"\(requestID)","timestamp":"\(ts)","type":"assistant","sessionId":"s1",\
        "message":{"id":"msg_\(requestID)_\(output)","model":"claude-opus-5",\
        "usage":{"input_tokens":2,"cache_read_input_tokens":100,\
        "cache_creation":{"ephemeral_1h_input_tokens":50,"ephemeral_5m_input_tokens":0},\
        "output_tokens":\(output)}}}
        """
    }

    private func codexTokenCount(ts: String, input: Int, cached: Int, output: Int) -> String {
        """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{\
        "total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":0,\
        "total_tokens":\(input + output)}}}}
        """
    }

    private func codexTurnContext(model: String, ts: String) -> String {
        """
        {"timestamp":"\(ts)","type":"turn_context","payload":{"model":"\(model)"}}
        """
    }

    func testFingerprintIgnoresFilesCollectorsDoNotRead() throws {
        let claude = TempDir(), codex = TempDir(), kimi = TempDir()
        let engine = SyncEngine(
            store: try EventStore.inMemory(), claudeRoot: claude.url,
            codexRoot: codex.url, kimiRoots: [kimi.url]
        )
        let before = engine.logsFingerprint()

        _ = claude.write(["not a transcript"], to: "proj/readme.txt")
        _ = codex.write(["not a rollout"], to: "2026/08/notes.jsonl")
        _ = kimi.write(["not a wire log"], to: "session/usage.jsonl")

        XCTAssertEqual(engine.logsFingerprint(), before,
                       "unrelated files under watched roots must not wake the sync engine")
    }

    func testFingerprintChangesForEveryCollectedLogKind() throws {
        let claude = TempDir(), codex = TempDir(), kimi = TempDir()
        _ = claude.write(["claude"], to: "proj/session.jsonl")
        _ = codex.write(["codex"], to: "2026/08/10/rollout-a.jsonl")
        _ = kimi.write(["kimi"], to: "workspace/session/agents/main/wire.jsonl")
        let engine = SyncEngine(
            store: try EventStore.inMemory(), claudeRoot: claude.url,
            codexRoot: codex.url, kimiRoots: [kimi.url]
        )

        var previous = engine.logsFingerprint()
        _ = claude.write(["claude", "grew"], to: "proj/session.jsonl")
        XCTAssertNotEqual(engine.logsFingerprint(), previous)

        previous = engine.logsFingerprint()
        _ = codex.write(["codex", "grew"], to: "2026/08/10/rollout-a.jsonl")
        XCTAssertNotEqual(engine.logsFingerprint(), previous)

        previous = engine.logsFingerprint()
        _ = kimi.write(["kimi", "grew"], to: "workspace/session/agents/main/wire.jsonl")
        XCTAssertNotEqual(engine.logsFingerprint(), previous)
    }

    func testFingerprintDetectsRedistributionWhenTotalSizeIsUnchanged() throws {
        let claude = TempDir()
        let first = claude.write(["aaaa"], to: "proj/first.jsonl")
        let second = claude.write(["bbbbbb"], to: "proj/second.jsonl")
        func totalSize(of files: [URL]) throws -> Int {
            try files.reduce(0) { total, url in
                total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
        }
        let engine = SyncEngine(
            store: try EventStore.inMemory(), claudeRoot: claude.url,
            codexRoot: TempDir().url, kimiRoots: [TempDir().url]
        )

        let before = engine.logsFingerprint()
        let oldTotal = try totalSize(of: [first, second])
        _ = claude.write(["aaaaa"], to: "proj/first.jsonl")
        _ = claude.write(["bbbbb"], to: "proj/second.jsonl")
        let newTotal = try totalSize(of: [first, second])

        XCTAssertEqual(newTotal, oldTotal, "the fixture must collide under the old summed-size fingerprint")
        XCTAssertNotEqual(engine.logsFingerprint(), before,
                          "per-file path and size must expose equal-and-opposite changes")
    }

    /// The core invariant: incremental sync (sync, append, sync again) must land
    /// on exactly the same store contents as one full sync of the final file.
    func testIncrementalEqualsFullSyncClaude() throws {
        let incrementalDir = TempDir(), fullDir = TempDir()
        let lines1 = [claudeRecord(requestID: "r1", ts: "2026-08-10T10:00:00.000Z", output: 100)]
        let lines2 = lines1 + [claudeRecord(requestID: "r2", ts: "2026-08-10T10:01:00.000Z", output: 200)]

        let incStore = try EventStore.inMemory()
        let incEngine = SyncEngine(store: incStore, claudeRoot: incrementalDir.url, codexRoot: TempDir().url, kimiRoots: [TempDir().url])
        _ = incrementalDir.write(lines1, to: "proj/session.jsonl")
        _ = incEngine.sync()
        _ = incrementalDir.write(lines2, to: "proj/session.jsonl")   // append (rewrite with more lines)
        _ = incEngine.sync()

        let fullStore = try EventStore.inMemory()
        let fullEngine = SyncEngine(store: fullStore, claudeRoot: fullDir.url, codexRoot: TempDir().url, kimiRoots: [TempDir().url])
        _ = fullDir.write(lines2, to: "proj/session.jsonl")
        _ = fullEngine.sync()

        XCTAssertEqual(
            try incStore.tokenBreakdown(provider: ClaudeCodeCollector.providerName),
            try fullStore.tokenBreakdown(provider: ClaudeCodeCollector.providerName)
        )
    }

    /// Codex deltas must resume from the checkpoint's saved cumulative snapshot,
    /// not from zero — otherwise the second sync double-counts.
    func testIncrementalEqualsFullSyncCodex() throws {
        let incrementalDir = TempDir(), fullDir = TempDir()
        let lines1 = [codexTokenCount(ts: "2026-08-10T10:00:00.000Z", input: 100, cached: 50, output: 10)]
        let lines2 = lines1 + [codexTokenCount(ts: "2026-08-10T10:01:00.000Z", input: 300, cached: 150, output: 30)]

        let incStore = try EventStore.inMemory()
        let incEngine = SyncEngine(store: incStore, claudeRoot: TempDir().url, codexRoot: incrementalDir.url, kimiRoots: [TempDir().url])
        _ = incrementalDir.write(lines1, to: "2026/08/10/rollout-a.jsonl")
        _ = incEngine.sync()
        _ = incrementalDir.write(lines2, to: "2026/08/10/rollout-a.jsonl")
        _ = incEngine.sync()

        let fullStore = try EventStore.inMemory()
        let fullEngine = SyncEngine(store: fullStore, claudeRoot: TempDir().url, codexRoot: fullDir.url, kimiRoots: [TempDir().url])
        _ = fullDir.write(lines2, to: "2026/08/10/rollout-a.jsonl")
        _ = fullEngine.sync()

        let inc = try XCTUnwrap(try incStore.tokenBreakdown(provider: CodexCollector.providerName))
        let full = try XCTUnwrap(try fullStore.tokenBreakdown(provider: CodexCollector.providerName))
        XCTAssertEqual(inc, full)
        XCTAssertEqual(full.billableEquivalent, 330, "final snapshot: 150 fresh + 150 cached + 30 output")
    }

    /// A turn's model comes from its `turn_context` line; a mid-session switch
    /// re-attributes later events, and the checkpoint carries the current
    /// model across an incremental resume.
    func testCodexModelAttribution() throws {
        let dir = TempDir()
        let lines1 = [
            codexTurnContext(model: "gpt-5.6-sol", ts: "2026-08-10T09:59:00.000Z"),
            codexTokenCount(ts: "2026-08-10T10:00:00.000Z", input: 100, cached: 50, output: 10),
        ]
        let lines2 = lines1 + [
            codexTurnContext(model: "gpt-5.5", ts: "2026-08-10T10:00:30.000Z"),
            codexTokenCount(ts: "2026-08-10T10:01:00.000Z", input: 300, cached: 150, output: 30),
        ]

        let store = try EventStore.inMemory()
        let engine = SyncEngine(store: store, claudeRoot: TempDir().url, codexRoot: dir.url, kimiRoots: [TempDir().url])
        _ = dir.write(lines1, to: "2026/08/10/rollout-a.jsonl")
        _ = engine.sync()
        _ = dir.write(lines2, to: "2026/08/10/rollout-a.jsonl")
        _ = engine.sync()

        let byModel = Dictionary(uniqueKeysWithValues: try store.totalsByModel().map { ($0.model, $0.billable) })
        XCTAssertEqual(byModel["gpt-5.6-sol"], 110, "first turn: 50 fresh + 50 cached + 10 output")
        XCTAssertEqual(byModel["gpt-5.5"], 220, "second turn after the switch: 100 fresh + 100 cached + 20 output")

        let costByModel = Dictionary(uniqueKeysWithValues: try store.totalsByModel().map { ($0.model, $0.costUSD) })
        XCTAssertEqual(try XCTUnwrap(costByModel["gpt-5.6-sol"] ?? nil), 0.000575, accuracy: 1e-9, "50×$5 + 50×$0.5 + 10×$30, per million")
        XCTAssertEqual(try XCTUnwrap(costByModel["gpt-5.5"] ?? nil), 0.00115, accuracy: 1e-9, "100×$5 + 100×$0.5 + 20×$30, per million")
    }

    /// An unchanged file must be skipped — this is what makes the menu-bar timer cheap.
    func testUnchangedFilesAreSkipped() throws {
        let dir = TempDir()
        _ = dir.write([claudeRecord(requestID: "r1", ts: "2026-08-10T10:00:00.000Z", output: 100)], to: "proj/session.jsonl")
        let store = try EventStore.inMemory()
        let engine = SyncEngine(store: store, claudeRoot: dir.url, codexRoot: TempDir().url, kimiRoots: [TempDir().url])
        var s = engine.sync()
        XCTAssertEqual(s.filesScanned, 1)
        s = engine.sync()
        XCTAssertEqual(s.filesScanned, 0)
        XCTAssertEqual(s.filesSkippedUnchanged, 1)
    }

    /// A truncated file (rotated) must be re-parsed from zero without duplicates.
    func testTruncatedFileReparsesCleanly() throws {
        let dir = TempDir()
        let lines = [claudeRecord(requestID: "r1", ts: "2026-08-10T10:00:00.000Z", output: 100),
                     claudeRecord(requestID: "r2", ts: "2026-08-10T10:01:00.000Z", output: 200)]
        _ = dir.write(lines, to: "proj/session.jsonl")
        let store = try EventStore.inMemory()
        let engine = SyncEngine(store: store, claudeRoot: dir.url, codexRoot: TempDir().url, kimiRoots: [TempDir().url])
        _ = engine.sync()
        _ = dir.write([lines[0]], to: "proj/session.jsonl")   // truncated: smaller than checkpoint
        let s = engine.sync()
        XCTAssertEqual(s.filesScanned, 1, "size shrink must force re-parse")
        // r2's event stays in the store (history is history), r1 replays harmlessly.
        XCTAssertEqual(try store.eventCount(provider: ClaudeCodeCollector.providerName), 2)
    }

    /// Sync makes the store faithful to the logs; it must never silently apply
    /// retention — old events survive a sync and are only deleted by an
    /// explicit applyRetention() call.
    func testSyncNeverDeletesOldEvents() throws {
        let dir = TempDir()
        _ = dir.write([claudeRecord(requestID: "ancient", ts: "2020-01-01T00:00:00.000Z", output: 100)], to: "proj/session.jsonl")
        let store = try EventStore.inMemory()
        let engine = SyncEngine(store: store, claudeRoot: dir.url, codexRoot: TempDir().url, kimiRoots: [TempDir().url])
        _ = engine.sync()
        XCTAssertEqual(try store.eventCount(provider: ClaudeCodeCollector.providerName), 1)
    }

    func testQuotaSnapshotsDeduplicateConsecutiveRepeats() throws {
        let store = try EventStore.inMemory()
        let q = QuotaWindow(id: "codex", label: "Weekly", usedPercent: 42, windowMinutes: 10080,
                            resetsAt: Date(timeIntervalSince1970: 1_787_500_000),
                            observedAt: Date(timeIntervalSince1970: 1_787_000_000), planType: nil)
        try store.insert(quota: q, provider: "Codex CLI")
        try store.insert(quota: q, provider: "Codex CLI")
        XCTAssertEqual(try store.quotaHistory(windowId: "codex").count, 1, "identical consecutive snapshots are noise")
    }

    /// A successful live refresh is meaningful even when the percentage did
    /// not change. History stays deduplicated, but the card remains current.
    ///
    /// **Changed intent.** This used to assert that an hour-old weekly reading
    /// was dropped from the dashboard. It is not any more: an hour is 0.6% of a
    /// weekly window, so the number is still accurate to well under a point,
    /// and hiding it was costing the user a card they wanted — the reported
    /// "Kimi quota does not show" — for a source that had merely gone quiet.
    /// A quiet source is now disclosed by the card's own age line instead.
    /// What still hides a card is the reading going *meaningless*: the window
    /// rolling out from under it, or its reset time passing.
    func testUnchangedQuotaRefreshesConfirmationWithoutGrowingHistory() throws {
        let store = try EventStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_787_500_000)
        let stale = QuotaWindow(id: "kimi-weekly", label: "weekly", usedPercent: 60,
                                windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400),
                                observedAt: now.addingTimeInterval(-3600))
        try store.insert(quota: stale, provider: "Kimi Code")
        XCTAssertEqual(try StoreReport.dashboard(from: store, now: now).quotas.count, 1,
                       "an hour is 0.6% of a weekly window — still worth showing, with its age")

        var refreshed = stale
        refreshed.observedAt = now.addingTimeInterval(-10)
        try store.insert(quota: refreshed, provider: "Kimi Code")

        XCTAssertEqual(try store.quotaHistory(windowId: "kimi-weekly").count, 1)
        XCTAssertEqual(
            store.quotaConfirmedAt(provider: "Kimi Code", windowID: "kimi-weekly"),
            refreshed.observedAt
        )
        XCTAssertEqual(try StoreReport.dashboard(from: store, now: now).quotas.count, 1)

        // A later backfill of an older observation must not make live data stale.
        try store.insert(quota: stale, provider: "Kimi Code")
        XCTAssertEqual(
            store.quotaConfirmedAt(provider: "Kimi Code", windowID: "kimi-weekly"),
            refreshed.observedAt
        )
    }

    /// Rotated window ids (same provider, same label) must collapse to one
    /// card — the freshest observation wins; expired windows disappear.
    func testDashboardDeduplicatesRotatedWindowIds() throws {
        let store = try EventStore.inMemory()
        let future = Date().addingTimeInterval(86400)
        let old = QuotaWindow(id: "codex", label: "weekly", usedPercent: 99, windowMinutes: 10080,
                              resetsAt: future, observedAt: Date().addingTimeInterval(-7200), planType: nil)
        let fresh = QuotaWindow(id: "codex-v2", label: "weekly", usedPercent: 56, windowMinutes: 10080,
                                resetsAt: future, observedAt: Date(), planType: nil)
        try store.insert(quota: old, provider: "Codex CLI")
        try store.insert(quota: fresh, provider: "Codex CLI")
        let dash = try StoreReport.dashboard(from: store)
        XCTAssertEqual(dash.quotas.count, 1)
        XCTAssertEqual(dash.quotas.first?.window.usedPercent, 56)
    }

    /// A window whose reset time already passed is stale — showing it as live
    /// quota is how the duplicate-card bug read as nonsense.
    func testDashboardDropsExpiredWindows() throws {
        let store = try EventStore.inMemory()
        let expired = QuotaWindow(id: "codex", label: "weekly", usedPercent: 99, windowMinutes: 10080,
                                  resetsAt: Date().addingTimeInterval(-3600), observedAt: Date().addingTimeInterval(-7200), planType: nil)
        try store.insert(quota: expired, provider: "Codex CLI")
        let dash = try StoreReport.dashboard(from: store)
        XCTAssertTrue(dash.quotas.isEmpty)
    }

    /// How old is "too old" scales with the window, because a quota figure is a
    /// percentage of a rolling window: after `age`, up to `age / window` of it
    /// has rolled off, and that ratio bounds the error the reading can carry.
    ///
    /// A flat threshold got both ends wrong — too lax for a 5-hour window and
    /// far too strict for a weekly one.
    func testOldObservationsAreDroppedInProportionToTheirWindow() throws {
        func dashboardCount(windowMinutes: Int, ageHours: Double) throws -> Int {
            let store = try EventStore.inMemory()
            let now = Date()
            let q = QuotaWindow(id: "w", label: QuotaWindow.label(forWindowMinutes: windowMinutes),
                                usedPercent: 60, windowMinutes: windowMinutes,
                                resetsAt: now.addingTimeInterval(86400 * 7),
                                observedAt: now.addingTimeInterval(-ageHours * 3600))
            try store.insert(quota: q, provider: "Kimi Code")
            return try StoreReport.dashboard(from: store, now: now).quotas.count
        }

        // Weekly: an hour is nothing, a week is everything.
        XCTAssertEqual(try dashboardCount(windowMinutes: 10080, ageHours: 1), 1)
        XCTAssertEqual(try dashboardCount(windowMinutes: 10080, ageHours: 24), 1)
        XCTAssertEqual(try dashboardCount(windowMinutes: 10080, ageHours: 24 * 3), 0,
                       "three days into a weekly window, the reading has rolled")

        // Five-hour: the same ages are a very different story.
        XCTAssertEqual(try dashboardCount(windowMinutes: 300, ageHours: 0.2), 1)
        XCTAssertEqual(try dashboardCount(windowMinutes: 300, ageHours: 3), 0,
                       "three hours into a five-hour window, most of it has rolled")
    }

    func testCollectorVersionResetIsScopedAndRunsOnce() throws {
        let store = try EventStore.inMemory()
        func usage(_ id: String, _ provider: String, _ billable: Int) -> AIEvent {
            AIEvent(id: id, timestamp: Date(), provider: provider,
                    tokens: TokenBreakdown(output: billable), costUSD: nil, confidence: .estimated)
        }
        try store.insert(usage: usage("codex-old", "Codex CLI", 500), keepLargest: false)
        try store.insert(usage: usage("claude-safe", "Claude Code", 100), keepLargest: false)
        try store.setCheckpoint(.init(size: 10, offset: 10, state: nil), for: "/tmp/codex/a.jsonl")

        XCTAssertTrue(try store.prepareCollectorVersion(
            settingKey: "collector_version_codex", version: "2",
            provider: "Codex CLI", checkpointRoot: "/tmp/codex"))
        XCTAssertEqual(try store.eventCount(provider: "Codex CLI"), 0)
        XCTAssertEqual(try store.eventCount(provider: "Claude Code"), 1)
        XCTAssertNil(try store.checkpoint(for: "/tmp/codex/a.jsonl"))
        XCTAssertFalse(try store.prepareCollectorVersion(
            settingKey: "collector_version_codex", version: "2",
            provider: "Codex CLI", checkpointRoot: "/tmp/codex"))
    }
}

// MARK: - Burn rate

final class BurnRateTests: XCTestCase {

    private func point(_ hoursAgo: Double, _ pct: Double, resetsInHours: Double = 24) -> EventStore.QuotaPoint {
        EventStore.QuotaPoint(
            observedAt: Date().addingTimeInterval(-hoursAgo * 3600),
            usedPercent: pct,
            resetsAt: Date().addingTimeInterval(resetsInHours * 3600)
        )
    }

    func testProjectionWithSufficientData() throws {
        let reset = Date().addingTimeInterval(24 * 3600)
        let history = [point(6, 20), point(3, 50), point(0, 80)]
        let p = try XCTUnwrap(BurnRate.project(history: history, windowMinutes: 10080, resetsAt: reset))
        XCTAssertEqual(p.percentPerHour, 10, accuracy: 0.01)
        // 20% remaining at 10%/h → 2 hours
        XCTAssertEqual(p.exhaustedAt.timeIntervalSinceNow, 2 * 3600, accuracy: 60)
    }

    func testNoPredictionWithOnePoint() {
        XCTAssertNil(BurnRate.project(history: [point(0, 60)], windowMinutes: 300, resetsAt: Date().addingTimeInterval(3600)))
    }

    func testNoPredictionWhenSpanTooShort() {
        // Two points 30 seconds apart on a weekly window: nothing to project from.
        let history = [
            EventStore.QuotaPoint(observedAt: Date().addingTimeInterval(-30), usedPercent: 40, resetsAt: nil),
            EventStore.QuotaPoint(observedAt: Date(), usedPercent: 41, resetsAt: nil),
        ]
        XCTAssertNil(BurnRate.project(history: history, windowMinutes: 10080, resetsAt: Date().addingTimeInterval(24 * 3600)))
    }

    func testNoPredictionWhenBurnIsZero() {
        let history = [point(2, 60), point(1, 60), point(0, 60)]
        XCTAssertNil(BurnRate.project(history: history, windowMinutes: 10080, resetsAt: Date().addingTimeInterval(24 * 3600)))
    }

    func testNoPredictionWhenQuotaSurvivesTheWindow() {
        // Burning ~0.33%/hour with 24h to reset → nowhere near exhaustion.
        let history = [point(6, 40), point(3, 41), point(0, 42)]
        XCTAssertNil(BurnRate.project(history: history, windowMinutes: 10080, resetsAt: Date().addingTimeInterval(24 * 3600)))
    }

    func testResetDiscardsOldHistory() throws {
        let reset = Date().addingTimeInterval(24 * 3600)
        // Usage drops between 6h and 4h ago — a reset. Only post-reset points count.
        let history = [point(8, 95), point(6, 97), point(4, 5), point(0, 45)]
        let p = try XCTUnwrap(BurnRate.project(history: history, windowMinutes: 10080, resetsAt: reset))
        XCTAssertEqual(p.percentPerHour, 10, accuracy: 0.01, "rate must come from post-reset points only")
    }
}

// MARK: - Recost

/// Stored costs are computed at sync time, so an edited rate table only reaches
/// events synced afterwards. `recost` closes that gap; these pin the properties
/// that make it safe to run on a real store.
final class RecostTests: XCTestCase {

    private func builtInCatalog() -> PricingCatalog {
        PricingCatalog(
            models: PricingTable.builtInAnthropic.merging(PricingTable.builtInOpenAI) { a, _ in a },
            fastMode: PricingTable.builtInFastMode
        )
    }

    /// One million fresh input tokens, so the cost equals the input rate exactly
    /// and the arithmetic in the assertions stays readable.
    private func event(id: String, model: String, speed: String? = nil, at ts: Date) -> AIEvent {
        let tokens = TokenBreakdown(uncachedInput: 1_000_000)
        return AIEvent(
            id: id, timestamp: ts, provider: "Claude Code", model: model,
            speed: speed, tokens: tokens,
            costUSD: PricingTable.cost(of: tokens, model: model, speed: speed, asOf: ts),
            confidence: .estimated
        )
    }

    private func storedCost(_ store: EventStore) throws -> Decimal {
        try XCTUnwrap(store.totalsByModel().map { Decimal($0.costUSD ?? 0) }.reduce(0, +))
    }

    /// The property that makes it safe to wire into a refresh: repricing against
    /// the table the costs were already written with changes nothing.
    func testRecostAgainstTheSameTableIsANoOp() throws {
        let store = try EventStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        try store.insert(usage: event(id: "a", model: "claude-opus-5", at: now), keepLargest: true)
        try store.insert(usage: event(id: "b", model: "claude-haiku-4-5", at: now), keepLargest: true)

        let summary = try store.recost()
        XCTAssertEqual(summary.rowsExamined, 2)
        XCTAssertEqual(summary.rowsChanged, 0, "nothing changed, so nothing should be rewritten")
        XCTAssertEqual(summary.deltaUSD, 0, "a no-op recost must report exactly zero, not a rounding artefact")
    }

    func testRecostAppliesAnEditedRate() throws {
        let store = try EventStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        try store.insert(usage: event(id: "a", model: "claude-opus-5", at: now), keepLargest: true)
        XCTAssertEqual(try storedCost(store), 5, "built-in opus-5 input rate")

        var edited = builtInCatalog()
        edited.models["claude-opus-5"] = ModelRate(input: 7, output: 35)
        PricingCatalog.override(with: edited)
        defer { PricingCatalog.override(with: nil) }

        let summary = try store.recost()
        XCTAssertEqual(summary.rowsChanged, 1)
        XCTAssertEqual(summary.deltaUSD, 2)
        XCTAssertEqual(try storedCost(store), 7, "the stored row now carries the edited rate")
    }

    /// A row is repriced against **its own** timestamp, so an intro rate that
    /// has since lapsed still applies to the events it actually covered.
    func testRecostUsesEachRowsOwnTimestampForIntroRates() throws {
        let store = try EventStore.inMemory()
        let during = Timestamps.parse("2026-08-17T00:00:00Z")!
        let after = Timestamps.parse("2026-09-15T00:00:00Z")!
        try store.insert(usage: event(id: "during", model: "claude-sonnet-5", at: during), keepLargest: true)
        try store.insert(usage: event(id: "after", model: "claude-sonnet-5", at: after), keepLargest: true)

        // Recost "now" is well past the cutoff; the older row must not follow.
        let summary = try store.recost(now: after)
        XCTAssertEqual(summary.rowsChanged, 0)
        XCTAssertEqual(try storedCost(store), 5, "intro $2 for the covered row + standard $3 for the later one")
    }

    func testScopedRecostLeavesOtherModelsUntouched() throws {
        let store = try EventStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let tokens = TokenBreakdown(uncachedInput: 1_000_000)
        try store.insert(usage: AIEvent(
            id: "new-gpt", timestamp: now, provider: "Codex CLI", model: "gpt-5.5",
            tokens: tokens, costUSD: nil, confidence: .estimated
        ), keepLargest: true)
        try store.insert(usage: AIEvent(
            id: "other", timestamp: now, provider: "Codex CLI", model: "future-model",
            tokens: tokens, costUSD: nil, confidence: .estimated
        ), keepLargest: true)

        let summary = try store.recost(onlyModels: ["gpt-5.5"])
        XCTAssertEqual(summary.rowsExamined, 1)
        XCTAssertEqual(summary.rowsChanged, 1)
        XCTAssertEqual(summary.nowPriced, 1)
        let costs = Dictionary(uniqueKeysWithValues: try store.totalsByModel().map { ($0.model, $0.costUSD) })
        XCTAssertEqual(costs["gpt-5.5"] ?? nil, 5)
        XCTAssertNil(costs["future-model"] ?? nil, "a scoped migration must not alter unrelated history")
    }

    /// An override with `replace: true` and a mistyped model id deletes money
    /// silently unless the summary says so. This is the alarm for that.
    func testModelsDroppedFromTheTableAreCountedAsLostPrices() throws {
        let store = try EventStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        try store.insert(usage: event(id: "a", model: "claude-opus-5", at: now), keepLargest: true)

        PricingCatalog.override(with: PricingCatalog(models: ["typo-in-the-id": ModelRate(input: 5, output: 25)], fastMode: [:]))
        defer { PricingCatalog.override(with: nil) }

        let summary = try store.recost()
        XCTAssertEqual(summary.nowUnpriced, 1)
        XCTAssertEqual(summary.newTotalUSD, 0)
        XCTAssertEqual(try storedCost(store), 0)
    }

    /// Fast mode is a stored fact now, not one inferred at recost time.
    func testFastModePremiumSurvivesARecost() throws {
        let store = try EventStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        try store.insert(usage: event(id: "fast", model: "claude-opus-5", speed: "fast", at: now), keepLargest: true)
        XCTAssertEqual(try storedCost(store), 10)

        let summary = try store.recost()
        XCTAssertEqual(summary.rowsChanged, 0)
        XCTAssertEqual(summary.unvouchedSpeedRows, 0, "the row records its own tier")
        XCTAssertEqual(try storedCost(store), 10, "a recost must not quietly demote it to the standard rate")
    }
}

// MARK: - Unpriced baseline

/// The unpriced list is always non-empty, so "something is unpriced" is not a
/// signal. The baseline is what turns it into one.
final class UnpricedBaselineTests: XCTestCase {

    private func insert(_ store: EventStore, id: String, provider: String, model: String, cost: Decimal?) throws {
        try store.insert(usage: AIEvent(
            id: id, timestamp: Date(timeIntervalSince1970: 1_787_000_000),
            provider: provider, model: model,
            tokens: TokenBreakdown(output: 100),
            costUSD: cost, confidence: .estimated
        ), keepLargest: false)
    }

    /// Priced events must not show up at all — the query is the store's own
    /// `cost_usd IS NULL`, not a collector's opinion.
    func testOnlyEventsWithNoCostAreListed() throws {
        let store = try EventStore.inMemory()
        try insert(store, id: "priced", provider: "Claude Code", model: "claude-opus-5", cost: 5)
        try insert(store, id: "unpriced", provider: "Codex CLI", model: "gpt-5.5", cost: nil)

        let models = try store.unpricedModels()
        XCTAssertEqual(models.map(\.model), ["gpt-5.5"])
        XCTAssertEqual(models[0].provider, "Codex CLI")
        XCTAssertEqual(models[0].billable, 100)
    }

    /// Locally-generated ids have no upstream rate to be missing, so a user who
    /// has never taken a baseline is not greeted by a false alarm.
    func testSyntheticModelsAreNeverNews() throws {
        let store = try EventStore.inMemory()
        try insert(store, id: "s", provider: "Claude Code", model: "<synthetic>", cost: nil)

        let scan = try store.unpricedScan(baseline: UnpricedBaseline())
        XCTAssertTrue(scan.newlyUnpriced.isEmpty)
        XCTAssertEqual(scan.acknowledged.map(\.model), ["<synthetic>"])
    }

    func testBaselineSilencesKnownGapsButNotNewOnes() throws {
        let store = try EventStore.inMemory()
        try insert(store, id: "old", provider: "Codex CLI", model: "gpt-5.5", cost: nil)

        // Before a baseline, an existing gap is news.
        var scan = try store.unpricedScan(baseline: UnpricedBaseline())
        XCTAssertEqual(scan.newlyUnpriced.map(\.model), ["gpt-5.5"])

        // Acknowledge it; the list goes quiet.
        let baseline = scan.asBaseline()
        scan = try store.unpricedScan(baseline: baseline)
        XCTAssertTrue(scan.newlyUnpriced.isEmpty, "an acknowledged gap is not news")
        XCTAssertEqual(scan.acknowledged.map(\.model), ["gpt-5.5"], "but it is still listed and still uncounted")

        // A model that turns up later is news even though the list was quiet.
        try insert(store, id: "new", provider: "Codex CLI", model: "gpt-6-unreleased", cost: nil)
        scan = try store.unpricedScan(baseline: baseline)
        XCTAssertEqual(scan.newlyUnpriced.map(\.model), ["gpt-6-unreleased"])
    }

    /// The same model id arriving through two providers is two facts: one may
    /// be priced and the other not.
    func testBaselineKeysAreProviderQualified() throws {
        let store = try EventStore.inMemory()
        try insert(store, id: "a", provider: "Codex CLI", model: "shared-id", cost: nil)
        let baseline = try store.unpricedScan(baseline: UnpricedBaseline()).asBaseline()

        try insert(store, id: "b", provider: "Kimi Code", model: "shared-id", cost: nil)
        let scan = try store.unpricedScan(baseline: baseline)
        XCTAssertEqual(scan.newlyUnpriced.map(\.provider), ["Kimi Code"],
                       "acknowledging it for one provider must not acknowledge it for another")
    }

    func testBaselineSurvivesADiskRoundTrip() throws {
        let dir = TempDir()
        let url = dir.url.appendingPathComponent("baseline.json")
        let original = UnpricedBaseline(
            recordedAt: Date(timeIntervalSince1970: 1_787_000_000),
            acknowledged: ["Codex CLI/gpt-5.5", "Kimi Code/k3-agent"]
        )
        try original.save(to: url)

        let loaded = UnpricedBaseline.load(from: url)
        XCTAssertEqual(loaded.acknowledged, original.acknowledged)
        XCTAssertEqual(loaded.recordedAt.timeIntervalSince1970, 1_787_000_000, accuracy: 1)
    }

    /// A missing file means "nothing acknowledged yet", not a crash and not a
    /// silently-everything-acknowledged.
    func testMissingBaselineFileMeansNothingIsAcknowledged() {
        let loaded = UnpricedBaseline.load(from: URL(fileURLWithPath: "/nonexistent/baseline.json"))
        XCTAssertTrue(loaded.acknowledged.isEmpty)
    }
}

// MARK: - Quota snapshot dedup

/// Quota history is a time series that the burn-rate engine reads, so it must
/// be a property of the logs — not of the order the files were walked in.
final class QuotaSnapshotOrderTests: XCTestCase {

    private func window(_ percent: Double, at seconds: TimeInterval) -> QuotaWindow {
        QuotaWindow(
            id: "codex", label: "weekly", usedPercent: percent,
            windowMinutes: 10080, resetsAt: nil,
            observedAt: Date(timeIntervalSince1970: seconds), planType: "plan"
        )
    }

    private func history(_ store: EventStore) throws -> [Double] {
        try store.quotaHistory(windowId: "codex").map(\.usedPercent)
    }

    /// The regression: syncing an older file after a newer one compared each of
    /// its snapshots against a reading from the *future*, matched none, and
    /// inserted every one. Chronological order of arrival must not matter.
    func testBackfillProducesTheSameHistoryAsForwardOrder() throws {
        let readings: [(Double, TimeInterval)] = [
            (1, 100), (1, 200), (5, 300), (5, 400), (5, 500), (9, 600), (9, 700),
        ]

        let forward = try EventStore.inMemory()
        for (p, t) in readings { try forward.insert(quota: window(p, at: t), provider: "Codex CLI") }

        let backward = try EventStore.inMemory()
        for (p, t) in readings.reversed() { try backward.insert(quota: window(p, at: t), provider: "Codex CLI") }

        XCTAssertEqual(try history(forward), [1, 5, 9], "consecutive repeats collapse")
        XCTAssertEqual(try history(backward), try history(forward),
                       "the same logs must produce the same history in either walk order")
    }

    /// Interleaved arrival — several rollout files being read round-robin — is
    /// the shape that actually occurs, and it must land in the same place.
    func testInterleavedArrivalMatchesChronologicalArrival() throws {
        let readings: [(Double, TimeInterval)] = [
            (2, 100), (2, 150), (4, 200), (4, 250), (7, 300), (7, 350), (11, 400),
        ]
        let chronological = try EventStore.inMemory()
        for (p, t) in readings { try chronological.insert(quota: window(p, at: t), provider: "Codex CLI") }

        let interleaved = try EventStore.inMemory()
        for i in [3, 0, 5, 1, 6, 2, 4] {
            try interleaved.insert(quota: window(readings[i].0, at: readings[i].1), provider: "Codex CLI")
        }
        XCTAssertEqual(try history(interleaved), try history(chronological))
    }

    /// Re-syncing the same logs must not grow the history — the property that
    /// makes the store safe to rebuild.
    func testReplayingTheSameSnapshotsIsANoOp() throws {
        let store = try EventStore.inMemory()
        let readings: [(Double, TimeInterval)] = [(1, 100), (5, 200), (9, 300)]
        for _ in 0..<3 {
            for (p, t) in readings { try store.insert(quota: window(p, at: t), provider: "Codex CLI") }
        }
        XCTAssertEqual(try history(store), [1, 5, 9])
    }

    /// A genuine drop is a window reset and must survive: it is the signal the
    /// burn-rate engine uses to discard the previous window.
    func testAResetIsNotMistakenForADuplicate() throws {
        let store = try EventStore.inMemory()
        for (p, t) in [(90.0, 100.0), (95.0, 200.0), (2.0, 300.0), (6.0, 400.0)] {
            try store.insert(quota: window(p, at: t), provider: "Codex CLI")
        }
        XCTAssertEqual(try history(store), [90, 95, 2, 6])
    }
}

// MARK: - Usage verification

/// `--verify` turns `estimated` from an assertion into a measurement by
/// checking the reconstructed token counts against the provider's own quota
/// accounting. These pin the filters that decide what counts as evidence.
final class UsageVerificationTests: XCTestCase {

    private let provider = "Codex CLI"

    private func quota(_ store: EventStore, _ percent: Double, at t: TimeInterval) throws {
        try store.insert(quota: QuotaWindow(
            id: "codex", label: "weekly", usedPercent: percent, windowMinutes: 10080,
            resetsAt: nil, observedAt: Date(timeIntervalSince1970: t), planType: "plan"
        ), provider: provider)
    }

    private func usage(_ store: EventStore, id: String, at t: TimeInterval, billable: Int, model: String = "gpt-5.6-sol") throws {
        try store.insert(usage: AIEvent(
            id: id, timestamp: Date(timeIntervalSince1970: t), provider: provider, model: model,
            tokens: TokenBreakdown(output: billable), costUSD: nil, confidence: .exact
        ), keepLargest: false)
    }

    /// A run over which the ratio is constant should read as tracking, with a
    /// spread near zero.
    private func makeConsistentStore(tokensPerPercent: Int, runs: Int) throws -> EventStore {
        let store = try EventStore.inMemory()
        var t: TimeInterval = 1_000_000
        for run in 0..<runs {
            try quota(store, 1, at: t)
            // 40 quota points over an hour, with usage to match.
            try usage(store, id: "e\(run)", at: t + 60, billable: 40 * tokensPerPercent)
            try quota(store, 41, at: t + 3600)
            t += 7 * 86_400   // next window
        }
        return store
    }

    func testAConsistentRatioReadsAsTracking() throws {
        let store = try makeConsistentStore(tokensPerPercent: 100_000, runs: 5)
        let r = try UsageVerification.verify(store: store, provider: provider, windowId: "codex", label: "weekly")

        XCTAssertEqual(r.segments.count, 5)
        XCTAssertEqual(try XCTUnwrap(r.median), 100_000, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(r.relativeSpread), 0, accuracy: 0.001)
        XCTAssertTrue(r.verdict.contains("tracks"), r.verdict)
    }

    /// Under three usable segments it must refuse to state a figure rather than
    /// derive an error bar from two points.
    func testThinEvidenceProducesNoNumber() throws {
        let store = try makeConsistentStore(tokensPerPercent: 100_000, runs: 2)
        let r = try UsageVerification.verify(store: store, provider: provider, windowId: "codex", label: "weekly")

        XCTAssertNil(r.relativeSpread)
        XCTAssertTrue(r.verdict.contains("not enough clean segments"), r.verdict)
    }

    /// Quota reported in whole percent means a short run's rounding error is
    /// the same size as the signal, so short runs are not evidence.
    func testShortQuotaSpansAreRejected() throws {
        let store = try EventStore.inMemory()
        try quota(store, 10, at: 1_000_000)
        try usage(store, id: "e", at: 1_000_060, billable: 500_000)
        try quota(store, 14, at: 1_003_600)   // only 4 points

        let r = try UsageVerification.verify(store: store, provider: provider, windowId: "codex", label: "weekly")
        XCTAssertTrue(r.segments.isEmpty)
        XCTAssertEqual(r.rejected["span under 15 quota points"], 1)
    }

    /// A segment covering no elapsed time is a replayed log, not consumption.
    /// The store held thousands of these before the snapshot dedup was fixed.
    func testZeroElapsedSegmentsAreRejectedAsReplays() throws {
        let store = try EventStore.inMemory()
        try quota(store, 1, at: 1_000_000)
        try usage(store, id: "e", at: 1_000_000, billable: 5_000_000)
        try quota(store, 90, at: 1_000_010)   // 89 points in ten seconds

        let r = try UsageVerification.verify(store: store, provider: provider, windowId: "codex", label: "weekly")
        XCTAssertTrue(r.segments.isEmpty)
        XCTAssertEqual(r.rejected["no elapsed time (replayed log)"], 1)
    }

    /// Models consume quota at different rates, so a mixed interval is not
    /// comparable to a single-model one and must not be averaged in.
    func testMixedModelSegmentsAreRejected() throws {
        let store = try EventStore.inMemory()
        try quota(store, 1, at: 1_000_000)
        try usage(store, id: "a", at: 1_000_060, billable: 2_000_000, model: "gpt-5.6-sol")
        try usage(store, id: "b", at: 1_000_120, billable: 2_000_000, model: "gpt-5.6-luna")
        try quota(store, 41, at: 1_003_600)

        let r = try UsageVerification.verify(store: store, provider: provider, windowId: "codex", label: "weekly")
        XCTAssertTrue(r.segments.isEmpty)
        XCTAssertEqual(r.rejected["mixed models (no single model above 90%)"], 1)
    }

    /// A reconstruction that misses half the events in some windows shows up as
    /// scatter — which is the entire point of the check.
    func testAnInconsistentReconstructionShowsAsScatter() throws {
        let store = try EventStore.inMemory()
        var t: TimeInterval = 1_000_000
        // Alternate between fully-counted and half-counted windows.
        for run in 0..<6 {
            try quota(store, 1, at: t)
            try usage(store, id: "e\(run)", at: t + 60, billable: run.isMultiple(of: 2) ? 4_000_000 : 2_000_000)
            try quota(store, 41, at: t + 3600)
            t += 7 * 86_400
        }
        let r = try UsageVerification.verify(store: store, provider: provider, windowId: "codex", label: "weekly")
        XCTAssertEqual(r.segments.count, 6)
        XCTAssertGreaterThan(try XCTUnwrap(r.relativeSpread), 0.2, "half the tokens missing must not read as agreement")
        XCTAssertTrue(r.verdict.contains("does NOT track"), r.verdict)
    }

    /// One row per window. Duplicate snapshots at the newest timestamp used to
    /// return one row each, repeating a quota card on the board.
    func testLatestQuotasReturnsOneRowPerWindowDespiteTiedTimestamps() throws {
        let store = try EventStore.inMemory()
        // Same second, different windows and different values.
        try store.insert(quota: QuotaWindow(id: "codex", label: "weekly", usedPercent: 40, windowMinutes: 10080,
                                            resetsAt: nil, observedAt: Date(timeIntervalSince1970: 500), planType: nil), provider: provider)
        try store.insert(quota: QuotaWindow(id: "codex", label: "weekly", usedPercent: 55, windowMinutes: 10080,
                                            resetsAt: nil, observedAt: Date(timeIntervalSince1970: 500), planType: nil), provider: provider)
        try store.insert(quota: QuotaWindow(id: "codex-secondary", label: "weekly · secondary", usedPercent: 10, windowMinutes: 10080,
                                            resetsAt: nil, observedAt: Date(timeIntervalSince1970: 500), planType: nil), provider: provider)

        let latest = try store.latestQuotas()
        XCTAssertEqual(latest.count, 2, "two windows, two rows — not one row per tied snapshot")
        XCTAssertEqual(Set(latest.map(\.window.id)), ["codex", "codex-secondary"])
        XCTAssertEqual(latest.first(where: { $0.window.id == "codex" })?.window.usedPercent, 55,
                       "the last-written of the tied readings is the current one")
    }
}

// MARK: - Codex forks: the inherited-counter trap

/// A forked or subagent rollout opens with the **parent's** running
/// `total_token_usage` already in it. Measuring deltas from zero books that
/// entire inherited history as this thread's first turn.
///
/// Regression coverage ensures an inherited parent counter is treated as the
/// fork's baseline rather than new usage, including when model context arrives
/// later in the rollout.
final class CodexForkTests: XCTestCase {

    private func meta(id: String, forkedFrom: String? = nil, subagent: Bool = false) -> String {
        var fields = ["\"id\":\"\(id)\"", "\"cwd\":\"/tmp/project\""]
        if let forkedFrom {
            fields.append("\"forked_from_id\":\"\(forkedFrom)\"")
            fields.append("\"parent_thread_id\":\"\(forkedFrom)\"")
            fields.append("\"session_id\":\"\(forkedFrom)\"")
        } else {
            fields.append("\"session_id\":\"\(id)\"")
        }
        if subagent { fields.append("\"thread_source\":\"subagent\"") }
        return "{\"timestamp\":\"2026-08-13T04:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\(fields.joined(separator: ","))}}"
    }

    private func tokenCount(_ ts: String, input: Int, cached: Int, output: Int) -> String {
        """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{\
        "total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":0,\
        "total_tokens":\(input + output)},\
        "model_context_window":272000}}}
        """
    }

    private func turnContext(_ ts: String, model: String) -> String {
        "{\"timestamp\":\"\(ts)\",\"type\":\"turn_context\",\"payload\":{\"model\":\"\(model)\"}}"
    }

    private func codexTotal(_ store: EventStore) throws -> Int {
        try store.tokenBreakdown(provider: "Codex CLI")?.billableEquivalent ?? 0
    }

    /// The regression, in miniature: the fork's opening snapshot is the
    /// parent's total and must not be counted again.
    func testForkedRolloutDoesNotRecountTheInheritedBaseline() throws {
        let dir = TempDir()
        _ = dir.write([
            meta(id: "child-1", forkedFrom: "parent-1"),
            turnContext("2026-08-13T04:00:00.000Z", model: "gpt-5.6-sol"),
            // Inherited: the parent already accounted for all of this.
            tokenCount("2026-08-13T04:00:01.000Z", input: 1_000_000, cached: 900_000, output: 50_000),
            // This thread's own work: +10,000 input, +1,000 output.
            tokenCount("2026-08-13T04:00:02.000Z", input: 1_010_000, cached: 900_000, output: 51_000),
        ], to: "2026/08/13/rollout-child.jsonl")

        let store = try EventStore.inMemory()
        _ = SyncEngine(store: store, claudeRoot: dir.url.appendingPathComponent("none"),
                       codexRoot: dir.url, kimiRoots: []).sync()

        // 10,000 fresh input + 1,000 output. Not 1,061,000.
        XCTAssertEqual(try codexTotal(store), 11_000,
                       "the inherited baseline must seed the delta, not become the first turn")
    }

    /// `thread_source: subagent` alone is enough — a spawned agent need not
    /// carry forked_from_id.
    func testSubagentMarkerAloneSeedsTheBaseline() throws {
        let dir = TempDir()
        _ = dir.write([
            meta(id: "sub-1", subagent: true),
            turnContext("2026-08-13T04:00:00.000Z", model: "gpt-5.6-sol"),
            tokenCount("2026-08-13T04:00:01.000Z", input: 500_000, cached: 400_000, output: 20_000),
            tokenCount("2026-08-13T04:00:02.000Z", input: 505_000, cached: 400_000, output: 20_500),
        ], to: "2026/08/13/rollout-sub.jsonl")

        let store = try EventStore.inMemory()
        _ = SyncEngine(store: store, claudeRoot: dir.url.appendingPathComponent("none"),
                       codexRoot: dir.url, kimiRoots: []).sync()
        XCTAssertEqual(try codexTotal(store), 5_500)
    }

    /// The other half of the contract: a genuine fresh session's first snapshot
    /// **is** its first turn, and must still be counted.
    func testFreshSessionStillCountsItsFirstSnapshot() throws {
        let dir = TempDir()
        _ = dir.write([
            meta(id: "fresh-1"),
            turnContext("2026-08-13T04:00:00.000Z", model: "gpt-5.6-sol"),
            tokenCount("2026-08-13T04:00:01.000Z", input: 1_000, cached: 0, output: 100),
            tokenCount("2026-08-13T04:00:02.000Z", input: 3_000, cached: 0, output: 300),
        ], to: "2026/08/13/rollout-fresh.jsonl")

        let store = try EventStore.inMemory()
        _ = SyncEngine(store: store, claudeRoot: dir.url.appendingPathComponent("none"),
                       codexRoot: dir.url, kimiRoots: []).sync()
        XCTAssertEqual(try codexTotal(store), 3_300, "a fresh session starts at zero — nothing to absorb")
    }

    /// The full-scan collector and the incremental sync must agree, or the
    /// report and the dashboard disagree about the same logs.
    func testFullScanCollectorAppliesTheSameRule() {
        let dir = TempDir()
        _ = dir.write([
            meta(id: "child-2", forkedFrom: "parent-2"),
            tokenCount("2026-08-13T04:00:01.000Z", input: 1_000_000, cached: 900_000, output: 50_000),
            tokenCount("2026-08-13T04:00:02.000Z", input: 1_010_000, cached: 900_000, output: 51_000),
        ], to: "2026/08/13/rollout-child2.jsonl")

        let report = CodexCollector(sessionsRoot: dir.url).collect()
        XCTAssertEqual(report.tokens?.billableEquivalent, 11_000)
        XCTAssertEqual(report.stats.inheritedBaselinesAbsorbed, 1, "and it says it did so")
    }

    /// A subagent emits token_count long before its first `turn_context`, so
    /// those events have no model — which means no rate matches and no cost is
    /// reported. The name arrives later in the same file and applies backwards.
    func testModelAnnouncedLateIsAppliedToEarlierEvents() throws {
        let dir = TempDir()
        _ = dir.write([
            meta(id: "child-3", forkedFrom: "parent-3", subagent: true),
            tokenCount("2026-08-13T04:00:01.000Z", input: 1_000_000, cached: 900_000, output: 50_000),
            tokenCount("2026-08-13T04:00:02.000Z", input: 2_000_000, cached: 900_000, output: 50_000),
            // Only now does the file say what it is running.
            turnContext("2026-08-13T04:00:03.000Z", model: "gpt-5.6-sol"),
            tokenCount("2026-08-13T04:00:04.000Z", input: 3_000_000, cached: 900_000, output: 50_000),
        ], to: "2026/08/13/rollout-child3.jsonl")

        let store = try EventStore.inMemory()
        _ = SyncEngine(store: store, claudeRoot: dir.url.appendingPathComponent("none"),
                       codexRoot: dir.url, kimiRoots: []).sync()

        let models = try store.totalsByModel()
        XCTAssertEqual(models.map(\.model), ["gpt-5.6-sol"], "no event may be left without a model")
        // 2M fresh input across two turns, priced at gpt-5.6-sol's $5/Mtok.
        XCTAssertEqual(try XCTUnwrap(models[0].costUSD ?? nil), 10, accuracy: 1e-9,
                       "an event with no model matched no rate and reported no cost at all")
    }

    /// A file that genuinely switches models must not have the first one
    /// painted over the later turns.
    func testAModelSwitchIsNotRewrittenBackwards() throws {
        let dir = TempDir()
        _ = dir.write([
            meta(id: "fresh-2"),
            turnContext("2026-08-13T04:00:00.000Z", model: "gpt-5.6-sol"),
            tokenCount("2026-08-13T04:00:01.000Z", input: 1_000, cached: 0, output: 100),
            turnContext("2026-08-13T04:00:02.000Z", model: "gpt-5.6-luna"),
            tokenCount("2026-08-13T04:00:03.000Z", input: 2_000, cached: 0, output: 200),
        ], to: "2026/08/13/rollout-switch.jsonl")

        let store = try EventStore.inMemory()
        _ = SyncEngine(store: store, claudeRoot: dir.url.appendingPathComponent("none"),
                       codexRoot: dir.url, kimiRoots: []).sync()

        XCTAssertEqual(Set(try store.totalsByModel().map(\.model)), ["gpt-5.6-sol", "gpt-5.6-luna"])
    }
}

// MARK: - Timeline spans and live counters

final class ActivityTimelineTests: XCTestCase {

    private func add(_ store: EventStore, _ id: String, session: String, provider: String,
                     model: String?, at t: TimeInterval, billable: Int, cost: Decimal? = nil) throws {
        try store.insert(usage: AIEvent(
            id: id, timestamp: Date(timeIntervalSince1970: t), provider: provider, model: model,
            sessionId: session, project: "proj",
            tokens: TokenBreakdown(output: billable), costUSD: cost, confidence: .exact
        ), keepLargest: false)
    }

    /// The point of the span view: many records inside one stretch of work
    /// collapse to one row.
    func testContinuousRecordsCollapseIntoOneSpan() throws {
        let store = try EventStore.inMemory()
        for i in 0..<10 {
            try add(store, "e\(i)", session: "s1", provider: "Claude Code",
                    model: "claude-opus-5", at: 1_000_000 + Double(i) * 60, billable: 100, cost: 1)
        }
        let spans = try store.recentActivity()
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].events, 10)
        XCTAssertEqual(spans[0].billable, 1_000)
        XCTAssertEqual(spans[0].costUSD, 10)
        XCTAssertEqual(spans[0].duration, 540, accuracy: 1)
    }

    /// A long pause is a new stretch of work, not a continuation.
    func testAGapStartsANewSpan() throws {
        let store = try EventStore.inMemory()
        try add(store, "a", session: "s1", provider: "Claude Code", model: "m", at: 1_000_000, billable: 100)
        try add(store, "b", session: "s1", provider: "Claude Code", model: "m", at: 1_000_060, billable: 100)
        // Two hours later.
        try add(store, "c", session: "s1", provider: "Claude Code", model: "m", at: 1_007_200, billable: 100)

        XCTAssertEqual(try store.recentActivity(gap: 300).count, 2)
        XCTAssertEqual(try store.recentActivity(gap: 4 * 3600).count, 1, "a wider gap merges them again")
    }

    /// The regression the grouped implementation exists for: two tools running
    /// at once interleave in time, and a single-pass walk broke the span every
    /// time the other tool wrote a record.
    func testConcurrentToolsDoNotFragmentEachOther() throws {
        let store = try EventStore.inMemory()
        for i in 0..<8 {
            let t = 1_000_000 + Double(i) * 30
            try add(store, "c\(i)", session: "claude", provider: "Claude Code", model: "claude-opus-5", at: t, billable: 100)
            try add(store, "k\(i)", session: "kimi", provider: "Kimi Code", model: "k3-agent", at: t + 15, billable: 50)
        }
        let spans = try store.recentActivity()
        XCTAssertEqual(spans.count, 2, "one span per tool, not sixteen fragments")
        XCTAssertEqual(spans.first(where: { $0.provider == "Claude Code" })?.events, 8)
        XCTAssertEqual(spans.first(where: { $0.provider == "Kimi Code" })?.billable, 400)
    }

    /// A model switch inside one session is a new stretch: it is the thing a
    /// reader most wants the timeline to show.
    func testAModelSwitchSplitsTheSpan() throws {
        let store = try EventStore.inMemory()
        try add(store, "a", session: "s1", provider: "Codex CLI", model: "gpt-5.6-sol", at: 1_000_000, billable: 100)
        try add(store, "b", session: "s1", provider: "Codex CLI", model: "gpt-5.6-luna", at: 1_000_060, billable: 100)
        XCTAssertEqual(try store.recentActivity().count, 2)
    }

    func testSpansComeBackNewestFirst() throws {
        let store = try EventStore.inMemory()
        try add(store, "old", session: "s1", provider: "Claude Code", model: "m", at: 1_000_000, billable: 100)
        try add(store, "new", session: "s2", provider: "Claude Code", model: "m", at: 2_000_000, billable: 100)
        let spans = try store.recentActivity()
        XCTAssertEqual(spans.map(\.sessionId), ["s2", "s1"])
    }
}

final class LiveCounterTests: XCTestCase {

    private func add(_ store: EventStore, _ id: String, session: String, at: Date, billable: Int) throws {
        try store.insert(usage: AIEvent(
            id: id, timestamp: at, provider: "Claude Code", model: "claude-opus-5",
            sessionId: session, tokens: TokenBreakdown(output: billable),
            costUSD: nil, confidence: .estimated
        ), keepLargest: false)
    }

    func testRateIsMeasuredOverTheWindowAndSessionTotalIsNot() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        // Old work in the same session, outside the burst window.
        try add(store, "old", session: "s1", at: now.addingTimeInterval(-3600), billable: 900)
        // Recent work: 600 tokens inside a 5-minute window == 120/min.
        try add(store, "new", session: "s1", at: now.addingTimeInterval(-60), billable: 600)

        let live = try store.liveCounters(now: now, window: 300)
        XCTAssertEqual(live.recentBillable, 600, "the rate window excludes the older work")
        XCTAssertEqual(try XCTUnwrap(live.tokensPerMinute), 120, accuracy: 0.001)
        XCTAssertEqual(live.activeSessionBillable, 1_500, "but the session total is the whole conversation")
        XCTAssertEqual(live.activeSessionId, "s1")
        XCTAssertTrue(live.isLive)
    }

    /// An idle store reports no rate rather than a rate of zero — the same rule
    /// the rest of the tool follows about absence.
    func testAnIdleStoreReportsNoRate() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        let old = now.addingTimeInterval(-86_400)
        try add(store, "old", session: "s1", at: old, billable: 500)
        let live = try store.liveCounters(now: now)
        XCTAssertEqual(live.recentBillable, 0)
        XCTAssertNil(live.tokensPerMinute)
        XCTAssertFalse(live.isLive, "a day-old event is not a live session")
        XCTAssertEqual(live.activeSessionBillable, 500, "the last session's total is still readable")
        XCTAssertEqual(try XCTUnwrap(live.lastEventAt).timeIntervalSince1970,
                       old.timeIntervalSince1970, accuracy: 0.001,
                       "an idle store with history is not an empty store")
    }

    func testTheMostRecentSessionIsTheActiveOne() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        try add(store, "a", session: "older", at: now.addingTimeInterval(-120), billable: 100)
        try add(store, "b", session: "newer", at: now.addingTimeInterval(-10), billable: 200)
        XCTAssertEqual(try store.liveCounters(now: now).activeSessionId, "newer")
    }

    // MARK: Two tools at once

    private func add(
        _ store: EventStore, _ id: String, session: String, provider: String,
        at: Date, billable: Int
    ) throws {
        try store.insert(usage: AIEvent(
            id: id, timestamp: at, provider: provider, model: "m",
            sessionId: session, tokens: TokenBreakdown(output: billable),
            costUSD: nil, confidence: .estimated
        ), keepLargest: false)
    }

    /// Two tools writing in the same window are two live sessions. Reporting
    /// only the one that wrote last showed a fraction of the spend as if it
    /// were the whole of it.
    func testEveryProviderWritingInTheWindowGetsItsOwnRow() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        try add(store, "c1", session: "claude", provider: "Claude Code", at: now.addingTimeInterval(-30), billable: 700)
        try add(store, "x1", session: "codex", provider: "Codex CLI", at: now.addingTimeInterval(-90), billable: 300)

        let live = try store.liveCounters(now: now, window: 300)
        XCTAssertEqual(live.sessions.map(\.provider), ["Claude Code", "Codex CLI"],
                       "newest first, one row per tool")
        XCTAssertEqual(live.sessions.map(\.billable), [700, 300])
        XCTAssertTrue(live.sessions.allSatisfy(\.isLive))
    }

    /// The defect this file exists to prevent recurring: a row's rate must be
    /// its own. With Claude Code and Codex both running, the meter printed one
    /// session's lifetime total beside the machine's rate — "693.7k this
    /// session · 614.6k/min", a pace that would spend the session in 68
    /// seconds. Each figure was right; the line was not.
    func testEachRowsRateIsItsOwnSessionNotTheMachines() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        // Both sessions opened an hour ago, so each is rated over the whole
        // five-minute window rather than a slice of it.
        try add(store, "c0", session: "claude", provider: "Claude Code", at: now.addingTimeInterval(-3_600), billable: 900)
        try add(store, "x0", session: "codex", provider: "Codex CLI", at: now.addingTimeInterval(-3_600), billable: 900)
        // Claude spends 600 in the window; Codex spends 3000, five times as fast.
        try add(store, "c1", session: "claude", provider: "Claude Code", at: now.addingTimeInterval(-10), billable: 600)
        try add(store, "x1", session: "codex", provider: "Codex CLI", at: now.addingTimeInterval(-20), billable: 3_000)

        let live = try store.liveCounters(now: now, window: 300)
        let claude = try XCTUnwrap(live.sessions.first { $0.provider == "Claude Code" })
        let codex = try XCTUnwrap(live.sessions.first { $0.provider == "Codex CLI" })

        XCTAssertEqual(try XCTUnwrap(claude.tokensPerMinute), 120, accuracy: 0.5,
                       "600 tokens across five minutes of its own life")
        XCTAssertEqual(try XCTUnwrap(codex.tokensPerMinute), 600, accuracy: 0.5)
        XCTAssertEqual(claude.billable, 1_500, "the total is still the whole conversation")
        XCTAssertEqual(try XCTUnwrap(live.tokensPerMinute), 720, accuracy: 0.5,
                       "the machine-wide rate is the sum, and belongs to no row")
    }

    /// A young session must not be divided by a window it has not lived
    /// through: forty seconds and 400k tokens is not 80k/min.
    func testAYoungSessionIsRatedOverItsOwnLifeNotTheWholeWindow() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        try add(store, "a", session: "s1", at: now.addingTimeInterval(-40), billable: 400_000)
        let session = try XCTUnwrap(try store.liveCounters(now: now, window: 300).sessions.first)
        // Floored at one minute of evidence — below that the divisor is noise.
        XCTAssertEqual(try XCTUnwrap(session.tokensPerMinute), 400_000, accuracy: 1)
    }

    /// Three windows of the same tool are three conversations, not one with a
    /// badge. The per-provider shape collapsed them into a row whose "this
    /// session" total was one of the three and whose `×3` connected to nothing.
    func testConcurrentSessionsInOneProviderEachGetARow() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        try add(store, "a", session: "s1", at: now.addingTimeInterval(-60), billable: 100)
        try add(store, "b", session: "s2", at: now.addingTimeInterval(-20), billable: 200)
        try add(store, "c", session: "s3", at: now.addingTimeInterval(-10), billable: 300)
        let live = try store.liveCounters(now: now, window: 300)
        XCTAssertEqual(live.sessions.map(\.sessionId), ["s3", "s2", "s1"], "newest first")
        XCTAssertEqual(live.sessions.map(\.billable), [300, 200, 100],
                       "each row's total is its own session's")
        XCTAssertEqual(live.liveSessionCount, 3)
        XCTAssertEqual(live.hiddenSessions, 0)
    }

    /// Session ids come from each tool's own namespace. Two providers are
    /// allowed to choose the same value, and that must not merge their totals
    /// or give SwiftUI duplicate row identities.
    func testSessionIdentityIsQualifiedByProvider() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        try add(store, "c", session: "shared", provider: "Claude Code",
                at: now.addingTimeInterval(-20), billable: 100)
        try add(store, "x", session: "shared", provider: "Codex CLI",
                at: now.addingTimeInterval(-10), billable: 300)

        let live = try store.liveCounters(now: now, window: 300)
        XCTAssertEqual(live.liveSessionCount, 2)
        XCTAssertEqual(live.sessions.count, 2)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: live.sessions.map { ($0.provider, $0.billable) }),
                       ["Claude Code": 100, "Codex CLI": 300])
        XCTAssertEqual(Set(live.sessions.map(\.id)).count, 2,
                       "provider-local session ids still need unique row identities")
    }

    /// The rate window is five minutes, but "running" is deliberately a
    /// tighter two-minute claim. Sessions that stopped three or four minutes
    /// ago may contribute to the rate; they must not inflate the running count
    /// or the hidden-row caption.
    func testRecentButStoppedSessionsAreNotReportedAsStillRunning() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        try add(store, "live", session: "live", provider: "Codex CLI",
                at: now.addingTimeInterval(-10), billable: 300)
        try add(store, "old-a", session: "old-a", provider: "Claude Code",
                at: now.addingTimeInterval(-180), billable: 100)
        try add(store, "old-b", session: "old-b", provider: "Kimi Code",
                at: now.addingTimeInterval(-240), billable: 100)

        let live = try store.liveCounters(now: now, window: 300, limit: 1)
        XCTAssertEqual(live.liveSessionCount, 1)
        XCTAssertEqual(live.sessions.map(\.sessionId), ["live"])
        XCTAssertEqual(live.hiddenSessions, 0,
                       "stopped sessions must not become a 'more running' caption")
        XCTAssertEqual(live.recentBillable, 500,
                       "the wider rate window still includes recent completed work")
    }

    /// With no live work, the last conversation remains useful as an idle
    /// reference row. It is not one hidden running session.
    func testIdleFallbackDoesNotCreateAHiddenRunningCount() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        try add(store, "old-a", session: "old-a", provider: "Claude Code",
                at: now.addingTimeInterval(-180), billable: 100)
        try add(store, "old-b", session: "old-b", provider: "Codex CLI",
                at: now.addingTimeInterval(-240), billable: 200)

        let live = try store.liveCounters(now: now, window: 300, limit: 1)
        XCTAssertEqual(live.liveSessionCount, 0)
        XCTAssertEqual(live.sessions.map(\.sessionId), ["old-a"])
        XCTAssertFalse(try XCTUnwrap(live.sessions.first).isLive)
        XCTAssertEqual(live.hiddenSessions, 0)
    }

    /// A cap that says nothing is indistinguishable from "this is all of it".
    func testTheRowCapIsDisclosedRatherThanSilent() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        for i in 0..<6 {
            try add(store, "e\(i)", session: "s\(i)", at: now.addingTimeInterval(-Double(i) * 10), billable: 100)
        }
        let live = try store.liveCounters(now: now, window: 300, limit: 4)
        XCTAssertEqual(live.sessions.count, 4, "only four are shown")
        XCTAssertEqual(live.liveSessionCount, 6, "but six are running")
        XCTAssertEqual(live.hiddenSessions, 2)
        XCTAssertEqual(live.sessions.map(\.sessionId), ["s0", "s1", "s2", "s3"],
                       "the cap keeps the newest, not an arbitrary four")
    }

    /// "At most limit" includes zero. This is useful to callers that need the
    /// machine-wide state without materializing rows, and must not silently
    /// turn into one row via `max(1, limit)`.
    func testAZeroRowLimitStillReportsTheHiddenLiveCount() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        try add(store, "a", session: "s1", at: now.addingTimeInterval(-10), billable: 100)

        let live = try store.liveCounters(now: now, window: 300, limit: 0)
        XCTAssertTrue(live.sessions.isEmpty)
        XCTAssertEqual(live.liveSessionCount, 1)
        XCTAssertEqual(live.hiddenSessions, 1)
        XCTAssertTrue(live.isLive, "the machine is live even when the caller requests no rows")
    }

    /// Claude Code writes `<synthetic>` records — locally generated turns worth
    /// zero tokens. Whichever record is last decides the row's label, so a
    /// session that ended on one introduced itself as "Claude Code ·
    /// <synthetic>" while it had been spending Opus money all along.
    func testTheRowIsLabelledWithTheNewestModelThatActuallyBilled() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        try add(store, "real", session: "s1", at: now.addingTimeInterval(-60), billable: 5_000)
        try store.insert(usage: AIEvent(
            id: "placeholder", timestamp: now.addingTimeInterval(-5), provider: "Claude Code",
            model: "<synthetic>", sessionId: "s1", tokens: TokenBreakdown(),
            costUSD: nil, confidence: .estimated
        ), keepLargest: false)

        let session = try XCTUnwrap(try store.liveCounters(now: now, window: 300).sessions.first)
        XCTAssertEqual(session.model, "claude-opus-5")
    }

    /// Cost is summed per session, and stays nil rather than becoming a zero
    /// when nothing in the conversation priced.
    func testSessionCostIsSummedAndAbsenceIsNotZero() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        for (i, cost) in [0.25, 0.75].enumerated() {
            try store.insert(usage: AIEvent(
                id: "p\(i)", timestamp: now.addingTimeInterval(-Double(i) * 10 - 10),
                provider: "Claude Code", model: "claude-opus-5", sessionId: "priced",
                tokens: TokenBreakdown(output: 100), costUSD: Decimal(cost), confidence: .exact
            ), keepLargest: false)
        }
        try add(store, "u", session: "unpriced", at: now.addingTimeInterval(-5), billable: 100)

        let live = try store.liveCounters(now: now, window: 300)
        let priced = try XCTUnwrap(live.sessions.first { $0.sessionId == "priced" })
        let unpriced = try XCTUnwrap(live.sessions.first { $0.sessionId == "unpriced" })
        XCTAssertEqual(try XCTUnwrap(priced.costUSD), 1.0, accuracy: 0.0001)
        XCTAssertNil(unpriced.costUSD, "unpriced is not free")
    }

    /// The project slug earns its width only when it is the thing telling two
    /// rows apart.
    func testTheProjectSlugAppearsOnlyWhenItDisambiguates() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        try store.insert(usage: AIEvent(
            id: "a", timestamp: now.addingTimeInterval(-30), provider: "Claude Code",
            model: "claude-opus-5", sessionId: "s1", project: "trotflow",
            tokens: TokenBreakdown(output: 100), costUSD: nil, confidence: .estimated
        ), keepLargest: false)
        try store.insert(usage: AIEvent(
            id: "b", timestamp: now.addingTimeInterval(-20), provider: "Codex CLI",
            model: "gpt-5.6-terra", sessionId: "s2", project: "aimonitor",
            tokens: TokenBreakdown(output: 100), costUSD: nil, confidence: .estimated
        ), keepLargest: false)

        var live = try store.liveCounters(now: now, window: 300)
        XCTAssertNil(StoreReport.liveRowProject(of: live.sessions[0], among: live.sessions),
                     "two different tools already tell themselves apart")

        try store.insert(usage: AIEvent(
            id: "c", timestamp: now.addingTimeInterval(-10), provider: "Claude Code",
            model: "claude-opus-5", sessionId: "s3", project: "aimonitor",
            tokens: TokenBreakdown(output: 100), costUSD: nil, confidence: .estimated
        ), keepLargest: false)
        live = try store.liveCounters(now: now, window: 300)
        let claudeRows = live.sessions.filter { $0.provider == "Claude Code" }
        XCTAssertEqual(claudeRows.count, 2)
        XCTAssertEqual(
            claudeRows.compactMap { StoreReport.liveRowProject(of: $0, among: live.sessions) }.sorted(),
            ["aimonitor", "trotflow"],
            "now the directory is the only thing distinguishing them")
    }

    // MARK: Clocks that disagree

    /// Log timestamps are not guaranteed to be behind this clock — a session
    /// synced from another machine, a server-stamped record, or NTP drift.
    /// A future-stamped record must not produce a negative displayed age.
    func testAnEventStampedInTheFutureHasAnAgeOfZeroNotANegativeOne() {
        let now = Date()
        let ahead = now.addingTimeInterval(422)
        XCTAssertEqual(StoreReport.age(of: ahead, now: now), 0)
        XCTAssertEqual(StoreReport.ageText(of: ahead, now: now), "0s")
        XCTAssertEqual(StoreReport.ageText(of: now.addingTimeInterval(-90), now: now), "1m")
        XCTAssertEqual(StoreReport.ageText(of: now.addingTimeInterval(-4_920), now: now), "1h 22m")
    }

    /// And the same timestamp must not invert the rate: a span measured to an
    /// end earlier than its start would divide by a negative number.
    func testAFutureStampedEventStaysLiveAndKeepsAPositiveRate() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        try add(store, "a", session: "s1", at: now.addingTimeInterval(60), billable: 90_000)
        let session = try XCTUnwrap(try store.liveCounters(now: now, window: 300).sessions.first)
        XCTAssertTrue(session.isLive, "a record from a clock a minute fast is still live work")
        XCTAssertGreaterThan(try XCTUnwrap(session.tokensPerMinute), 0)
        XCTAssertFalse(session.clockDisagrees, "a minute is drift, and drift is not worth a caption")
    }

    /// Flooring stops a negative age; a separate skew indicator preserves the
    /// information that a source timestamp is substantially ahead.
    func testAClockTooFarAheadIsDisclosedRatherThanFlooredIntoJustNow() throws {
        let store = try EventStore.inMemory()
        let now = Date()
        try add(store, "a", session: "s1", at: now.addingTimeInterval(58 * 60), billable: 1_000)
        let live = try store.liveCounters(now: now, window: 300)
        let session = try XCTUnwrap(live.sessions.first)
        XCTAssertTrue(session.clockDisagrees)
        XCTAssertFalse(session.isLive,
                       "an untrusted future timestamp is not proof that work is happening now")
        XCTAssertEqual(live.liveSessionCount, 0)
        XCTAssertEqual(live.recentBillable, 0,
                       "a record 58 minutes ahead cannot belong to the last five minutes")
        XCTAssertNil(live.tokensPerMinute)
        XCTAssertEqual(session.recentBillable, 0)
        XCTAssertNil(session.tokensPerMinute)
        XCTAssertEqual(session.clockSkew, 58 * 60, accuracy: 1)
        XCTAssertEqual(StoreReport.shortDuration(session.clockSkew), "58m")
        // Quantized, so a skewed session does not re-publish on every tick.
        XCTAssertEqual(
            EventStore.quantizedSkew(of: now.addingTimeInterval(3_490), now: now),
            EventStore.quantizedSkew(of: now.addingTimeInterval(3_495), now: now),
            "five seconds of drift inside one minute is not a new reading")
        XCTAssertEqual(StoreReport.ageText(of: session.lastEventAt, now: now), "0s",
                       "the floor still holds — the caption is what stops it being read as a fact")
    }
}

// MARK: - Store permissions

/// The store is a complete record of when this person works, for how long, on
/// which projects by directory name, and at what cost. SQLite creates it with
/// the process umask — 0644 on macOS, readable by every other local account —
/// and "local" is not the same claim as "private", which is the one PRIVACY.md
/// makes. The credential files this tool *reads* are 0600; the file it writes
/// should not be looser than its own sources.
final class StorePermissionTests: XCTestCase {

    private func mode(_ path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    func testStoreIsOwnerOnlyOnDisk() throws {
        let dir = TempDir()
        let path = dir.url.appendingPathComponent("store.db").path
        let store = try EventStore(path: path)
        // Write something so the -wal companion exists too.
        try store.insert(usage: AIEvent(
            id: "e", timestamp: Date(), provider: "Claude Code", model: "claude-opus-5",
            tokens: TokenBreakdown(output: 10), costUSD: nil, confidence: .estimated
        ), keepLargest: false)

        XCTAssertEqual(try mode(path) & 0o077, 0, "group and other must have no access to the store")
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            XCTAssertEqual(try mode(path + suffix) & 0o077, 0, "\(suffix) leaks what the store does not")
        }
        XCTAssertEqual(try mode(dir.url.path) & 0o077, 0, "the containing directory must not be listable")
    }

    /// Reopening must not loosen anything, and must not fail on a store that is
    /// already locked down.
    func testReopeningKeepsThePermissions() throws {
        let dir = TempDir()
        let path = dir.url.appendingPathComponent("store.db").path
        _ = try EventStore(path: path)
        _ = try EventStore(path: path)
        XCTAssertEqual(try mode(path) & 0o077, 0)
    }
}
