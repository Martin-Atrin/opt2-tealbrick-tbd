import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech
import UniformTypeIdentifiers

/// The Vocabulary page (v1 `VocabularyView`): processing mode, the clean steps, custom words,
/// snippets and backup. It is the one place the words and snippets are edited.
struct TBDVocabularyView: View {
    @EnvironmentObject private var env: TBDListeningEnvironment
    @StateObject private var model: TBDVocabularyModel
    @State private var mode: TBDProcessingMode
    @State private var removeFillers: Bool
    @State private var spokenPunctuation: Bool

    init(env: TBDListeningEnvironment) {
        _model = StateObject(wrappedValue: TBDVocabularyModel(database: env.database))
        _mode = State(initialValue: env.preferences.processingMode)
        _removeFillers = State(initialValue: env.preferences.removeFillers)
        _spokenPunctuation = State(initialValue: env.preferences.spokenPunctuation)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TBDTokens.Space.lg) {
                TBDPageHeader("Vocabulary", label: "Listening · Processed on this Mac")
                modeCard
                pipelineCard
                TBDWordsEditor(model: model)
                TBDSnippetsEditor(model: model)
                TBDVocabularyBackupCard(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            model.reload()
            model.onChange = { env.changed() }
        }
        .sheet(isPresented: Binding(get: { model.pendingImport != nil }, set: { if !$0 { model.cancelImport() } })) {
            if let preview = model.pendingImport { TBDVocabularyImportSheet(model: model, preview: preview).frame(minWidth: 460) }
        }
    }

    private func card<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
                Text(subtitle).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tbdCard()
    }

    private var modeCard: some View {
        card("Mode", "Switch anytime. Takes effect on your next dictation or file.") {
            HStack(spacing: TBDTokens.Space.md) {
                ForEach(TBDProcessingMode.allCases, id: \.self) { option in
                    Button {
                        mode = option
                        env.preferences.processingMode = option
                    } label: {
                        VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                            HStack {
                                Text(option.title).font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
                                Spacer()
                                if mode == option { Image(systemName: "checkmark.circle.fill").font(TBDFonts.symbol(16)).foregroundStyle(TBDColor.tealInk) }
                            }
                            Text(option.subtitle).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                            Text(option.detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(TBDTokens.Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(mode == option ? TBDColor.tealWash : TBDColor.tile, in: TBDBrickShape())
                        .overlay(TBDBrickShape()
                            .strokeBorder(mode == option ? TBDColor.tealInk : TBDColor.line, lineWidth: mode == option ? TBDTokens.Stroke.bar : TBDTokens.Stroke.hairline))
                        .contentShape(TBDBrickShape())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.title) mode")
                    .accessibilityAddTraits(mode == option ? .isSelected : [])
                }
            }
        }
    }

    private var pipelineCard: some View {
        card(mode == .raw ? "Raw mode is on" : "Clean steps",
             mode == .raw ? "Text processing is off. The steps and lists below apply when you switch to Clean."
                           : "These steps run in order on every Clean dictation and file. Meetings stay verbatim apart from custom words.") {
            VStack(spacing: 0) {
                TBDSettingsRow("Remove fillers", help: "Drops “um”, “uh” and similar.") {
                    Toggle("", isOn: Binding(get: { removeFillers }, set: { removeFillers = $0; env.preferences.removeFillers = $0 }))
                        .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
                }
                TBDSettingsRow("Fix words", help: "\(model.words.count) custom correction\(model.words.count == 1 ? "" : "s"). They run after transcription; this build has no recognition-time boosting.") { EmptyView() }
                TBDSettingsRow("Expand snippets", help: "\(model.snippets.count) snippet\(model.snippets.count == 1 ? "" : "s").") { EmptyView() }
                TBDSettingsRow("Spoken punctuation",
                               help: "“question mark” becomes ?. Dictation and files only; meetings stay verbatim.") {
                    Toggle("", isOn: Binding(get: { spokenPunctuation }, set: { spokenPunctuation = $0; env.preferences.spokenPunctuation = $0 }))
                        .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
                }
            }
        }
    }
}

/// Custom words list and add row.
struct TBDWordsEditor: View {
    @ObservedObject var model: TBDVocabularyModel
    @State private var heard = ""
    @State private var replacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel("Custom words")
            Text("Fix words the engine gets wrong. Leave the replacement empty to fix capitalisation only.")
                .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            HStack(spacing: TBDTokens.Space.sm) {
                TextField("Heard as", text: $heard).tbdField().onSubmit(add)
                TextField("Replace with", text: $replacement).tbdField().onSubmit(add)
                Button("Add", action: add).buttonStyle(TBDButtonStyle(.secondary))
                    .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.wordError { Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk) }
            if model.words.count > 5 { TextField("Search words", text: $model.wordQuery).tbdField() }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.filteredWords) { word in
                    HStack {
                        Toggle("", isOn: Binding(get: { word.isEnabled }, set: { _ in model.toggle(word) })).labelsHidden()
                            .toggleStyle(.checkbox) // design-guard: allow (native checkbox, no kit equivalent)
                        Text(word.word).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                        Image(systemName: "arrow.right").font(TBDFonts.symbol(13)).foregroundStyle(TBDColor.muted)
                        Text(word.replacement ?? word.word).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                        Spacer()
                        Button { model.delete(word) } label: { Image(systemName: "trash") }
                            .buttonStyle(TBDButtonStyle(.icon)).accessibilityLabel("Delete \(word.word)")
                    }
                    .padding(.vertical, TBDKit.s2)
                .overlay(alignment: .bottom) { Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair) }
                }
            }
            if model.words.isEmpty { Text("No custom words yet.").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tbdCard()
    }

    private func add() {
        if model.addWord(heard, replacement: replacement) { heard = ""; replacement = "" }
    }
}

