import Foundation
import GRDB

/// Dictation statistics: totals, speaking speed, time saved, streaks, a daily heatmap and top apps.
public struct TBDDictationInsights: Sendable, Equatable {
    public struct App: Sendable, Equatable { public let name: String; public let count: Int; public let words: Int }
    public struct Day: Sendable, Equatable { public let date: Date; public let count: Int; public let words: Int; public let durationMs: Int }

    /// Typing speed assumed for "time saved".
    public static let typingWordsPerMinute = 40.0
    public static let heatmapDays = 182

    public var count = 0
    public var words = 0
    public var durationMs = 0
    public var longestMs = 0
    public var currentStreak = 0
    public var longestStreak = 0
    public var topApps: [App] = []
    /// The last `heatmapDays` days, oldest first, zero-filled.
    public var days: [Day] = []

    public init() {}

    public var wordsPerMinute: Int { durationMs > 0 ? Int(Double(words) / (Double(durationMs) / 60_000)) : 0 }

    /// Typing time for the same words minus speaking time.
    public var timeSavedMs: Int { max(0, Int(Double(words) / Self.typingWordsPerMinute * 60_000) - durationMs) }

    public var speedDescription: String {
        switch wordsPerMinute {
        case ..<1: "—"
        case ..<80: "Thoughtful pace"
        case ..<120: "Conversational"
        case ..<160: "Brisk speaker"
        case ..<200: "Fast talker"
        default: "Lightning speed"
        }
    }

    public var wordsDescription: String {
        if words >= 80_000 { return String(format: "%.1f novels written", Double(words) / 80_000) }
        if words >= 200 { return "\(words / 200) emails worth" }
        return "Keep going!"
    }

    /// Heatmap level 0–4 for a day's dictation count.
    public static func level(_ count: Int) -> Int {
        switch count {
        case ..<1: 0
        case 1: 1
        case 2...3: 2
        case 4...7: 3
        default: 4
        }
    }

    /// Consecutive days ending today, or yesterday when today has none yet.
    static func currentStreak(_ active: Set<Date>, today: Date, calendar: Calendar) -> Int {
        var day = calendar.startOfDay(for: today)
        if !active.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while active.contains(day) {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    static func longestStreak(_ active: Set<Date>, calendar: Calendar) -> Int {
        var best = 0
        for day in active {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day), !active.contains(previous) else { continue }
            var length = 1
            var next = calendar.date(byAdding: .day, value: 1, to: day)!
            while active.contains(next) { length += 1; next = calendar.date(byAdding: .day, value: 1, to: next)! }
            best = max(best, length)
        }
        return best
    }
}

public enum TBDLibrarySort: String, CaseIterable, Sendable {
    case newest, oldest, title
    public var title: String {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .title: "Title"
        }
    }
}

/// Date sections of the library list.
public enum TBDDateGroup: Hashable, Sendable, Comparable {
    case today, yesterday, previous7, previous30, month(year: Int, month: Int)

    public static func of(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> TBDDateGroup {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return .today
        case 1: return .yesterday
        case 2...7: return .previous7
        case 8...30: return .previous30
        default:
            let parts = calendar.dateComponents([.year, .month], from: date)
            return .month(year: parts.year ?? 0, month: parts.month ?? 0)
        }
    }

    public var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7: return "Previous 7 days"
        case .previous30: return "Previous 30 days"
        case .month(let year, let month):
            let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
            return date.formatted(.dateTime.month(.wide).year())
        }
    }

    var sortKey: Int {
        switch self {
        case .today: Int.max
        case .yesterday: Int.max - 1
        case .previous7: Int.max - 2
        case .previous30: Int.max - 3
        case .month(let year, let month): year * 12 + month
        }
    }

    /// Newest section first.
    public static func < (lhs: TBDDateGroup, rhs: TBDDateGroup) -> Bool { lhs.sortKey > rhs.sortKey }
}

extension TBDListeningDatabase {
    public func dictationInsights(now: Date = Date(), calendar: Calendar = .current) throws -> TBDDictationInsights {
        try writer.read { db in
            var insights = TBDDictationInsights()
            let rows = try Row.fetchAll(db, sql: "SELECT createdAt, wordCount, durationMs FROM dictation WHERE TRIM(rawText) != ''")
            var byDay: [Date: (count: Int, words: Int, ms: Int)] = [:]
            for row in rows {
                let date: Date = row[0]
                let words: Int = row[1], ms: Int = row[2]
                insights.count += 1
                insights.words += words
                insights.durationMs += ms
                insights.longestMs = max(insights.longestMs, ms)
                let day = calendar.startOfDay(for: date)
                let current = byDay[day] ?? (0, 0, 0)
                byDay[day] = (current.count + 1, current.words + words, current.ms + ms)
            }
            let active = Set(byDay.keys)
            insights.currentStreak = TBDDictationInsights.currentStreak(active, today: now, calendar: calendar)
            insights.longestStreak = TBDDictationInsights.longestStreak(active, calendar: calendar)
            let today = calendar.startOfDay(for: now)
            insights.days = (0..<TBDDictationInsights.heatmapDays).reversed().map { offset in
                let day = calendar.date(byAdding: .day, value: -offset, to: today)!
                let value = byDay[day] ?? (0, 0, 0)
                return TBDDictationInsights.Day(date: day, count: value.count, words: value.words, durationMs: value.ms)
            }
            insights.topApps = try Row.fetchAll(db, sql: """
                SELECT targetApp, COUNT(*), COALESCE(SUM(wordCount), 0) FROM dictation
                WHERE kind = 'dictation' AND TRIM(rawText) != '' AND targetApp IS NOT NULL AND TRIM(targetApp) != ''
                GROUP BY targetApp ORDER BY COUNT(*) DESC, targetApp ASC LIMIT 5
                """).map { TBDDictationInsights.App(name: $0[0], count: $0[1], words: $0[2]) }
            return insights
        }
    }

    /// Library items sorted as asked (search keeps full-text matching).
    public func transcriptions(limit: Int = 500, kind: TBDSourceKind? = nil, matching query: String? = nil,
                               sort: TBDLibrarySort) throws -> [TBDTranscription] {
        guard Self.pattern(query) == nil else {
            let items = try transcriptions(limit: limit, kind: kind, matching: query)
            return Self.sorted(items, by: sort)
        }
        return try writer.read { db in
            var request = TBDTranscription.all()
            if let kind { request = request.filter(Column("sourceKind") == kind.rawValue) }
            switch sort {
            case .newest: request = request.order(Column("createdAt").desc)
            case .oldest: request = request.order(Column("createdAt").asc)
            case .title: request = request.order(sql: "title COLLATE NOCASE ASC, createdAt DESC")
            }
            return try request.limit(limit).fetchAll(db)
        }
    }

    static func sorted(_ items: [TBDTranscription], by sort: TBDLibrarySort) -> [TBDTranscription] {
        switch sort {
        case .newest: return items.sorted { $0.createdAt > $1.createdAt }
        case .oldest: return items.sorted { $0.createdAt < $1.createdAt }
        case .title:
            return items.sorted {
                let order = $0.title.localizedCaseInsensitiveCompare($1.title)
                return order == .orderedSame ? $0.createdAt > $1.createdAt : order == .orderedAscending
            }
        }
    }

    /// Number of dictations whose text matches `query`.
    public func dictationMatchCount(_ query: String) throws -> Int {
        guard let pattern = Self.pattern(query) else { return 0 }
        return try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dictation_ft WHERE dictation_ft MATCH ?", arguments: [pattern]) ?? 0
        }
    }
}
