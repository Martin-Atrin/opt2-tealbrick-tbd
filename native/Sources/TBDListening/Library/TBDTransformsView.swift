import SwiftUI
import TBDDesign
import TBDSpeech

/// Transforms page state: the Transform library and Transform history. Ported from the earlier
/// app's TransformsView, TransformEditorSheet and TransformsViewModel.
@MainActor
final class TBDTransformsModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case transforms = "My Transforms"
        case history = "History"
        var id: String { rawValue }
    }
    static let historyLimit = 200

    @Published var section: Section = .transforms
    @Published var transforms: [TBDPrompt] = []
    @Published var missingBuiltIns = 0
    @Published var history: [TBDTransformRun] = []
    @Published var historyTotal = 0
    @Published var historySearch = ""
    @Published var error: String?
    let database: TBDListeningDatabase?
    /// Re-registers hotkeys after a change (one binding per Transform with a hotkey).
    var onHotkeysChanged: () -> Void = {}

    init(database: TBDListeningDatabase?) { self.database = database }

    func load() {
        guard let database else { return }
        transforms = (try? database.prompts(category: .transform)) ?? []
        missingBuiltIns = ((try? database.deletedPrompts()) ?? []).filter { $0.isBuiltIn && $0.category == .transform }.count
        history = (try? database.transformRuns(limit: Self.historyLimit)) ?? []
        historyTotal = (try? database.transformRunCount()) ?? 0
    }

    /// Search checks Transform names, source apps, original text and transformed text.
    var shownHistory: [TBDTransformRun] {
        let query = historySearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return history }
        return history.filter { run in
            [run.transformName, run.sourceAppDisplayName, run.inputText, run.outputText].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func newTransform() -> TBDPrompt {
        TBDPrompt(name: "", content: "", category: .transform, sortOrder: max(200, (transforms.map(\.sortOrder).max() ?? 199) + 1))
    }

    /// Returns false (with `error` set) when the Transform could not be saved.
    @discardableResult
    func save(_ transform: TBDPrompt) -> Bool { attempt { try self.database?.savePrompt(transform) } }
    func delete(_ transform: TBDPrompt) { attempt { try self.database?.deletePrompt(id: transform.id) } }
    func reset(_ transform: TBDPrompt) { attempt { try self.database?.resetBuiltInPrompt(id: transform.id) } }
    func restoreMissing() { attempt { try self.database?.restoreMissingBuiltIns(category: .transform) } }
    func toggleMenu(_ transform: TBDPrompt) { attempt { try self.database?.togglePromptVisibility(id: transform.id) } }
    func clearHotkey(_ transform: TBDPrompt) {
        var item = transform; item.hotkey = nil
        attempt { try self.database?.savePrompt(item) }
    }

    func deleteRun(_ run: TBDTransformRun) { attempt { try self.database?.deleteTransformRun(id: run.id) } }
    func clearHistory() { attempt { try self.database?.clearTransformRuns() } }

    @discardableResult
    private func attempt(_ body: () throws -> Void) -> Bool {
        defer { load(); onHotkeysChanged() }
        do { try body(); error = nil; return true } catch { self.error = error.localizedDescription; return false }
    }
}

