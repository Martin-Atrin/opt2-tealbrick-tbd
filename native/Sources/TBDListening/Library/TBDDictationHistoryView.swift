import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// Dictation history with simple stats.
struct TBDDictationHistoryView: View {
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var query = ""
    @State private var items: [TBDDictation] = []
    @State private var stats = TBDListeningDatabase.DictationStats()

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            HStack(spacing: TBDTokens.Space.xl) {
                stat("Dictations", "\(stats.count)")
                stat("Today", "\(stats.today)")
                stat("Words", stats.words.formatted())
                stat("Speaking time", TBDExport.clock(stats.durationMs))
                stat("Words per minute", "\(stats.wordsPerMinute)")
                Spacer()
                Button("Clear history", role: .destructive) { clear() }.buttonStyle(TBDButtonStyle(.destructive)).disabled(items.isEmpty)
            }
            .tbdCard(padding: TBDTokens.Space.md)
            HStack(spacing: TBDTokens.Space.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(TBDTokens.muted)
                TextField("Search dictations", text: $query).textFieldStyle(.plain)
            }
            .tbdField().frame(maxWidth: 360)
            if !env.preferences.keepHistory {
                Text("History is off. Turn it on in Settings → Listening → System.").foregroundStyle(TBDTokens.muted)
            }
            if items.isEmpty {
                Text(query.isEmpty ? "Hold your dictation hotkey (\(env.preferences.dictationHotkey)) to dictate into any app." : "No matches.")
                    .foregroundStyle(TBDTokens.muted).font(TBDTokens.Typography.body)
                Spacer()
            } else {
                List(items) { item in row(item) }.listStyle(.inset).scrollContentBackground(.hidden)
            }
        }
        .task(id: "\(query)|\(env.revision)") {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            items = (try? env.database?.dictations(matching: query)) ?? []
            stats = (try? env.database?.dictationStats()) ?? stats
        }
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
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let app = item.targetApp { Text(app) }
                    Text("\(item.wordCount) words")
                    if item.cleanText != nil { Text("Cleaned") }
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
