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
                Text(title).font(TBDTokens.Typography.title).foregroundStyle(TBDTokens.ink)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(TBDTokens.muted)
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
                                Text(option.title).font(TBDTokens.Typography.title)
                                Spacer()
                                if mode == option { Image(systemName: "checkmark.circle.fill").foregroundStyle(TBDTokens.accent) }
                            }
                            Text(option.subtitle).font(.system(size: 12)).foregroundStyle(TBDTokens.muted)
                            Text(option.detail).font(.system(size: 12)).foregroundStyle(TBDTokens.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(TBDTokens.Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(mode == option ? TBDTokens.selected : TBDTokens.paper)
                        .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
                            .strokeBorder(mode == option ? TBDTokens.accent : TBDTokens.border, lineWidth: mode == option ? TBDTokens.Stroke.bar : TBDTokens.Stroke.hairline))
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
                        .labelsHidden().toggleStyle(.switch)
                }
                TBDSettingsRow("Fix words", help: "\(model.words.count) custom correction\(model.words.count == 1 ? "" : "s"). They run after transcription; this build has no recognition-time boosting.") { EmptyView() }
                TBDSettingsRow("Expand snippets", help: "\(model.snippets.count) snippet\(model.snippets.count == 1 ? "" : "s").") { EmptyView() }
                TBDSettingsRow("Spoken punctuation",
                               help: "“question mark” becomes ?. Dictation and files only; meetings stay verbatim.") {
                    Toggle("", isOn: Binding(get: { spokenPunctuation }, set: { spokenPunctuation = $0; env.preferences.spokenPunctuation = $0 }))
                        .labelsHidden().toggleStyle(.switch)
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
                .foregroundStyle(TBDTokens.muted)
            HStack(spacing: TBDTokens.Space.sm) {
                TextField("Heard as", text: $heard).tbdField().onSubmit(add)
                TextField("Replace with", text: $replacement).tbdField().onSubmit(add)
                Button("Add", action: add).buttonStyle(TBDButtonStyle(.secondary))
                    .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.wordError { Text(error).font(.system(size: 12)).foregroundStyle(TBDTokens.alert) }
            if model.words.count > 5 { TextField("Search words", text: $model.wordQuery).tbdField() }
            ForEach(model.filteredWords) { word in
                HStack {
                    Toggle("", isOn: Binding(get: { word.isEnabled }, set: { _ in model.toggle(word) })).labelsHidden().toggleStyle(.checkbox)
                    Text(word.word)
                    Image(systemName: "arrow.right").foregroundStyle(TBDTokens.muted)
                    Text(word.replacement ?? word.word).foregroundStyle(TBDTokens.ink)
                    Spacer()
                    Button { model.delete(word) } label: { Image(systemName: "trash") }
                        .buttonStyle(TBDButtonStyle(.icon)).accessibilityLabel("Delete \(word.word)")
                }
            }
            if model.words.isEmpty { Text("No custom words yet.").foregroundStyle(TBDTokens.muted) }
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
            Text("Say the trigger phrase to insert the text. Type \\n for a line break.").foregroundStyle(TBDTokens.muted)
            HStack(spacing: TBDTokens.Space.sm) {
                TextField("Trigger, e.g. my address", text: $trigger).tbdField().onSubmit(add)
                TextField("Text to insert", text: $expansion).tbdField().onSubmit(add)
                Button("Add", action: add).buttonStyle(TBDButtonStyle(.secondary))
                    .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.snippetError { Text(error).font(.system(size: 12)).foregroundStyle(TBDTokens.alert) }
            if model.snippets.count > 5 { TextField("Search snippets", text: $model.snippetQuery).tbdField() }
            ForEach(model.filteredSnippets) { snippet in
                if editing == snippet.id {
                    HStack(spacing: TBDTokens.Space.sm) {
                        TextField("Trigger", text: $editTrigger).tbdField()
                        TextField("Text", text: $editExpansion).tbdField()
                        Button("Save") { if model.updateSnippet(id: snippet.id, trigger: editTrigger, expansion: editExpansion) { editing = nil } }
                            .buttonStyle(TBDButtonStyle(.primary))
                        Button("Cancel") { editing = nil; model.snippetError = nil }.buttonStyle(TBDButtonStyle(.quiet))
                    }
                } else {
                    HStack {
                        Toggle("", isOn: Binding(get: { snippet.isEnabled }, set: { _ in model.toggle(snippet) })).labelsHidden().toggleStyle(.checkbox)
                        Text(snippet.trigger)
                        Image(systemName: "arrow.right").foregroundStyle(TBDTokens.muted)
                        Text(snippet.action.map { "Press \($0.label)" } ?? TBDVocabularyModel.editable(snippet.expansion)).lineLimit(1)
                        Spacer()
                        Text("used \(snippet.useCount)×").font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
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
                }
            }
            if model.snippets.isEmpty { Text("No snippets yet.").foregroundStyle(TBDTokens.muted) }
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
                .foregroundStyle(TBDTokens.muted)
            HStack(spacing: TBDTokens.Space.sm) {
                Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(TBDButtonStyle(.primary)).disabled(!model.canExport)
                Button { importFile() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(TBDButtonStyle(.secondary))
                if !model.canExport { Text("Add a word or snippet to enable export.").font(.system(size: 11)).foregroundStyle(TBDTokens.muted) }
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
            line("Exported \(words) word\(words == 1 ? "" : "s") and \(snippets) snippet\(snippets == 1 ? "" : "s") to \(filename).", color: TBDTokens.muted)
        case .imported(let result): line(TBDVocabularyModel.summary(of: result), color: TBDTokens.muted)
        case .failed(let message): line(message, color: TBDTokens.alert)
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.system(size: 12)).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
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
            Text("Import vocabulary").font(TBDTokens.Typography.title).foregroundStyle(TBDTokens.ink)
            Text("The file has \(preview.wordsTotal) word\(preview.wordsTotal == 1 ? "" : "s") and \(preview.snippetsTotal) snippet\(preview.snippetsTotal == 1 ? "" : "s").")
            if preview.hasConflicts {
                Text("\(preview.wordConflicts.count + preview.snippetConflicts.count) already exist here. \(preview.duplicateWords.count + preview.duplicateSnippets.count) repeat inside the file.")
                    .foregroundStyle(TBDTokens.muted)
            }
            Picker("When an entry already exists", selection: $model.conflictPolicy) {
                Text("Keep mine").tag(TBDVocabularyBackup.ConflictPolicy.skip)
                Text("Use the file's").tag(TBDVocabularyBackup.ConflictPolicy.replace)
                Text("Replace all").tag(TBDVocabularyBackup.ConflictPolicy.replaceAll)
            }
            .pickerStyle(.segmented)
            if model.conflictPolicy == .replaceAll {
                if preview.hasRemovals {
                    Text("Replace all deletes \(preview.wordsRemoved.count) word\(preview.wordsRemoved.count == 1 ? "" : "s") and \(preview.snippetsRemoved.count) snippet\(preview.snippetsRemoved.count == 1 ? "" : "s") that are not in the file: \((preview.wordsRemoved + preview.snippetsRemoved).prefix(8).joined(separator: ", ")).")
                        .foregroundStyle(TBDTokens.alert)
                } else {
                    Text("Nothing here is missing from the file, so nothing is deleted.").foregroundStyle(TBDTokens.muted)
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
    }
}