struct TBDTransformsView: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @StateObject private var model: TBDTransformsModel
    @State private var editing: TBDPrompt?
    @State private var confirmClear = false

    init(context: TBDListeningContext) {
        self.context = context
        let model = TBDTransformsModel(database: context.env.database)
        model.onHotkeysChanged = { [weak context] in context?.reloadHotkeys() }
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            Text("Press a hotkey on any selected text to rewrite it through your “general” model route, in any app. The result is pasted over the selection.")
                .foregroundStyle(TBDTokens.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("", selection: $model.section) {
                    ForEach(TBDTransformsModel.Section.allCases) { section in
                        Text(section == .history ? "History (\(model.historyTotal))" : section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(TBDTokens.alert).lineLimit(2) }
            }
            switch model.section {
            case .transforms: library
            case .history: historyList
            }
        }
        .task(id: env.revision) { model.load() }
        .sheet(item: $editing) { transform in
            TBDTransformEditorSheet(transform: transform, isNew: !model.transforms.contains { $0.id == transform.id }, model: model)
        }
        .confirmationDialog("Clear Transform history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { model.clearHistory() }
        } message: { Text("Every saved input and output is removed from this Mac.") }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
                HStack {
                    Button { editing = model.newTransform() } label: { Label("Create your own", systemImage: "plus") }
                        .buttonStyle(TBDButtonStyle(.secondary))
                    Spacer()
                    if model.missingBuiltIns > 0 {
                        Button("Restore missing defaults") { model.restoreMissing() }.buttonStyle(TBDButtonStyle(.quiet))
                    }
                }
                ForEach(model.transforms) { transform in card(transform) }
            }
        }
    }

    private func card(_ transform: TBDPrompt) -> some View {
        HStack(alignment: .top, spacing: TBDTokens.Space.md) {
            VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                HStack(spacing: TBDTokens.Space.sm) {
                    Text(transform.name).font(TBDTokens.Typography.control)
                    if transform.isBuiltIn { TBDChip("Built-in", color: TBDTokens.muted) }
                    if !transform.isVisible { TBDChip("Hidden from menu", color: TBDTokens.muted) }
                }
                Text(transform.content).font(.system(size: 12)).foregroundStyle(TBDTokens.muted).lineLimit(2)
            }
            Spacer()
            if let hotkey = transform.hotkey.flatMap({ try? TBDHotkey.parse($0) }) {
                TBDChip(hotkey.displayName)
                Button { model.clearHotkey(transform) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(TBDButtonStyle(.icon)).help("Clear shortcut")
            } else {
                Text("No shortcut bound").font(.system(size: 12)).foregroundStyle(TBDTokens.muted)
            }
            Button { model.toggleMenu(transform) } label: { Image(systemName: transform.isVisible ? "menubar.rectangle" : "eye.slash") }
                .buttonStyle(TBDButtonStyle(.icon)).help(transform.isVisible ? "Hide from the menu-bar Transform menu" : "Show in the menu-bar Transform menu")
            Button { editing = transform } label: { Image(systemName: "pencil") }.buttonStyle(TBDButtonStyle(.icon)).help("Edit")
            Button { model.delete(transform) } label: { Image(systemName: "trash") }.buttonStyle(TBDButtonStyle(.icon)).help("Delete this Transform")
        }
        .tbdCard(padding: TBDTokens.Space.md)
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            HStack {
                TextField("Search history", text: $model.historySearch).tbdField().frame(maxWidth: 280)
                Spacer()
                Button("Clear history") { confirmClear = true }.buttonStyle(TBDButtonStyle(.destructive)).disabled(model.historyTotal == 0)
            }
            if model.historyTotal > model.history.count {
                Text("Showing the most recent \(model.history.count) of \(model.historyTotal) saved runs.").font(.system(size: 12)).foregroundStyle(TBDTokens.muted)
            }
            if model.history.isEmpty {
                Text("No saved Transform runs yet. Completed edits will appear here.").foregroundStyle(TBDTokens.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
                    ForEach(model.shownHistory) { run in historyRow(run) }
                }
            }
        }
    }

    private func historyRow(_ run: TBDTransformRun) -> some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
            HStack(spacing: TBDTokens.Space.sm) {
                Text(run.transformName).font(TBDTokens.Typography.control)
                Text("·").foregroundStyle(TBDTokens.muted)
                Text(run.sourceAppDisplayName).foregroundStyle(TBDTokens.muted)
                Text(run.createdAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(TBDTokens.muted)
                Spacer()
                Button("Copy Original") { TBDPasteService.copy(run.inputText) }.buttonStyle(TBDButtonStyle(.quiet))
                Button("Copy Transformed") { TBDPasteService.copy(run.outputText) }.buttonStyle(TBDButtonStyle(.quiet))
                Button { model.deleteRun(run) } label: { Image(systemName: "trash") }.buttonStyle(TBDButtonStyle(.icon)).help("Delete")
            }
            TBDLabel("Original")
            Text(run.inputText).font(TBDTokens.Typography.body).lineLimit(4).textSelection(.enabled)
            TBDLabel("Transformed")
            Text(run.outputText).font(TBDTokens.Typography.body).lineLimit(6).textSelection(.enabled)
        }
        .tbdCard(padding: TBDTokens.Space.md)
    }
}

struct TBDTransformEditorSheet: View {
    @State var transform: TBDPrompt
    let isNew: Bool
    @ObservedObject var model: TBDTransformsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            Text(isNew ? "New Transform" : "Edit Transform").font(TBDTokens.Typography.title)
            if transform.isBuiltIn {
                Text("Built-in Transform — you can edit it freely. Your changes survive app launches.").font(.system(size: 12)).foregroundStyle(TBDTokens.muted)
            }
            TBDLabel("Name")
            TextField("Name", text: $transform.name).tbdField()
            TBDLabel("Prompt")
            TextEditor(text: $transform.content).font(TBDTokens.Typography.body).frame(height: 160).scrollContentBackground(.hidden)
                .padding(6).background(TBDTokens.paper)
                .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border))
            Text("Tell the model how to change the selected text. Be specific — the prompt runs verbatim on every press.")
                .font(.system(size: 12)).foregroundStyle(TBDTokens.muted)
            TBDSettingsRow("Hotkey", help: "Optional — leave empty to keep this Transform dormant.") {
                TBDHotkeyRecorderView(value: transform.hotkey.flatMap { try? TBDHotkey.parse($0) }, defaultHotkey: nil) { hotkey in
                    transform.hotkey = hotkey?.serialized
                }
            }
            TBDSettingsRow("Running label", help: "Shown in the pill while it runs. Empty uses “\(TBDPrompt.defaultRunningLabel(forName: transform.name))”.") {
                TextField("Default", text: Binding(get: { transform.runningLabel ?? "" }, set: { transform.runningLabel = $0.isEmpty ? nil : $0 }))
                    .tbdField().frame(width: 180)
            }
            TBDSettingsRow("Show in the menu-bar Transform menu") {
                Toggle("", isOn: $transform.isVisible).labelsHidden().toggleStyle(.switch)
            }
            TBDInferenceFields(inference: $transform.inference, modelOverride: $transform.modelOverride)
            if let error = model.error { Text(error).foregroundStyle(TBDTokens.alert) }
            HStack {
                if transform.isBuiltIn, !isNew {
                    Button("Reset Transform") { model.reset(transform); dismiss() }.buttonStyle(TBDButtonStyle(.quiet))
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(TBDButtonStyle(.quiet))
                Button("Save") { if model.save(transform) { dismiss() } }.buttonStyle(TBDButtonStyle(.primary))
                    .disabled(transform.name.trimmingCharacters(in: .whitespaces).isEmpty || transform.content.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(TBDTokens.Space.xl).frame(width: 520)
    }
}