/// Snippets list, add row and inline edit.
struct TBDSnippetsEditor: View {
    @ObservedObject var model: TBDVocabularyModel
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var editing: String?
    @State private var editTrigger = ""
    @State private var editExpansion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel("Snippets")
            Text("Say the trigger phrase to insert the text. Type \\n for a line break.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            HStack(spacing: TBDTokens.Space.sm) {
                TextField("Trigger, e.g. my address", text: $trigger).tbdField().onSubmit(add)
                TextField("Text to insert", text: $expansion).tbdField().onSubmit(add)
                Button("Add", action: add).buttonStyle(TBDButtonStyle(.secondary))
                    .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.snippetError { Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk) }
            if model.snippets.count > 5 { TextField("Search snippets", text: $model.snippetQuery).tbdField() }
            VStack(alignment: .leading, spacing: 0) {
            ForEach(model.filteredSnippets) { snippet in
                if editing == snippet.id {
                    HStack(spacing: TBDTokens.Space.sm) {
                        TextField("Trigger", text: $editTrigger).tbdField()
                        TextField("Text", text: $editExpansion).tbdField()
                        Button("Save") { if model.updateSnippet(id: snippet.id, trigger: editTrigger, expansion: editExpansion) { editing = nil } }
                            .buttonStyle(TBDButtonStyle(.primary))
                        Button("Cancel") { editing = nil; model.snippetError = nil }.buttonStyle(TBDButtonStyle(.quiet))
                    }
                    .padding(.vertical, TBDKit.s2)
                    .overlay(alignment: .bottom) { Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair) }
                } else {
                    HStack {
                        Toggle("", isOn: Binding(get: { snippet.isEnabled }, set: { _ in model.toggle(snippet) })).labelsHidden()
                            .toggleStyle(.checkbox) // design-guard: allow (native checkbox, no kit equivalent)
                        Text(snippet.trigger).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                        Image(systemName: "arrow.right").font(TBDFonts.symbol(13)).foregroundStyle(TBDColor.muted)
                        Text(snippet.action.map { "Press \($0.label)" } ?? TBDVocabularyModel.editable(snippet.expansion))
                            .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.inkSoft).lineLimit(1)
                        Spacer()
                        Text("used \(snippet.useCount)×").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                        if snippet.action == nil {
                            Button {
                                editing = snippet.id; editTrigger = snippet.trigger
                                editExpansion = TBDVocabularyModel.editable(snippet.expansion); model.snippetError = nil
                            } label: { Image(systemName: "pencil") }
                                .buttonStyle(TBDButtonStyle(.icon)).accessibilityLabel("Edit \(snippet.trigger)")
                        }
                        Button { model.delete(snippet) } label: { Image(systemName: "trash") }
                            .buttonStyle(TBDButtonStyle(.icon)).accessibilityLabel("Delete \(snippet.trigger)")
                    }
                    .padding(.vertical, TBDKit.s2)
                    .overlay(alignment: .bottom) { Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair) }
                }
            }
            }
            if model.snippets.isEmpty { Text("No snippets yet.").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tbdCard()
    }

    private func add() {
        if model.addSnippet(trigger: trigger, expansion: expansion) { trigger = ""; expansion = "" }
    }
}

