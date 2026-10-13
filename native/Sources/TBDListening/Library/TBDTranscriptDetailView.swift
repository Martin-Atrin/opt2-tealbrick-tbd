import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech
import UniformTypeIdentifiers

@MainActor
final class TBDTranscriptDetailModel: ObservableObject {
    /// The transcript as shown (stored words with the person's edits applied). Never save it whole.
    @Published var item: TBDTranscription?
    @Published private(set) var projection: TBDTranscriptEditor.Projection?
    @Published var summaries: [TBDSummary] = []
    /// Transcript prompts offered in the summary picker (Prompts page, visible ones).
    @Published var summaryPrompts: [TBDPrompt] = []
    /// One-off instructions added to the next prompt run.
    @Published var extraInstructions = ""
    @Published var working: String?
    @Published var error: String?
    @Published var tab: Tab = .transcript
    @Published private(set) var notes = ""
    @Published private(set) var notesStatus: String?
    let id: String
    let ask: TBDAskModel
    private let env: TBDListeningEnvironment
    private var notesSave: Task<Void, Never>?
    private var notesDirty = false

    enum Tab: String, CaseIterable, Identifiable {
        case transcript, notes, ask
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    init(id: String, env: TBDListeningEnvironment) {
        self.id = id
        self.env = env
        ask = TBDAskModel(database: env.database, transcriptionID: id)
        ask.context = { [weak self] in
            guard let self, let item = self.item else { return ("", nil) }
            return (TBDMeetingAsk.transcript(item), self.notes.isEmpty ? nil : self.notes)
        }
    }

    func load() {
        projection = try? env.database?.projectedTranscription(id: id)
        item = projection?.item
        summaries = (try? env.database?.summaries(for: id)) ?? []
        summaryPrompts = (try? env.database?.availableResultPrompts(for: id)) ?? []
        if !notesDirty { notes = item?.userNotes ?? "" }
        ask.load()
    }

    var tabs: [Tab] { item?.sourceKind == .meeting ? Tab.allCases : [.transcript, .ask] }

    /// Edits saved notes; written to the library after a short pause in typing.
    func editNotes(_ text: String) {
        guard text != notes else { return }
        notes = text
        notesDirty = true
        notesStatus = "Saving…"
        notesSave?.cancel()
        notesSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushNotes()
        }
    }

    func flushNotes() {
        notesSave?.cancel()
        guard notesDirty else { return }
        do {
            try env.database?.updateUserNotes(id: id, notes: notes)
            notesDirty = false
            notesStatus = "Saved"
        } catch {
            notesStatus = "Not saved: \(error.localizedDescription)"
        }
    }

    /// Runs a library prompt (the default one when nil) and adds its result as another summary.
    func summarize(with prompt: TBDPrompt? = nil) {
        guard let chosen = prompt ?? (try? env.database?.defaultSummaryPrompt()) else {
            error = "No transcript prompt is available. Add or show one on the Prompts page."
            return
        }
        let extra = extraInstructions
        runAI("Running \(chosen.name)…") { item in
            try await TBDPromptRunner.summarize(item, with: chosen, extraInstructions: extra)
        }
        extraInstructions = ""
    }

    private func runAI(_ label: String, _ body: @escaping (TBDTranscription) async throws -> TBDSummary) {
        guard let item, working == nil else { return }
        working = label; error = nil
        Task {
            defer { working = nil }
            do {
                let summary = try await body(item)
                try env.database?.save(summary)
                load()
            } catch { self.error = error.localizedDescription }
        }
    }

    func deleteSummary(_ summary: TBDSummary) { try? env.database?.deleteSummary(id: summary.id); load() }

    func copy() { if let item { TBDPasteService.copy(TBDExport.render(item, as: .txt)) } }

    func rename(_ title: String) {
        guard item != nil, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        try? env.database?.rename(transcriptionId: id, title: title)
        load()
        env.changed()
    }

    // MARK: Edits

    var editCount: Int { projection?.editCount ?? 0 }

