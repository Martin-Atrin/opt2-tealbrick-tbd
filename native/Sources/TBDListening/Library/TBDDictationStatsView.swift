import SwiftUI
import TBDDesign
import TBDSpeech

/// Dictation stats: words, speed, speaking time, streaks with a 26-week heatmap, top apps.
struct TBDDictationStatsView: View {
    let insights: TBDDictationInsights

    var body: some View {
        if insights.count == 0 {
            Text("Your stats will appear here.").foregroundStyle(TBDColor.inkSoft).font(TBDTokens.Typography.body)
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: TBDTokens.Space.lg) {
                    HStack(alignment: .top, spacing: TBDTokens.Space.lg) {
                        tile("Total words", insights.words.formatted(.number.notation(.compactName)), insights.wordsDescription)
                        tile("Voice speed", "\(insights.wordsPerMinute) WPM", insights.speedDescription)
                        tile("Time speaking", Self.friendly(insights.durationMs),
                             insights.timeSavedMs >= 60_000 ? "Saved \(Self.friendly(insights.timeSavedMs)) typing"
                                : "\(insights.count) dictation\(insights.count == 1 ? "" : "s")")
                    }
                    streak
                    if !insights.topApps.isEmpty { apps }
                }
                .padding(.trailing, TBDTokens.Space.md)
            }
        }
    }

    private func tile(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
            TBDLabel(label)
            Text(value).font(TBDFonts.nunito(TBDKit.textH2, TBDKit.weightHead)).foregroundStyle(TBDColor.ink)
            Text(detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tbdCard(padding: TBDTokens.Space.md)
    }

    private var streak: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            HStack {
                Text(insights.currentStreak > 0 ? "\(insights.currentStreak) day streak" : "Build a streak")
                    .font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                Spacer()
                Text("Longest streak · \(insights.longestStreak) day\(insights.longestStreak == 1 ? "" : "s")")
                    .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
            heatmap
            HStack(spacing: 3) {
                Spacer()
                Text("Less").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
                ForEach(0..<5) { level in cell(level) }
                Text("More").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
            }
        }
        .tbdCard(padding: TBDTokens.Space.md)
    }

    /// Columns are weeks (oldest left), rows are weekdays.
    private var heatmap: some View {
        let calendar = Calendar.current
        let leading = insights.days.first.map { (calendar.component(.weekday, from: $0.date) - calendar.firstWeekday + 7) % 7 } ?? 0
        let padded: [TBDDictationInsights.Day?] = Array(repeating: nil, count: leading) + insights.days.map { $0 }
        let weeks = stride(from: 0, to: padded.count, by: 7).map { Array(padded[$0..<min($0 + 7, padded.count)]) }
        return HStack(alignment: .top, spacing: 3) {
            ForEach(weeks.indices, id: \.self) { index in
                VStack(spacing: 3) {
                    ForEach(weeks[index].indices, id: \.self) { row in
                        if let day = weeks[index][row] {
                            cell(TBDDictationInsights.level(day.count))
                                .help("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.count) dictation\(day.count == 1 ? "" : "s") · \(day.words) word\(day.words == 1 ? "" : "s") · \(Self.friendly(day.durationMs))")
                        } else {
                            Color.clear.frame(width: 10, height: 10)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ level: Int) -> some View {
        let opacity: Double = [0, 0.30, 0.55, 0.78, 1.0][min(4, max(0, level))]
        return RoundedRectangle(cornerRadius: TBDKit.radiusSwatch)
            .fill(level == 0 ? TBDColor.plate : TBDColor.teal.opacity(opacity))
            .frame(width: 10, height: 10)
    }

    private var apps: some View {
        let total = max(1, insights.topApps.reduce(0) { $0 + $1.count })
        let most = max(1, insights.topApps.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            HStack {
                Text("Where you dictate").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                Spacer()
                Text("Top \(insights.topApps.count) app\(insights.topApps.count == 1 ? "" : "s")").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
            ForEach(insights.topApps, id: \.name) { app in
                HStack(spacing: TBDTokens.Space.md) {
                    Text(app.name).font(TBDTokens.Typography.body).foregroundStyle(TBDColor.ink).frame(width: 140, alignment: .leading).lineLimit(1)
                    GeometryReader { geometry in
                        Capsule().fill(TBDColor.teal)
                            .frame(width: max(4, geometry.size.width * CGFloat(app.count) / CGFloat(most)), height: 6)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 12)
                    Text("\(Int((Double(app.count) / Double(total) * 100).rounded()))%").font(TBDFonts.mono())
                        .foregroundStyle(TBDColor.muted).frame(width: 40, alignment: .trailing)
                }
            }
        }
        .tbdCard(padding: TBDTokens.Space.md)
    }

    /// "45 sec", "1.5 min", "2.3 hr".
    static func friendly(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000
        if seconds < 60 { return "\(Int(seconds)) sec" }
        if seconds < 3600 { return String(format: "%.1f min", seconds / 60) }
        return String(format: "%.1f hr", seconds / 3600)
    }
}
