import XCTest
@testable import TBDSpeech

final class LibraryInsightsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let now = ISO8601DateFormatter().date(from: "2026-10-12T15:00:00Z")!

    private func daysAgo(_ days: Int, hour: Int = 10) -> Date {
        calendar.date(byAdding: .day, value: -days, to: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!)!
    }

    func testInsightsTotalsStreaksHeatmapAndTopApps() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        // Yesterday and the two days before (no dictation today yet): current streak 3.
        for days in [1, 2, 3] {
            try db.save(TBDDictation(createdAt: daysAgo(days), durationMs: 60_000, rawText: Array(repeating: "w", count: 120).joined(separator: " "), targetApp: "Mail"))
        }
        // An older run of four days: longest streak 4.
        for days in [10, 11, 12, 13] { try db.save(TBDDictation(createdAt: daysAgo(days), durationMs: 30_000, rawText: "a b c", targetApp: "Slack")) }
        try db.save(TBDDictation(createdAt: daysAgo(1, hour: 12), durationMs: 10_000, rawText: "note text", targetApp: "TBD Voice note"))
        try db.save(TBDDictation(createdAt: daysAgo(400), durationMs: 1_000, rawText: "  ", targetApp: "Mail"))   // blank: ignored

        let insights = try db.dictationInsights(now: now, calendar: calendar)
        XCTAssertEqual(insights.count, 8)
        XCTAssertEqual(insights.words, 3 * 120 + 4 * 3 + 2)
        XCTAssertEqual(insights.currentStreak, 3, "a streak survives until today ends")
        XCTAssertEqual(insights.longestStreak, 4)
        XCTAssertEqual(insights.longestMs, 60_000)
        XCTAssertEqual(insights.days.count, TBDDictationInsights.heatmapDays)
        XCTAssertEqual(insights.days.last?.date, calendar.startOfDay(for: now))
        XCTAssertEqual(insights.days[insights.days.count - 2].count, 2, "yesterday had two dictations")
        XCTAssertEqual(insights.topApps.map(\.name), ["Slack", "Mail"], "voice notes are not apps")
        XCTAssertEqual(insights.topApps.first?.count, 4)
    }

    func testDerivedFigures() {
        var insights = TBDDictationInsights()
        insights.words = 400
        insights.durationMs = 120_000
        XCTAssertEqual(insights.wordsPerMinute, 200)
        XCTAssertEqual(insights.speedDescription, "Lightning speed")
        XCTAssertEqual(insights.timeSavedMs, 600_000 - 120_000, "40 WPM typing")
        XCTAssertEqual(insights.wordsDescription, "2 emails worth")
        insights.words = 100
        XCTAssertEqual(insights.wordsDescription, "Keep going!")
        XCTAssertEqual([0, 1, 2, 3, 4, 7, 8, 30].map(TBDDictationInsights.level), [0, 1, 2, 2, 3, 3, 4, 4])
        let active: Set<Date> = [calendar.startOfDay(for: now)]
        XCTAssertEqual(TBDDictationInsights.currentStreak(active, today: now, calendar: calendar), 1)
        XCTAssertEqual(TBDDictationInsights.currentStreak([], today: now, calendar: calendar), 0)
    }

    func testLibrarySortAndDateGroups() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        for (title, days) in [("beta", 0), ("Alpha", 3), ("gamma", 40)] {
            var item = TBDTranscription(title: title, sourceKind: .file, status: .completed)
            item.createdAt = daysAgo(days)
            item.rawText = "shared words"
            try db.save(item)
        }
        XCTAssertEqual(try db.transcriptions(sort: .newest).map(\.title), ["beta", "Alpha", "gamma"])
        XCTAssertEqual(try db.transcriptions(sort: .oldest).map(\.title), ["gamma", "Alpha", "beta"])
        XCTAssertEqual(try db.transcriptions(sort: .title).map(\.title), ["Alpha", "beta", "gamma"])
        XCTAssertEqual(try db.transcriptions(matching: "shared", sort: .title).map(\.title), ["Alpha", "beta", "gamma"])

        XCTAssertEqual(TBDDateGroup.of(daysAgo(0), now: now, calendar: calendar), .today)
        XCTAssertEqual(TBDDateGroup.of(daysAgo(1), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(TBDDateGroup.of(daysAgo(5), now: now, calendar: calendar), .previous7)
        XCTAssertEqual(TBDDateGroup.of(daysAgo(20), now: now, calendar: calendar), .previous30)
        XCTAssertEqual(TBDDateGroup.of(daysAgo(60), now: now, calendar: calendar), .month(year: 2026, month: 8))
        XCTAssertEqual([TBDDateGroup.month(year: 2025, month: 1), .previous30, .today, .month(year: 2026, month: 3)].sorted(),
                       [.today, .previous30, .month(year: 2026, month: 3), .month(year: 2025, month: 1)])
    }

    func testDictationMatchCount() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        try db.save(TBDDictation(durationMs: 1, rawText: "quarterly budget review"))
        try db.save(TBDDictation(durationMs: 1, rawText: "lunch plans"))
        XCTAssertEqual(try db.dictationMatchCount("budg"), 1)
        XCTAssertEqual(try db.dictationMatchCount(""), 0)
    }
}