    func apply(_ edit: TBDTranscriptEdit) {
        guard let database = env.database, let stored = try? database.transcription(id: id) else { return }
        do {
            try database.applyEdit(edit, to: id, fingerprint: TBDTranscriptEditor.fingerprint(stored))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        load()
        env.changed()
    }

    func undoEdit() {
        do { try env.database?.undoLastEdit(of: id) } catch { self.error = error.localizedDescription }
        load()
        env.changed()
    }

    func renameSpeaker(_ speaker: TBDSpeaker) {
        guard let label = TBDTextPrompt.ask("Rename speaker", message: "Name for \(speaker.label) in this transcript.",
                                             initial: speaker.label, action: "Rename") else { return }
        apply(.renameSpeaker(id: speaker.id, label: label))
    }

    func assignNewSpeaker(_ range: TBDWordRange) {
        guard let label = TBDTextPrompt.ask("New speaker", message: "Name the speaker of this passage.", initial: "", action: "Add") else { return }
        let id = "user:" + tbdNewID()
        apply(.addSpeaker(id: id, label: label))
        apply(.assignSpeaker(range: range, speaker: id))
    }

    /// Re-runs the meeting transcription after confirming; edits are dropped, notes and answers stay.
    func retranscribe(_ meetings: TBDMeetingController) {
        let alert = NSAlert()
        alert.messageText = "Retranscribe this meeting?"
        alert.informativeText = "Replaces this transcript using the current speech engine. Notes, summaries and Ask conversations are kept."
            + (editCount > 0 ? " Your transcript edits will be reset." : "")
        alert.addButton(withTitle: "Retranscribe")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? env.database?.deleteEdits(of: id)
        meetings.retranscribe(id)
        load()
    }

    func delete() {
        guard let item else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(item.title)”?"
        alert.informativeText = "The transcript, its summaries and its kept audio are removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let database = env.database else { return }
        // Same removal as the Library's bulk delete: a failure keeps the item and says why.
        let outcome = TBDRetentionSweeper(database: database).deleteFromLibrary(ids: [item.id])
        if let failure = outcome.failed.first { error = "Could not delete: \(failure.reason)"; return }
        env.selectedTranscriptionID = nil
        env.changed()
    }
}

/// Transcript with timestamps and speakers, AI summary and questions, export.
struct TBDTranscriptDetailView: View {
    let context: TBDListeningContext
    @StateObject private var model: TBDTranscriptDetailModel
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var title = ""
    @State private var splitting = false
    @State private var editing: TBDWordRange?
    @State private var draft = ""
    // Reader: audio player, Text/Timed view, font size, find (PARITY WP4 reader).
    @StateObject private var player = TBDTranscriptPlayer()
    @AppStorage(TBDTranscriptFontScale.defaultsKey) private var fontScale = TBDTranscriptFontScale.defaultValue
    @State private var viewMode = TBDTranscriptViewMode.initial
    @State private var find = TBDTranscriptFind()
    @State private var findVisible = false
    @State private var findToken = 0
    @FocusState private var findFocused: Bool
    /// Playback-follow is paused after a manual scroll (5 s) and while find navigates.
    @State private var followPaused = false
    @State private var findPausedFollow = false
    @State private var pauseTask: Task<Void, Never>?
    @State private var scrollMonitor: Any?

    init(context: TBDListeningContext, id: String) {
        self.context = context
        _model = StateObject(wrappedValue: TBDTranscriptDetailModel(id: id, env: context.env))
    }

