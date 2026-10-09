import XCTest
@testable import AIMonitorCore

final class ReceiptTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    /// 2026-10-03 13:30 local.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 13, minute: 30))!
    }

    private func event(_ id: String, daysAgo: Int, hour: Int = 10, model: String, provider: String,
                       tokens: Int, cost: String?) -> AIEvent {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        return AIEvent(
            id: id, timestamp: calendar.date(byAdding: .hour, value: hour, to: day),
            provider: provider, model: model, sessionId: "s-\(provider)",
            tokens: TokenBreakdown(output: tokens), costUSD: cost.flatMap { Decimal(string: $0) },
            confidence: .estimated)
    }

    private func store(_ events: [AIEvent]) throws -> EventStore {
        let s = try EventStore.inMemory()
        for e in events { try s.insert(usage: e, keepLargest: false) }
        return s
    }

    /// The one-day slip is the hero's "today" by construction — same rows, same
    /// sum — so the two can never be read side by side and disagree.
    func testOneDayTotalMatchesDashboardToday() throws {
        let s = try store([
            event("a", daysAgo: 0, model: "m-a", provider: "Claude Code", tokens: 1000, cost: "1.25"),
            event("b", daysAgo: 0, hour: 12, model: "m-b", provider: "Codex CLI", tokens: 500, cost: "0.50"),
            event("c", daysAgo: 1, model: "m-a", provider: "Claude Code", tokens: 9000, cost: "9.00"),
        ])
        let r = try s.receipt(.day, now: now, calendar: calendar)
        let today = try s.totals(since: calendar.startOfDay(for: now))
        XCTAssertEqual(r.totalTokens, today.billable)
        XCTAssertEqual(r.totalRequests, today.requests)
        XCTAssertEqual(r.pricedCostUSD ?? -1, today.costUSD ?? -2, accuracy: 1e-9)
        XCTAssertEqual(r.days.count, 1)
        XCTAssertEqual(r.items.map(\.model), ["m-a", "m-b"], "most expensive line first")
    }

    /// An unpriced model is a line with tokens and no price — never $0.00 — and
    /// it is left out of the money total while still counted in tokens.
    func testUnpricedLineIsListedButNotSummedAsZero() throws {
        let s = try store([
            event("a", daysAgo: 0, model: "priced", provider: "Claude Code", tokens: 100, cost: "2.00"),
            event("b", daysAgo: 0, model: "mystery", provider: "Kimi Code", tokens: 5000, cost: nil),
        ])
        let r = try s.receipt(.day, now: now, calendar: calendar)
        XCTAssertEqual(r.items.map(\.model), ["priced", "mystery"], "priced lines before unpriced ones")
        XCTAssertNil(r.items[1].costUSD)
        XCTAssertEqual(r.unpricedItems, 1)
        XCTAssertEqual(r.unpricedTokens, 5000)
        XCTAssertEqual(r.totalTokens, 5100)
        XCTAssertEqual(r.pricedCostUSD ?? 0, 2.0, accuracy: 1e-9)
    }

    /// A zero-token model (Claude Code's `<synthetic>`) is not a purchase: no
    /// line, and not counted as an unpriced item.
    func testZeroTokenModelIsNotALine() throws {
        let s = try store([
            event("a", daysAgo: 0, model: "priced", provider: "Claude Code", tokens: 100, cost: "1"),
            event("b", daysAgo: 0, model: "<synthetic>", provider: "Claude Code", tokens: 0, cost: nil),
        ])
        let r = try s.receipt(.day, now: now, calendar: calendar)
        XCTAssertEqual(r.items.map(\.model), ["priced"])
        XCTAssertEqual(r.unpricedItems, 0)
    }

    /// Nothing priced at all is "no price", not a $0 bill.
    func testAllUnpricedHasNoMoneyTotal() throws {
        let s = try store([event("a", daysAgo: 0, model: "mystery", provider: "Kimi Code", tokens: 10, cost: nil)])
        XCTAssertNil(try s.receipt(.day, now: now, calendar: calendar).pricedCostUSD)
    }

    /// Seven days, oldest first, each one present — the quiet ones at zero —
    /// and an event eight days back is outside the slip.
    func testWeekHasSevenDaysOldestFirstIncludingQuietOnes() throws {
        let s = try store([
            event("old", daysAgo: 7, model: "m", provider: "Claude Code", tokens: 99_999, cost: "99"),
            event("d6", daysAgo: 6, model: "m", provider: "Claude Code", tokens: 600, cost: "6"),
            event("d2", daysAgo: 2, model: "m", provider: "Claude Code", tokens: 200, cost: "2"),
            event("d0", daysAgo: 0, model: "m", provider: "Claude Code", tokens: 10, cost: "0.1"),
        ])
        let r = try s.receipt(.week, now: now, calendar: calendar)
        XCTAssertEqual(r.days.count, 7)
        XCTAssertEqual(r.days.map(\.tokens), [600, 0, 0, 0, 200, 0, 10])
        XCTAssertNil(r.days[1].costUSD, "a closed day has no price, not $0 of usage")
        XCTAssertEqual(r.days.first?.start, calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)))
        XCTAssertEqual(r.totalTokens, 810, "the event eight days back is not on the slip")
        XCTAssertEqual(r.days.reduce(0) { $0 + $1.tokens }, r.totalTokens, "days and items add up to the same thing")
    }

    /// A day that is 23 hours long (clocks go forward) is still one bucket.
    func testDaysFollowTheCalendarAcrossAClockChange() throws {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 is the US spring-forward day.
        let monday = ny.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!
        let late = ny.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23, minute: 30))!
        let s = try EventStore.inMemory()
        try s.insert(usage: AIEvent(id: "x", timestamp: late, provider: "Claude Code", model: "m",
                                    tokens: TokenBreakdown(output: 42), costUSD: 1, confidence: .estimated),
                     keepLargest: false)
        let r = try s.receipt(.week, now: monday, calendar: ny)
        XCTAssertEqual(r.days[5].tokens, 42, "23:30 on the short day belongs to that day, not the next")
    }

    /// Re-reading within the same minute with nothing new is the same slip —
    /// that equality is what keeps the page from redrawing every tick.
    func testSameMinuteSameSlip() throws {
        let s = try store([event("a", daysAgo: 0, model: "m", provider: "Claude Code", tokens: 1, cost: "1")])
        let a = try s.receipt(.day, now: now, calendar: calendar)
        let b = try s.receipt(.day, now: now.addingTimeInterval(20), calendar: calendar)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.number.count, 7)
    }
}
