import SwiftUI
import TBDDesign
import TBDSpeech
import UniformTypeIdentifiers

/// The Listening tab: library, dictation history and meetings, with drag-and-drop transcription.
struct TBDListeningView: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var dropTargeted = false
    @State private var showPractice = false

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.lg) {
            TBDPageHeader("Listening", label: "Speech") {
                // The Transcribe page carries its own file, link and meeting controls.
                if env.selectedTab != .transcribe {
                    HStack(spacing: TBDTokens.Space.sm) {
                        Button { context.files.pickFiles() } label: { Label("Transcribe file", systemImage: "doc.badge.plus") }
                            .buttonStyle(TBDButtonStyle(.secondary))
                        Button { context.files.promptForURL() } label: { Label("Link", systemImage: "link") }
                            .buttonStyle(TBDButtonStyle(.secondary))
                        TBDMeetingButton(meetings: context.meetings)
                    }
                }
            }
            if let error = env.databaseError {
                TBDNotice("The Listening library could not be opened: \(error)", tone: .needsYou)
            }
            TBDModelBanner()
            if showPractice { TBDPracticeDictation(context: context) }
            TBDSegmented(selection: $env.selectedTab, options: TBDListeningTab.allCases.map { ($0, $0.title) })
            if env.selectedTab != .transcribe { TBDQueueStrip(queue: context.files) }
            Group {
                switch env.selectedTab {
                case .transcribe: TBDTranscribeView(context: context)
                case .library: TBDLibraryView(context: context, kind: nil)
                case .dictations: TBDDictationHistoryView()
                case .meetings: TBDMeetingsView(context: context)
                case .prompts: TBDPromptsView(context: context)
                case .transforms: TBDTransformsView(context: context)
                case .vocabulary: TBDVocabularyView(env: env)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(TBDTokens.Space.xxl)
        .background(TBDColor.paper)
        .task(id: env.revision) {
            showPractice = !env.preferences.practiceCompleted && ((try? env.database?.dictations(limit: 1))?.isEmpty ?? false)
                || (showPractice && !env.preferences.practiceCompleted)
        }
        .overlay {
            if dropTargeted {
                TBDBrickShape().strokeBorder(TBDColor.tealInk, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .overlay(TBDLabel("Drop audio or video to transcribe")).padding(TBDTokens.Space.sm)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            // Gather every dropped file and folder first, then queue them once, in drop order.
            Task { @MainActor in context.files.enqueue(files: await TBDDropCollector.urls(from: providers)) }
            return true
        }
    }
}

/// Progress of queued file and link jobs.
struct TBDQueueStrip: View {
    @ObservedObject var queue: TBDFileQueue

    var body: some View {
        if !queue.items.isEmpty {
            VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
                HStack {
                    TBDLabel("Transcription queue")
                    Spacer()
                    if queue.items.contains(where: \.isFinished) {
                        Button("Clear finished") { queue.clearFinished() }.buttonStyle(TBDButtonStyle(.quiet))
                    }
                }
                ForEach(queue.items) { item in
                    HStack(spacing: TBDTokens.Space.md) {
                        Text(item.title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 280, alignment: .leading)
                        status(item)
                        Spacer()
                        if !item.isFinished {
                            Button { queue.cancel(item.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(TBDButtonStyle(.icon)).help("Cancel").accessibilityLabel("Cancel \(item.title)")
                        }
                    }
                }
            }
            .tbdCard(padding: TBDTokens.Space.md)
        }
    }

    @ViewBuilder private func status(_ item: TBDFileQueue.Item) -> some View {
        switch item.state {
        case .queued: TBDTag("Queued", status: .idle)
        case .running(let stage, let fraction):
            ProgressView(value: fraction).frame(width: 140)
            Text(stage).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        case .done: TBDTag("Done", status: .live)
        case .failed(let message):
            TBDTag("Failed", status: .needsYou)
            Text(message).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).lineLimit(1)
        case .cancelled: TBDTag("Cancelled", status: .idle)
        }
    }
}

/// Shown until the selected engine's model is on disk. Downloads only when clicked.
struct TBDModelBanner: View {
    @EnvironmentObject private var env: TBDListeningEnvironment
    @StateObject private var models = TBDModelsModel()

    var body: some View {
        // The live engine first (dictation), then the final engine if it differs.
        let prefs = env.preferences
        let engine = models.manager.isDownloaded(engine: prefs.liveEngine) ? prefs.finalEngine : prefs.liveEngine
        let model = TBDModelManager.Model(engine: engine)
        if !models.manager.isDownloaded(model) {
            HStack(spacing: TBDTokens.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download the speech model to start").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                    Text("\(model.title): \(model.detail) Speech stays on this Mac.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                    if let error = models.error { Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk) }
                }
                Spacer()
                if let value = models.progress[model] {
                    ProgressView(value: value).frame(width: 160)
                } else {
                    Button("Download") { models.download(model) }.buttonStyle(TBDButtonStyle(.primary))
                }
            }
            .tbdCard(padding: TBDTokens.Space.md)
            .onChange(of: models.statuses.map(\.downloaded)) { _, _ in env.changed(); Task { await env.speech.warmUp() } }
        }
    }
}