    var body: some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: player.activeIndex) { _, index in followPlayback(index, proxy) }
                .onChange(of: player.jumpCount) { _, _ in resumeFollow() }
                .onChange(of: findToken) { _, _ in scrollToFindMatch(proxy) }
        }
    }

    private var content: some View {
        Group {
            if let item = model.item {
                ScrollView {
                    VStack(alignment: .leading, spacing: TBDTokens.Space.lg) {
                        header(item)
                        if let error = model.error { Text(error).foregroundStyle(TBDTokens.alert).font(TBDTokens.Typography.body) }
                        switch item.status {
                        case .processing: HStack { ProgressView().controlSize(.small); Text("Transcribing…").foregroundStyle(TBDTokens.muted) }
                        case .failed, .cancelled: failure(item)
                        case .completed: EmptyView()
                        }
                        if model.tabs.count > 1 {
                            Picker("", selection: $model.tab) {
                                ForEach(model.tabs) { Text($0 == .ask && model.ask.streaming ? "Ask •" : $0.title).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        switch model.tab {
                        case .transcript:
                            if item.status == .completed { ai(item) }
                            transcript(item)
                        case .notes:
                            TBDNotesEditor(text: Binding(get: { model.notes }, set: { model.editNotes($0) }), status: model.notesStatus,
                                           placeholder: "Your notes for this meeting…").frame(minHeight: 320)
                        case .ask:
                            TBDAskView(model: model.ask, starters: item.sourceKind == .meeting ? TBDAskPrompts.starters(env.database) : TBDQuickPrompt.transcriptStarters,
                                       followUps: TBDAskPrompts.followUps(env.database),
                                       placeholder: item.sourceKind == .meeting ? "Ask about the meeting…" : "Ask about this transcript…")
                                .frame(minHeight: 360)
                        }
                    }
                    .padding(.trailing, TBDTokens.Space.md)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if item.status == .completed, player.isAvailable {
                        TBDPlayerBar(player: player, title: item.title, showsAudioMenu: item.sourceKind == .meeting) { model.error = $0 }
                    }
                }
            } else {
                Text("This item no longer exists.").foregroundStyle(TBDTokens.muted)
            }
        }
        .onAppear { model.load(); title = model.item?.title ?? ""; syncPlayer(); installScrollMonitor() }
        .onDisappear {
            model.flushNotes(); model.ask.stop()
            player.cleanup(); removeScrollMonitor()
        }
        .sheet(isPresented: $splitting) {
            if let item = model.item {
                TBDSplitSheet(item: item) { cuts, titles in try context.meetings.split(item.id, cutsMs: cuts, titles: titles) }
            }
        }
        .onChange(of: env.revision) { _, _ in model.load(); syncPlayer() }
        .onChange(of: model.item) { _, _ in if findVisible { rebuildFind() } }
        .onChange(of: viewMode) { _, _ in syncPlayer(); if findVisible { rebuildFind() } }
        .onChange(of: model.item?.title) { _, new in if let new { title = new } }
    }

    private func header(_ item: TBDTranscription) -> some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel(item.sourceKind.label + " · " + item.createdAt.formatted(date: .abbreviated, time: .shortened)
                     + (item.durationMs > 0 ? " · " + TBDExport.clock(item.durationMs) : ""))
            TextField("Title", text: $title).textFieldStyle(.plain)
                .font(TBDTokens.Typography.title).foregroundStyle(TBDTokens.ink)
                .onSubmit { model.rename(title) }
            TBDTranscriptLabelsBar(transcriptionID: item.id)
            if let notice = item.captureNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let link = item.sourceURL, let url = URL(string: link) {
                Link(link, destination: url).font(.system(size: 11)).lineLimit(1)
            }
            HStack(spacing: TBDTokens.Space.sm) {
                Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(TBDButtonStyle(.secondary))
                TBDExportButton(item: item, summaries: model.summaries)
                TBDFavoriteButton(item: item)
                TBDKnowledgeButton(item: item, knowledge: context.knowledge)
                if !item.speakers.isEmpty {
                    Menu {
                        ForEach(item.speakers, id: \.id) { speaker in Button("Rename \(speaker.label)…") { model.renameSpeaker(speaker) } }
                    } label: { Text(item.speakers.map(\.label).joined(separator: ", ")).font(.system(size: 11)) }
                    .menuStyle(.borderlessButton).fixedSize().help("Rename speakers")
                }
                if model.editCount > 0 {
                    Button { model.undoEdit() } label: { Label("Undo edit", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(TBDButtonStyle(.quiet))
                }
                Spacer()
                if item.sourceKind == .meeting {
                    Menu {
                        Button("Retranscribe…") { model.retranscribe(context.meetings) }
                            .disabled(item.status == .processing || !item.audioPaths.contains { FileManager.default.fileExists(atPath: $0) })
                        Button("Split…") { splitting = true }.disabled(TBDMeetingSplitter.ineligibility(item) != nil)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Meeting actions")
                }
                Button { model.delete() } label: { Image(systemName: "trash") }.buttonStyle(TBDButtonStyle(.icon)).help("Delete")
                    .accessibilityLabel("Delete transcript")
            }
        }
    }

    private func failure(_ item: TBDTranscription) -> some View {
        HStack {
            Text(item.errorMessage ?? "Transcription did not finish.").foregroundStyle(TBDTokens.alert)
            Spacer()
            if item.sourceKind == .meeting {
                Button("Transcribe again") { context.meetings.retranscribe(item.id) }.buttonStyle(TBDButtonStyle(.secondary))
            } else if let path = item.sourcePath, FileManager.default.fileExists(atPath: path) {
                Button("Retry") { model.deleteQuietly(); context.files.enqueue(files: [URL(fileURLWithPath: path)]) }
                    .buttonStyle(TBDButtonStyle(.secondary))
            } else if let link = item.sourceURL {
                Button("Retry") { model.deleteQuietly(); context.files.enqueue(link: link) }.buttonStyle(TBDButtonStyle(.secondary))
            }
        }
        .tbdCard(padding: TBDTokens.Space.md)
    }

    private func ai(_ item: TBDTranscription) -> some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            HStack(spacing: TBDTokens.Space.sm) {
                Button { model.summarize() } label: { Label("Summarise", systemImage: "text.alignleft") }
                    .buttonStyle(TBDButtonStyle(.primary)).disabled(model.working != nil)
                    .help("Runs the default transcript prompt from the Prompts page.")
                Menu("Run prompt") {
                    ForEach(model.summaryPrompts) { prompt in
                        Button(prompt.name) { model.summarize(with: prompt) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.working != nil || model.summaryPrompts.isEmpty)
                TextField("Extra instructions (optional)", text: $model.extraInstructions).tbdField().frame(maxWidth: 260)
                Button { model.tab = .ask } label: { Label("Ask", systemImage: "bubble.left.and.text.bubble.right") }
                    .buttonStyle(TBDButtonStyle(.secondary))
            }
            if let working = model.working {
                HStack { ProgressView().controlSize(.small); Text(working).foregroundStyle(TBDTokens.muted) }
            }
            ForEach(model.summaries) { summary in
                VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                    HStack {
                        TBDLabel(summary.kind == .summary ? (summary.promptName ?? "Summary") : "Q: " + summary.prompt)
                        Spacer()
                        Button { TBDPasteService.copy(summary.content) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(TBDButtonStyle(.icon)).help("Copy")
                        Button { model.deleteSummary(summary) } label: { Image(systemName: "xmark") }
                            .buttonStyle(TBDButtonStyle(.icon)).help("Remove")
                    }
                    Text(LocalizedStringKey(summary.content)).font(TBDTokens.Typography.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tbdCard(padding: TBDTokens.Space.md)
            }
        }
    }

    // MARK: Reader (Text / Timed, find, font size, playback follow)

    private struct Passage: Identifiable {
        let index: Int
        let segment: TBDSegment
        let range: TBDWordRange?
        let edited: Bool
        var id: Int { index }
    }

    private func passages(for item: TBDTranscription) -> [Passage] {
        if let editable = model.projection?.segments, !editable.isEmpty {
            return editable.enumerated().map { Passage(index: $0, segment: $1.segment, range: $1.range, edited: $1.edited) }
        }
        return item.segments.enumerated().map { Passage(index: $0, segment: $1, range: nil, edited: false) }
    }

    /// Text unless the transcript has timing and the person chose Timed (v1 opens in Text and does not remember).
    private func effectiveMode(_ item: TBDTranscription) -> TBDTranscriptViewMode {
        TBDTranscriptReader.hasTimedView(item) ? viewMode : .text
    }

    private var bodyFont: Font { .custom("Switzer", size: TBDTranscriptFontScale.pointSize(fontScale)) }

    private func transcript(_ item: TBDTranscription) -> some View {
        let mode = effectiveMode(item)
        let list = passages(for: item)
        return VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            HStack(spacing: TBDTokens.Space.sm) {
                TBDLabel("Transcript")
                if item.status == .completed, !list.isEmpty {
                    Text(mode == .timed ? "Right-click a passage to edit it or change its speaker." : "Switch to Timed to edit passages or speakers.")
                        .font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
                }
                Spacer()
                if TBDTranscriptReader.hasTimedView(item) {
                    Picker("Transcript view", selection: $viewMode) {
                        ForEach(TBDTranscriptViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
                fontControls
                Button { openFind() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(TBDButtonStyle(.icon)).help("Find in transcript (⌘F)").accessibilityLabel("Find in transcript")
            }
            if findVisible {
                HStack {
                    Spacer()
                    TBDTranscriptFindBar(
                        query: Binding(get: { find.query }, set: { setFindQuery($0) }),
                        isFocused: $findFocused,
                        position: find.displayPosition,
                        hasQueryButNoMatches: find.hasQueryButNoMatches,
                        onNext: { find.next(); findToken &+= 1 },
                        onPrev: { find.prev(); findToken &+= 1 },
                        onClose: closeFind)
                }
            }
            switch mode {
            case .text: textBody(item)
            case .timed: ForEach(list) { passage in row(passage, in: item) }
            }
        }
        .background { findShortcuts }
    }

    private func textBody(_ item: TBDTranscription) -> some View {
        let text = TBDTranscriptReader.bodyText(item)
        return Group {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if item.status == .completed { Text("No transcript available").foregroundStyle(TBDTokens.muted) }
            } else {
                Group {
                    if findVisible, find.hasMatches {
                        Text(TBDTranscriptFindHighlight.attributed(text, ranges: find.ranges(inBlock: 0), current: find.currentRange(inBlock: 0), baseFont: bodyFont))
                    } else {
                        Text(text).font(bodyFont)
                    }
                }
                .foregroundStyle(TBDTokens.ink).lineSpacing(6).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) { textFindAnchor(text) }
                .tbdCard(padding: TBDTokens.Space.lg)
            }
        }
    }

    /// Invisible copy of the text before the current match; its bottom edge is where Text mode scrolls to.
    @ViewBuilder
    private func textFindAnchor(_ text: String) -> some View {
        if findVisible, let current = find.current,
           let prefix = TBDTranscriptReader.prefix(of: text, utf16Offset: current.range.location) {
            Text(prefix).font(bodyFont).lineSpacing(6).foregroundStyle(.clear)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottomLeading) { Color.clear.frame(width: 1, height: 1).id(Self.textAnchorID) }
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private static let textAnchorID = -1

    private var fontControls: some View {
        HStack(spacing: 2) {
            Button { fontScale = TBDTranscriptFontScale.adjusted(fontScale, by: -TBDTranscriptFontScale.step) } label: {
                Image(systemName: "textformat.size.smaller").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain).disabled(!TBDTranscriptFontScale.canDecrease(fontScale))
            .help("Smaller transcript text").accessibilityLabel("Smaller transcript text")
            Button { fontScale = TBDTranscriptFontScale.adjusted(fontScale, by: TBDTranscriptFontScale.step) } label: {
                Image(systemName: "textformat.size.larger").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain).disabled(!TBDTranscriptFontScale.canIncrease(fontScale))
            .help("Larger transcript text").accessibilityLabel("Larger transcript text")
        }
        .foregroundStyle(TBDTokens.muted)
    }

    // MARK: Find

    /// Registers ⌘F, ⌘G and ⇧⌘G while the transcript is on screen; stepping needs an open bar with matches.
    private var findShortcuts: some View {
        ZStack {
            Button("") { openFind() }.keyboardShortcut("f", modifiers: .command)
            if findVisible, find.hasMatches {
                Button("") { find.next(); findToken &+= 1 }.keyboardShortcut("g", modifiers: .command)
                Button("") { find.prev(); findToken &+= 1 }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private func openFind() {
        findVisible = true
        rebuildFind()
        DispatchQueue.main.async { findFocused = true }
    }

    private func closeFind() {
        findVisible = false
        findFocused = false
        find.clear()
        releaseFindPause()
    }

    private func setFindQuery(_ text: String) {
        find.setQuery(text)
        if !find.hasMatches { releaseFindPause() }
        findToken &+= 1
    }

    /// Searches the text of the mode on screen: segments in Timed, the whole text in Text.
    private func rebuildFind() {
        guard let item = model.item else { return }
        find.setBlocks(TBDTranscriptReader.findBlocks(mode: effectiveMode(item), segments: passages(for: item).map(\.segment),
                                                      body: TBDTranscriptReader.bodyText(item)))
        if find.hasMatches { findToken &+= 1 } else { releaseFindPause() }
    }

    /// Scrolls the current match into view; playback-follow stays paused so it cannot pull the view back.
    private func scrollToFindMatch(_ proxy: ScrollViewProxy) {
        guard findVisible, let current = find.current, let item = model.item else { return }
        followPaused = true
        findPausedFollow = true
        pauseTask?.cancel()
        let target = effectiveMode(item) == .timed ? current.blockIndex : Self.textAnchorID
        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
    }

    /// Follow playback again, but only if find (not a manual scroll) paused it.
    private func releaseFindPause() {
        guard findPausedFollow else { return }
        followPaused = false
        findPausedFollow = false
        pauseTask?.cancel()
    }

    // MARK: Playback

    private func syncPlayer() {
        guard let item = model.item, item.status == .completed else { player.cleanup(); return }
        player.prepare(paths: item.audioPaths, fallbackDurationMs: item.durationMs)
        player.segmentStarts = effectiveMode(item) == .timed ? passages(for: item).map { $0.segment.start } : []
    }

    private func followPlayback(_ index: Int?, _ proxy: ScrollViewProxy) {
        guard player.isPlaying, !followPaused, editing == nil, let index, let item = model.item, effectiveMode(item) == .timed else { return }
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
    }

    /// A seek or jump in playback time re-syncs the transcript at once.
    private func resumeFollow() {
        followPaused = false
        pauseTask?.cancel()
    }

    /// A manual scroll during playback pauses following for a few seconds (v1).
    private func installScrollMonitor() {
        removeScrollMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard player.isPlaying else { return event }
            if findPausedFollow {
                findPausedFollow = false
                followPaused = false
                pauseTask?.cancel()
            }
            followPaused = true
            pauseTask?.cancel()
            pauseTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(TBDTranscriptReader.followPauseSeconds))
                if !Task.isCancelled { followPaused = false }
            }
            return event
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        pauseTask?.cancel()
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ passage: Passage, in item: TBDTranscription) -> some View {
        let segment = passage.segment
        let range = passage.range
        let isActive = player.activeIndex == passage.index
        HStack(alignment: .firstTextBaseline, spacing: TBDTokens.Space.md) {
            timestamp(segment)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: TBDTokens.Space.xs) {
                    if let speaker = item.speakerLabel(segment.speaker) {
                        Text(speaker).font(TBDTokens.Typography.label).tracking(TBDTokens.Typography.labelTracking)
                            .foregroundStyle(speakerColor(segment.speaker, in: item))
                    }
                    if passage.edited { Text("Edited").font(.system(size: 10)).foregroundStyle(TBDTokens.muted) }
                }
                if let range, editing == range {
                    TextEditor(text: $draft).font(TBDTokens.Typography.body).frame(minHeight: 60)
                        .scrollContentBackground(.hidden).padding(TBDTokens.Space.xs)
                        .background(TBDTokens.paper, in: RoundedRectangle(cornerRadius: TBDTokens.Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.sm).strokeBorder(TBDTokens.accent))
                    HStack {
                        Button("Save") { model.apply(.editText(range: range, text: draft)); editing = nil }
                            .buttonStyle(TBDButtonStyle(.primary)).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") { editing = nil }.buttonStyle(TBDButtonStyle(.quiet))
                    }
                } else {
                    segmentText(segment.text, block: passage.index)
                        .foregroundStyle(TBDTokens.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(isActive ? TBDTokens.Space.sm : 0)
        .background(isActive ? TBDTokens.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: TBDTokens.Radius.base))
        .id(passage.index)
        .contextMenu {
            if player.isAvailable { Button("Play from here") { player.play(fromMs: segment.start) } }
            if let range, item.status == .completed {
                Button("Edit text") { draft = segment.text; editing = range }
                Menu("Speaker") {
                    ForEach(item.speakers, id: \.id) { speaker in
                        Button(speaker.label) { model.apply(.assignSpeaker(range: range, speaker: speaker.id)) }
                            .disabled(speaker.id == segment.speaker)
                    }
                    Divider()
                    Button("New speaker…") { model.assignNewSpeaker(range) }
                }
                if let speaker = item.speakers.first(where: { $0.id == segment.speaker }) {
                    Button("Rename \(speaker.label)…") { model.renameSpeaker(speaker) }
                }
            }
            Button("Copy passage") { TBDPasteService.copy(segment.text) }
            Button("Copy with timestamp") {
                TBDPasteService.copy(TBDTranscriptReader.clipboardText(timestamp: TBDExport.clock(segment.start), body: segment.text))
            }
        }
    }

    /// Clicking the time plays from there when the audio is kept (v1 timestamp chip).
    @ViewBuilder
    private func timestamp(_ segment: TBDSegment) -> some View {
        let label = Text(TBDExport.clock(segment.start)).font(.system(size: 11, design: .monospaced))
        if player.isAvailable {
            Button { player.play(fromMs: segment.start) } label: { label.foregroundStyle(TBDTokens.accent) }
                .buttonStyle(.plain).frame(width: 52, alignment: .trailing).help("Play from here")
                .accessibilityLabel("Play from \(TBDExport.clock(segment.start))")
        } else {
            label.foregroundStyle(TBDTokens.muted).frame(width: 52, alignment: .trailing)
        }
    }

    private func segmentText(_ text: String, block: Int) -> Text {
        let ranges = findVisible ? find.ranges(inBlock: block) : []
        guard !ranges.isEmpty else { return Text(text).font(bodyFont) }
        return Text(TBDTranscriptFindHighlight.attributed(text, ranges: ranges, current: find.currentRange(inBlock: block), baseFont: bodyFont))
    }

    private func speakerColor(_ id: String?, in item: TBDTranscription) -> Color {
        guard let id, let index = item.speakers.firstIndex(where: { $0.id == id }) else { return TBDTokens.muted }
        return TBDTokens.data[index % TBDTokens.data.count]
    }
}

extension TBDTranscriptDetailModel {
    /// Removes a failed record before it is retried as a new item.
    func deleteQuietly() {
        try? env.database?.deleteTranscription(id: id)
        env.changed()
    }
}

/// Choose split points for a meeting and name the parts.
struct TBDSplitSheet: View {
    let item: TBDTranscription
    let split: ([Int], [String]) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var points = ""
    @State private var titles: [String] = []
    @State private var error: String?

    private var cuts: [Int]? {
        let values = points.split(separator: ",").map { TBDTimecode.parse(String($0)) }
        return values.contains(where: { $0 == nil }) || values.isEmpty ? nil : values.compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            Text("Split “\(item.title)”").font(TBDTokens.Typography.title)
            Text("Each part becomes its own meeting with its own audio and transcript. The original stays as it is; notes, summaries and answers stay with it.")
                .font(.system(size: 12)).foregroundStyle(TBDTokens.muted).fixedSize(horizontal: false, vertical: true)
            TBDSettingsRow("Split at", help: "m:ss or h:mm:ss; separate several points with commas. Length \(TBDExport.clock(item.durationMs)).") {
                TextField("12:30", text: $points).tbdField().frame(width: 180)
            }
            ForEach(titles.indices, id: \.self) { index in
                TextField("Part \(index + 1)", text: $titles[index]).tbdField()
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(TBDTokens.alert) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(TBDButtonStyle(.quiet))
                Button("Split") {
                    guard let cuts else { error = "Enter time codes such as 12:30."; return }
                    do { try split(cuts, titles); dismiss() } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(TBDButtonStyle(.primary)).disabled(cuts == nil)
            }
        }
        .padding(TBDTokens.Space.xl)
        .frame(width: 440)
        .onAppear {
            points = TBDExport.clock(max(1000, item.durationMs / 2))
            titles = TBDMeetingSplitter.defaultTitles(item.title, parts: 2)
        }
        .onChange(of: points) { _, _ in
            let count = (cuts?.count ?? 1) + 1
            if count != titles.count { titles = TBDMeetingSplitter.defaultTitles(item.title, parts: count) }
            error = nil
        }
    }
}
