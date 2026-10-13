import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// Dictation history (grouped by day, searchable) and stats.
struct TBDDictationHistoryView: View {
    enum SubTab: String, CaseIterable { case history = "History", stats = "Stats" }
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var items: [TBDDictation] = []
    @State private var stats = TBDListeningDatabase.DictationStats()
    @State private var insights = TBDDictationInsights()
    @State private var tab: SubTab = .history

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            HStack(spacing: TBDTokens.Space.md) {
                Picker("", selection: $tab) { ForEach(SubTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                HStack(spacing: TBDTokens.Space.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(TBDTokens.muted)
                    TextField("Search dictations", text: $env.dictationQuery).textFieldStyle(.plain)
                }
                .tbdField().frame(maxWidth: 320)
                Spacer()
                Button("Clear history", role: .destructive) { clear() }.buttonStyle(TBDButtonStyle(.destructive)).disabled(items.isEmpty)
            }
            if tab == .stats {
                TBDDictationStatsView(insights: insights)
            } else {
                HStack(spacing: TBDTokens.Space.xl) {
                    stat("Dictations", "\(stats.count)")
                    stat("Today", "\(stats.today)")
                    stat("Words", stats.words.formatted())
                    stat("Words per minute", "\(stats.wordsPerMinute)")
                    stat("Streak", insights.currentStreak == 1 ? "1 day" : "\(insights.currentStreak) days")
                }
                if !env.preferences.keepHistory {
                    Text("History is off. Turn it on in Settings → Listening → System.").foregroundStyle(TBDTokens.muted)
                }
                if items.isEmpty {
                    Text(env.dictationQuery.isEmpty ? "Your voice, captured. Hold your dictation hotkey (\(env.preferences.pushToTalkHotkeyLabel)) to dictate into any app."
                         : "No matching records. Try different words or clear your search.")
                        .foregroundStyle(TBDTokens.muted).font(TBDTokens.Typography.body)
                    Spacer()
                } else {
                    List {
                        ForEach(Self.days(items), id: \.0) { day, entries in
                            Section(Self.dayTitle(day)) { ForEach(entries) { row($0) } }
                        }
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden)
                }
            }
        }
        .onChange(of: env.dictationQuery) { _, query in if !query.isEmpty { tab = .history } }
        .task(id: "\(env.dictationQuery)|\(env.revision)") {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            items = (try? env.database?.dictations(matching: env.dictationQuery)) ?? []
            stats = (try? env.database?.dictationStats()) ?? stats
            insights = (try? env.database?.dictationInsights()) ?? insights
        }
    }

    static func days(_ items: [TBDDictation]) -> [(Date, [TBDDictation])] {
        let calendar = Calendar.current
        return Dictionary(grouping: items) { calendar.startOfDay(for: $0.createdAt) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.createdAt > $1.createdAt }) }
    }

    static func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TBDLabel(label)
            Text(value).font(TBDTokens.Typography.title).foregroundStyle(TBDTokens.ink)
        }
    }

    private func row(_ item: TBDDictation) -> some View {
        HStack(alignment: .top, spacing: TBDTokens.Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text).font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.ink).textSelection(.enabled).lineLimit(4)
                HStack(spacing: TBDTokens.Space.sm) {
                    Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                    if let app = item.targetApp { Text(app) }
                    Text("\(item.wordCount) words")
                    if item.cleanText != nil { Text("Cleaned") }
                    if item.status == .cancelled { Text("Cancelled, not pasted") }
                }
                .font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
            }
            Spacer()
            Button { TBDPasteService.copy(item.text) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(TBDButtonStyle(.icon)).help("Copy").accessibilityLabel("Copy dictation")
            if item.cleanText != nil {
                Button { TBDPasteService.copy(item.rawText) } label: { Image(systemName: "text.quote") }
                    .buttonStyle(TBDButtonStyle(.icon)).help("Copy raw transcript").accessibilityLabel("Copy raw transcript")
            }
            Button { delete(item) } label: { Image(systemName: "trash") }
                .buttonStyle(TBDButtonStyle(.icon)).help("Delete").accessibilityLabel("Delete dictation")
        }
        .padding(.vertical, 4)
    }

    private func delete(_ item: TBDDictation) {
        if let path = item.audioPath, path.hasPrefix(TBDListeningPaths.root.path) { try? FileManager.default.removeItem(atPath: path) }
        try? env.database?.deleteDictation(id: item.id)
        env.changed()
    }

    private func clear() {
        let alert = NSAlert()
        alert.messageText = "Clear all dictation history?"
        alert.informativeText = "Saved dictation audio is removed too. Library items are not affected."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for item in (try? env.database?.dictations(limit: .max)) ?? [] {
            if let path = item.audioPath, path.hasPrefix(TBDListeningPaths.root.path) { try? FileManager.default.removeItem(atPath: path) }
        }
        try? env.database?.deleteAllDictations()
        env.changed()
    }
}
