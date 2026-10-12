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

    func summarize() { runAI("Summarising…") { item in
        let prompt = self.env.preferences.summaryPrompt
        return TBDSummary(transcriptionId: item.id, kind: .summary, prompt: prompt, content: try await TBDListeningAI.summarize(item, prompt: prompt))
    } }

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

    func export(_ format: TBDExportFormat) {
        guard let item else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.title.replacingOccurrences(of: "/", with: "-") + "." + format.fileExtension
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try TBDExport.render(item, as: format, summaries: summaries).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }

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
        for path in item.audioPaths where path.hasPrefix(TBDListeningPaths.root.path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        if item.sourceKind == .meeting, let folder = item.audioPaths.first.map({ URL(fileURLWithPath: $0).deletingLastPathComponent() }),
           folder.path.hasPrefix(TBDListeningPaths.meetings.path) {
            try? FileManager.default.removeItem(at: folder)
        }
        try? env.database?.deleteTranscription(id: item.id)
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

    init(context: TBDListeningContext, id: String) {
        self.context = context
        _model = StateObject(wrappedValue: TBDTranscriptDetailModel(id: id, env: context.env))
    }

    var body: some View {
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
                            TBDAskView(model: model.ask, starters: item.sourceKind == .meeting ? TBDQuickPrompt.starters : TBDQuickPrompt.transcriptStarters,
                                       placeholder: item.sourceKind == .meeting ? "Ask about the meeting…" : "Ask about this transcript…")
                                .frame(minHeight: 360)
                        }
                    }
                    .padding(.trailing, TBDTokens.Space.md)
                }
            } else {
                Text("This item no longer exists.").foregroundStyle(TBDTokens.muted)
            }
        }
        .onAppear { model.load(); title = model.item?.title ?? "" }
        .onDisappear { model.flushNotes(); model.ask.stop() }
        .sheet(isPresented: $splitting) {
            if let item = model.item {
                TBDSplitSheet(item: item) { cuts, titles in try context.meetings.split(item.id, cutsMs: cuts, titles: titles) }
            }
        }
        .onChange(of: env.revision) { _, _ in model.load() }
    }

    private func header(_ item: TBDTranscription) -> some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel(item.sourceKind.label + " · " + item.createdAt.formatted(date: .abbreviated, time: .shortened)
                     + (item.durationMs > 0 ? " · " + TBDExport.clock(item.durationMs) : ""))
            TextField("Title", text: $title).textFieldStyle(.plain)
                .font(TBDTokens.Typography.title).foregroundStyle(TBDTokens.ink)
                .onSubmit { model.rename(title) }
            if let link = item.sourceURL, let url = URL(string: link) {
                Link(link, destination: url).font(.system(size: 11)).lineLimit(1)
            }
            HStack(spacing: TBDTokens.Space.sm) {
                Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(TBDButtonStyle(.secondary))
                Menu {
                    ForEach(TBDExportFormat.allCases, id: \.self) { format in Button(format.title) { model.export(format) } }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize()
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
                Button { model.tab = .ask } label: { Label("Ask", systemImage: "bubble.left.and.text.bubble.right") }
                    .buttonStyle(TBDButtonStyle(.secondary))
            }
            if let working = model.working {
                HStack { ProgressView().controlSize(.small); Text(working).foregroundStyle(TBDTokens.muted) }
            }
            ForEach(model.summaries) { summary in
                VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                    HStack {
                        TBDLabel(summary.kind == .summary ? "Summary" : "Q: " + summary.prompt)
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

    private func transcript(_ item: TBDTranscription) -> some View {
        let editable = model.projection?.segments ?? []
        let fallback = item.segments.isEmpty && !item.text.isEmpty
            ? [TBDSegment(start: 0, end: item.durationMs, text: item.text)] : item.segments
        return VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            HStack {
                TBDLabel("Transcript")
                if !editable.isEmpty, item.status == .completed {
                    Text("Right-click a passage to edit it or change its speaker.").font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
                }
            }
            if editable.isEmpty {
                ForEach(Array(fallback.enumerated()), id: \.offset) { _, segment in row(segment, in: item, range: nil, edited: false) }
            } else {
                ForEach(editable) { passage in row(passage.segment, in: item, range: passage.range, edited: passage.edited) }
            }
        }
    }

    @ViewBuilder
    private func row(_ segment: TBDSegment, in item: TBDTranscription, range: TBDWordRange?, edited: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TBDTokens.Space.md) {
            Text(TBDExport.clock(segment.start)).font(.system(size: 11, design: .monospaced)).foregroundStyle(TBDTokens.muted)
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: TBDTokens.Space.xs) {
                    if let speaker = item.speakerLabel(segment.speaker) {
                        Text(speaker).font(TBDTokens.Typography.label).tracking(TBDTokens.Typography.labelTracking)
                            .foregroundStyle(speakerColor(segment.speaker, in: item))
                    }
                    if edited { Text("Edited").font(.system(size: 10)).foregroundStyle(TBDTokens.muted) }
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
                    Text(segment.text).font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .contextMenu {
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
        }
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