/// Backup & Restore card: export and import vocabulary files in v1's format.
struct TBDVocabularyBackupCard: View {
    @ObservedObject var model: TBDVocabularyModel

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel("Backup & restore")
            Text("Save your vocabulary to a file. Restore it on this Mac or another. The file format matches the earlier version.")
                .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            HStack(spacing: TBDTokens.Space.sm) {
                Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(TBDButtonStyle(.secondary)).disabled(!model.canExport)
                Button { importFile() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(TBDButtonStyle(.secondary))
                if !model.canExport { Text("Add a word or snippet to enable export.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted) }
            }
            status
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tbdCard()
    }

    @ViewBuilder private var status: some View {
        switch model.backupStatus {
        case .idle: EmptyView()
        case .exported(let words, let snippets, let filename):
            line("Exported \(words) word\(words == 1 ? "" : "s") and \(snippets) snippet\(snippets == 1 ? "" : "s") to \(filename).", color: TBDColor.muted)
        case .imported(let result): line(TBDVocabularyModel.summary(of: result), color: TBDColor.muted)
        case .failed(let message): line(message, color: TBDColor.brickInk)
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        HStack(alignment: .top) {
            Text(text).font(TBDTokens.Typography.hint).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.backupStatus = .idle } label: { Image(systemName: "xmark") }
                .buttonStyle(TBDButtonStyle(.icon)).accessibilityLabel("Dismiss")
        }
    }

    private func export() {
        guard let payload = model.exportPayload() else { return }
        let panel = NSSavePanel()
        panel.title = "Export vocabulary"
        panel.message = "Save your custom words and snippets to a JSON file."
        panel.nameFieldStringValue = model.suggestedFilename
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try payload.data.write(to: url, options: .atomic)
            model.backupStatus = .exported(words: payload.words, snippets: payload.snippets, filename: url.lastPathComponent)
        } catch {
            model.backupStatus = .failed("Could not write the file: \(error.localizedDescription)")
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.title = "Import vocabulary"
        panel.message = "Choose a vocabulary backup (.json)."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.loadPreview(from: url)
    }
}

/// Shows what an import would do and asks how to treat entries that already exist.
struct TBDVocabularyImportSheet: View {
    @ObservedObject var model: TBDVocabularyModel
    let preview: TBDVocabularyBackup.Preview

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            Text("Import vocabulary").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
            Text("The file has \(preview.wordsTotal) word\(preview.wordsTotal == 1 ? "" : "s") and \(preview.snippetsTotal) snippet\(preview.snippetsTotal == 1 ? "" : "s").")
                .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.ink)
            if preview.hasConflicts {
                Text("\(preview.wordConflicts.count + preview.snippetConflicts.count) already exist here. \(preview.duplicateWords.count + preview.duplicateSnippets.count) repeat inside the file.")
                    .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
            TBDLabel("When an entry already exists")
            TBDSegmented(selection: $model.conflictPolicy, options: [
                (TBDVocabularyBackup.ConflictPolicy.skip, "Keep mine"),
                (TBDVocabularyBackup.ConflictPolicy.replace, "Use the file's"),
                (TBDVocabularyBackup.ConflictPolicy.replaceAll, "Replace all"),
            ])
            if model.conflictPolicy == .replaceAll {
                if preview.hasRemovals {
                    TBDNotice("Replace all deletes \(preview.wordsRemoved.count) word\(preview.wordsRemoved.count == 1 ? "" : "s") and \(preview.snippetsRemoved.count) snippet\(preview.snippetsRemoved.count == 1 ? "" : "s") that are not in the file: \((preview.wordsRemoved + preview.snippetsRemoved).prefix(8).joined(separator: ", ")).",
                              tone: .needsYou)
                } else {
                    Text("Nothing here is missing from the file, so nothing is deleted.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelImport() }.buttonStyle(TBDButtonStyle(.secondary))
                Button("Import") { model.applyImport() }
                    .buttonStyle(TBDButtonStyle(model.conflictPolicy == .replaceAll && preview.hasRemovals ? .destructive : .primary))
            }
        }
        .padding(TBDTokens.Space.xl)
        .background(TBDColor.tile)
    }
}
