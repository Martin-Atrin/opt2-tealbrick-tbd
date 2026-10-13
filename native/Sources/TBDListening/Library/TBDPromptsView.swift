import SwiftUI
import TBDDesign
import TBDSpeech

/// Prompts page state: the transcript prompt library (collections, versions, trash) and the
/// meeting Ask quick prompts. Ported from the earlier app's PromptsWorkspaceView, PromptLibraryView
/// and AskPromptsSheet.
@MainActor
final class TBDPromptsModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case transcriptPrompts = "Transcript prompts"
        case liveAsk = "Live Ask"
        var id: String { rawValue }
    }
    /// Collection filter: everything, unfiled prompts, or one collection.
    enum Filter: Hashable { case all, unfiled, collection(String) }

    @Published var section: Section = .transcriptPrompts
    @Published var prompts: [TBDPrompt] = []
    @Published var collections: [TBDPromptCollection] = []
    @Published var deleted: [TBDPrompt] = []
    @Published var quickPrompts: [TBDQuickPromptItem] = []
    @Published var versions: [TBDPromptVersion] = []
    @Published var selectedID: String?
    @Published var draft: TBDPrompt?
    @Published var search = ""
    @Published var filter: Filter = .all
    @Published var error: String?
    let database: TBDListeningDatabase?

    init(database: TBDListeningDatabase?) { self.database = database }

    func load() {
        guard let database else { return }
        prompts = (try? database.prompts(category: .result)) ?? []
        collections = (try? database.promptCollections()) ?? []
        deleted = ((try? database.deletedPrompts()) ?? []).filter { $0.category == .result }
        quickPrompts = (try? database.quickPrompts()) ?? []
        if selectedID == nil || !prompts.contains(where: { $0.id == selectedID }) { select(prompts.first) }
        else if let selectedID { versions = (try? database.promptVersions(promptId: selectedID)) ?? [] }
    }

    var shown: [TBDPrompt] {
        prompts.filter { prompt in
            switch filter {
            case .all: true
            case .unfiled: prompt.collectionId == nil
            case .collection(let id): prompt.collectionId == id
            }
        }
        .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.content.localizedCaseInsensitiveContains(search) }
    }

    func select(_ prompt: TBDPrompt?) {
        selectedID = prompt?.id
        draft = prompt
        versions = prompt.flatMap { try? database?.promptVersions(promptId: $0.id) } ?? []
        error = nil
    }

    func newPrompt() {
        let prompt = TBDPrompt(name: "New prompt", content: "Describe what to produce from the transcript.",
                               sortOrder: (prompts.map(\.sortOrder).max() ?? 0) + 1,
                               collectionId: { if case .collection(let id) = filter { return id }; return nil }())
        selectedID = prompt.id
        draft = prompt
        versions = []
    }

    func save() { attempt { if let draft { self.select(try self.database?.savePrompt(draft)) } } }
    func delete(_ prompt: TBDPrompt) { attempt { try self.database?.deletePrompt(id: prompt.id); self.selectedID = nil } }
    func restore(_ prompt: TBDPrompt) { attempt { try self.database?.restoreDeletedPrompt(id: prompt.id) } }
    func reset(_ prompt: TBDPrompt) { attempt { self.select(try self.database?.resetBuiltInPrompt(id: prompt.id)) } }
    func use(_ version: TBDPromptVersion) {
        attempt { self.select(try self.database?.restorePromptVersion(promptId: version.promptId, versionId: version.id)) }
    }
    func restoreDefaults() { attempt { try self.database?.restorePromptDefaults() } }
    func toggleVisible(_ prompt: TBDPrompt) { attempt { try self.database?.togglePromptVisibility(id: prompt.id) } }
    func setAutoRun(_ prompt: TBDPrompt, _ on: Bool) { attempt { try self.database?.setPromptAutoRun(id: prompt.id, enabled: on) } }
    func setAutoRun(_ prompt: TBDPrompt, source: TBDSourceKind, _ on: Bool) {
        attempt { try self.database?.setPromptAutoRun(id: prompt.id, source: source, enabled: on) }
    }
    func setNotes(_ prompt: TBDPrompt, _ on: Bool) { attempt { try self.database?.setIncludeMeetingNotes(id: prompt.id, enabled: on) } }
    func assign(_ prompt: TBDPrompt, to collection: String?) { attempt { try self.database?.assignPrompt(id: prompt.id, toCollection: collection) } }

    func addCollection(_ name: String) { attempt { try self.database?.savePromptCollection(TBDPromptCollection(name: name)) } }
    func rename(_ collection: TBDPromptCollection, _ name: String) {
        var item = collection; item.name = name
        attempt { try self.database?.savePromptCollection(item) }
    }
    func deleteCollection(_ collection: TBDPromptCollection) {
        attempt {
            try self.database?.deletePromptCollection(id: collection.id)
            if self.filter == .collection(collection.id) { self.filter = .all }
        }
    }
    func moveCollection(_ collection: TBDPromptCollection, by offset: Int) {
        var ids = collections.map(\.id)
        guard let index = ids.firstIndex(of: collection.id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        attempt { try self.database?.reorderPromptCollections(ids: ids) }
    }

    // Quick prompts
    func saveQuick(_ item: TBDQuickPromptItem) { attempt { try self.database?.saveQuickPrompt(item) } }
    func deleteQuick(_ item: TBDQuickPromptItem) { attempt { try self.database?.deleteQuickPrompt(id: item.id) } }
    func toggleQuickVisible(_ item: TBDQuickPromptItem) { attempt { try self.database?.toggleQuickPromptVisibility(id: item.id) } }
    func pin(_ item: TBDQuickPromptItem, _ pinned: Bool) { attempt { try self.database?.setQuickPromptPinned(id: item.id, pinned: pinned) } }
    func restoreQuick(_ item: TBDQuickPromptItem) { attempt { try self.database?.restoreQuickPromptDefault(id: item.id) } }
    func restoreQuickDefaults() { attempt { try self.database?.restoreQuickPromptDefaults() } }
    func moveQuick(_ item: TBDQuickPromptItem, by offset: Int) {
        var ids = quickPrompts.filter { $0.isPinned == item.isPinned }.map(\.id)
        guard let index = ids.firstIndex(of: item.id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        attempt { try self.database?.reorderQuickPrompts(ids: ids, pinned: item.isPinned) }
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body(); error = nil } catch { self.error = error.localizedDescription }
        load()
    }
}

struct TBDPromptsView: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @StateObject private var model: TBDPromptsModel
    @State private var showCollections = false
    @State private var showTrash = false

    init(context: TBDListeningContext) {
        self.context = context
        _model = StateObject(wrappedValue: TBDPromptsModel(database: context.env.database))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            HStack {
                TBDSegmented(selection: $model.section, options: TBDPromptsModel.Section.allCases.map { ($0, $0.rawValue) })
                Spacer()
                if let error = model.error { Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk).lineLimit(2) }
            }
            switch model.section {
            case .transcriptPrompts: library
            case .liveAsk: TBDQuickPromptsEditor(model: model)
            }
        }
        .task(id: env.revision) { model.load() }
        .sheet(isPresented: $showCollections) { TBDPromptCollectionsSheet(model: model) }
        .sheet(isPresented: $showTrash) { TBDPromptTrashSheet(model: model) }
    }

    private var library: some View {
        HStack(alignment: .top, spacing: TBDTokens.Space.lg) {
            VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
                TextField("Search prompts", text: $model.search).tbdField()
                HStack(spacing: TBDTokens.Space.sm) {
                    Picker("", selection: $model.filter) {
                        Text("All collections").tag(TBDPromptsModel.Filter.all)
                        Text("Unfiled").tag(TBDPromptsModel.Filter.unfiled)
                        ForEach(model.collections) { Text($0.name).tag(TBDPromptsModel.Filter.collection($0.id)) }
                    }
                    .labelsHidden().frame(maxWidth: 180)
                    Spacer()
                    Menu {
                        Button("Manage collections…") { showCollections = true }
                        Button("Trash (\(model.deleted.count))…") { showTrash = true }
                        Divider()
                        Button("Reset to defaults") { model.restoreDefaults() }
                    } label: { Image(systemName: "ellipsis.circle").font(TBDFonts.symbol(16)) }
                        .menuStyle(.borderlessButton).fixedSize().help("Manage collections and restore deleted prompts")
                }
                Button { model.newPrompt() } label: { Label("New prompt", systemImage: "plus") }.buttonStyle(TBDButtonStyle(.secondary))
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.shown) { prompt in row(prompt) }
                        if model.shown.isEmpty {
                            Text("No prompts match.").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft).padding(.top, TBDTokens.Space.sm)
                        }
                    }
                }
            }
            .frame(width: 260)
            ScrollView {
                if model.draft != nil { TBDPromptEditor(model: model) } else {
                    VStack(alignment: .leading, spacing: TBDKit.s1) {
                        Text("Choose a prompt or create one.").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
                        Text("Prompts run on a transcript from its Summarise menu.").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func row(_ prompt: TBDPrompt) -> some View {
        Button { model.select(prompt) } label: {
            HStack(spacing: TBDTokens.Space.sm) {
                Text(prompt.name).font(TBDTokens.Typography.control)
                    .foregroundStyle(prompt.isVisible || model.selectedID == prompt.id ? TBDColor.ink : TBDColor.muted).lineLimit(1)
                Spacer()
                if prompt.isAutoRun { TBDTag("Auto", status: .live) }
                if prompt.isBuiltIn { TBDTag("Built-in", status: .idle) }
                if !prompt.isVisible { Image(systemName: "eye.slash").font(TBDFonts.symbol(13)).foregroundStyle(TBDColor.muted) }
            }
            .padding(.horizontal, TBDTokens.Space.sm).padding(.vertical, TBDKit.s2)
            .background(model.selectedID == prompt.id ? TBDColor.tealWash : .clear, in: TBDBrickShape())
            .overlay(alignment: .bottom) { Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Editor for one transcript prompt: instructions, collection, auto-run, notes, generation settings, versions.
struct TBDPromptEditor: View {
    @ObservedObject var model: TBDPromptsModel

    var body: some View {
        if let draft = Binding($model.draft) {
            let stored = model.prompts.first { $0.id == draft.wrappedValue.id }
            VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
                TBDLabel("Name")
                TextField("Name", text: draft.name).tbdField()
                TBDLabel("Instructions")
                TextEditor(text: draft.content).font(TBDTokens.Typography.body).frame(minHeight: 200).scrollContentBackground(.hidden)
                    .padding(6).background(TBDColor.fieldFill, in: TBDBrickShape()).foregroundStyle(TBDColor.fieldOn)
                    .overlay(TBDBrickShape().strokeBorder(TBDColor.fieldEdge, lineWidth: TBDKit.hair))
                Text("Markdown supported. Sent as the system prompt with the transcript.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                TBDInferenceFields(inference: draft.inference, modelOverride: draft.modelOverride)
                HStack(spacing: TBDTokens.Space.sm) {
                    Button(stored == nil ? "Create" : "Save Changes") { model.save() }.buttonStyle(TBDButtonStyle(.primary))
                        .disabled(stored == draft.wrappedValue)
                    if let stored {
                        if stored.isBuiltIn { Button("Reset to default") { model.reset(stored) }.buttonStyle(TBDButtonStyle(.quiet)) }
                        Spacer()
                        Button("Delete") { model.delete(stored) }.buttonStyle(TBDButtonStyle(.destructive))
                    }
                }
                if let stored { options(stored); history(stored) }
            }
        }
    }

    /// Metadata applies immediately (never a new version).
    @ViewBuilder private func options(_ prompt: TBDPrompt) -> some View {
        TBDSettingsRow("Collection") {
            Picker("", selection: Binding(get: { prompt.collectionId ?? "" }, set: { model.assign(prompt, to: $0.isEmpty ? nil : $0) })) {
                Text("Unfiled").tag("")
                ForEach(model.collections) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().frame(width: 180)
        }
        TBDSettingsRow("Show in the summary menu") {
            Toggle("", isOn: Binding(get: { prompt.isVisible }, set: { _ in model.toggleVisible(prompt) })).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
        }
        TBDSettingsRow("Auto-Run", help: "Run automatically after a transcription finishes (meetings use it when meeting auto-summary is on).") {
            Toggle("", isOn: Binding(get: { prompt.isAutoRun }, set: { model.setAutoRun(prompt, $0) })).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
        }
        if prompt.isAutoRun {
            TBDSettingsRow("Run automatically after") {
                HStack(spacing: TBDTokens.Space.sm) {
                    ForEach(TBDSourceKind.allCases, id: \.self) { source in
                        Toggle(source.label, isOn: Binding(get: { prompt.autoRuns(for: source) }, set: { model.setAutoRun(prompt, source: source, $0) }))
                            .toggleStyle(.checkbox) // design-guard: allow (native checkbox, no kit equivalent)
                            .font(TBDTokens.Typography.hint)
                    }
                }
            }
        }
        TBDSettingsRow("Include meeting notes as context") {
            Toggle("", isOn: Binding(get: { prompt.includeMeetingNotes }, set: { model.setNotes(prompt, $0) })).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
        }
        TBDPromptLabelTargets(promptID: prompt.id)
    }

    @ViewBuilder private func history(_ prompt: TBDPrompt) -> some View {
        TBDLabel("Versions").padding(.top, TBDTokens.Space.md)
        ForEach(model.versions) { version in
            VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                HStack(spacing: TBDTokens.Space.sm) {
                    Text("Version \(version.versionNumber)").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                    TBDTag(version.origin.title, status: .idle)
                    Text(version.createdAt.formatted(date: .abbreviated, time: .shortened)).font(TBDFonts.mono()).foregroundStyle(TBDColor.muted)
                    Spacer()
                    if version.id == prompt.activeVersionId { TBDTag("Current", status: .live) } else {
                        Button("Use this version") { model.use(version) }.buttonStyle(TBDButtonStyle(.quiet))
                    }
                }
                if let note = version.changeNote { Text(note).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted) }
                Text(version.content).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).lineLimit(3)
            }
            .tbdCard(padding: TBDTokens.Space.sm)
        }
    }
}

/// Per-prompt generation settings and model override. Empty fields use the route's defaults.
struct TBDInferenceFields: View {
    @Binding var inference: TBDPromptInference?
    @Binding var modelOverride: String?

    var body: some View {
        DisclosureGroup("Generation settings") {
            VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                field("Temperature (0–2)", Binding(get: { inference?.temperature.map { String($0) } ?? "" },
                                                    set: { update { $0.temperature = Double($1) } ($0) }))
                field("Max tokens", Binding(get: { inference?.maxTokens.map(String.init) ?? "" }, set: { update { $0.maxTokens = Int($1) } ($0) }))
                field("Top P (0–1)", Binding(get: { inference?.topP.map { String($0) } ?? "" }, set: { update { $0.topP = Double($1) } ($0) }))
                field("Top K", Binding(get: { inference?.topK.map(String.init) ?? "" }, set: { update { $0.topK = Int($1) } ($0) }))
                Picker("Thinking", selection: Binding(get: { inference?.thinkingMode ?? .providerDefault },
                                                      set: { mode in update { settings, _ in settings.thinkingMode = mode } ("") })) {
                    Text("Automatic").tag(TBDPromptInference.ThinkingMode.providerDefault)
                    Text("On").tag(TBDPromptInference.ThinkingMode.enabled)
                    Text("Off").tag(TBDPromptInference.ThinkingMode.disabled)
                }
                .frame(width: 260)
                if inference?.thinkingMode == .enabled {
                    Picker("Reasoning effort", selection: Binding(get: { inference?.reasoningEffort ?? .medium },
                                                                  set: { effort in update { settings, _ in settings.reasoningEffort = effort } ("") })) {
                        ForEach(TBDPromptInference.ReasoningEffort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 260)
                }
                field("Custom model ID", Binding(get: { modelOverride ?? "" }, set: { modelOverride = $0.isEmpty ? nil : $0 }))
                Text("Sent today: temperature, max tokens and model. The others are kept with the prompt.")
                    .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
            .padding(.top, TBDTokens.Space.xs)
        }
        .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.ink)
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        HStack { Text(title).frame(width: 140, alignment: .leading); TextField("Default", text: text).tbdField().frame(width: 200) }
    }

    /// Applies an edit to a copy (blank fields clear it) and stores nil when everything is default.
    private func update(_ change: @escaping (inout TBDPromptInference, String) -> Void) -> (String) -> Void {
        { text in
            var settings = inference ?? TBDPromptInference()
            change(&settings, text.trimmingCharacters(in: .whitespaces))
            inference = settings.normalized
        }
    }
}

struct TBDPromptCollectionsSheet: View {
    @ObservedObject var model: TBDPromptsModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            Text("Collections").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
            Text("Collections organise prompts. They are never sent to the model; deleting one leaves its prompts unfiled.")
                .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("New collection", text: $newName).tbdField().onSubmit(add)
                Button("Create", action: add).buttonStyle(TBDButtonStyle(.secondary)).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(model.collections) { collection in
                HStack {
                    Text(collection.name).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                    Spacer()
                    Button { if let name = TBDTextPrompt.ask("Rename collection", message: "", initial: collection.name, action: "Rename") { model.rename(collection, name) } }
                        label: { Image(systemName: "pencil") }.buttonStyle(TBDButtonStyle(.icon)).help("Rename collection")
                    Button { model.moveCollection(collection, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(TBDButtonStyle(.icon))
                    Button { model.moveCollection(collection, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(TBDButtonStyle(.icon))
                    Button { model.deleteCollection(collection) } label: { Image(systemName: "trash") }
                        .buttonStyle(TBDButtonStyle(.icon)).help("Delete collection")
                }
            }
            if let error = model.error { Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk) }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(TBDButtonStyle(.primary)) }
        }
        .padding(TBDTokens.Space.xl).frame(width: 460).background(TBDColor.tile)
    }

    private func add() {
        model.addCollection(newName)
        if model.error == nil { newName = "" }
    }
}

struct TBDPromptTrashSheet: View {
    @ObservedObject var model: TBDPromptsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            Text("Trash").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
            if model.deleted.isEmpty {
                Text("No deleted prompts. Removed prompts can be restored here with their version history.")
                    .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
            }
            ForEach(model.deleted) { prompt in
                HStack {
                    Text(prompt.name).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                    if prompt.isBuiltIn { TBDTag("Built-in", status: .idle) }
                    Spacer()
                    Button("Restore") { model.restore(prompt) }.buttonStyle(TBDButtonStyle(.secondary))
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(TBDButtonStyle(.primary)) }
        }
        .padding(TBDTokens.Space.xl).frame(width: 420).background(TBDColor.tile)
    }
}

/// Live Ask quick prompts: pin to the after-answer strip, show/hide, edit, reorder, restore.
struct TBDQuickPromptsEditor: View {
    @ObservedObject var model: TBDPromptsModel
    @State private var editing: TBDQuickPromptItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
                Text("Quick prompts appear in a meeting's Ask tab. Visible prompts fill the empty Ask state; pinned prompts form the strip after each answer.")
                    .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { editing = TBDQuickPromptItem(label: "", prompt: "") } label: { Label("New quick prompt", systemImage: "plus") }
                        .buttonStyle(TBDButtonStyle(.secondary))
                    Spacer()
                    Button("Restore defaults") { model.restoreQuickDefaults() }.buttonStyle(TBDButtonStyle(.quiet))
                }
                TBDLabel("Pinned")
                bucket(model.quickPrompts.filter(\.isPinned))
                TBDLabel("All prompts").padding(.top, TBDTokens.Space.md)
                bucket(model.quickPrompts.filter { !$0.isPinned })
            }
        }
        .sheet(item: $editing) { item in TBDQuickPromptSheet(item: item) { model.saveQuick($0) } }
    }

    private func bucket(_ items: [TBDQuickPromptItem]) -> some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
            ForEach(items) { item in
                HStack(spacing: TBDTokens.Space.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: TBDTokens.Space.xs) {
                            Text(item.label).font(TBDTokens.Typography.control).foregroundStyle(item.isVisible ? TBDColor.ink : TBDColor.muted)
                            if let group = item.groupLabel { TBDTag(group, status: .idle) }
                        }
                        Text(item.prompt).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).lineLimit(2)
                    }
                    Spacer()
                    Button { model.pin(item, !item.isPinned) } label: { Image(systemName: item.isPinned ? "pin.fill" : "pin") }
                        .buttonStyle(TBDButtonStyle(.icon)).help(item.isPinned ? "Unpin" : "Pin to the after-answer strip")
                    Button { model.toggleQuickVisible(item) } label: { Image(systemName: item.isVisible ? "eye" : "eye.slash") }
                        .buttonStyle(TBDButtonStyle(.icon)).help(item.isVisible ? "Hide" : "Show")
                    Button { model.moveQuick(item, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(TBDButtonStyle(.icon))
                    Button { model.moveQuick(item, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(TBDButtonStyle(.icon))
                    Button { editing = item } label: { Image(systemName: "pencil") }.buttonStyle(TBDButtonStyle(.icon)).help("Edit")
                    if item.isBuiltIn {
                        Button { model.restoreQuick(item) } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(TBDButtonStyle(.icon)).help("Restore the built-in text")
                    } else {
                        Button { model.deleteQuick(item) } label: { Image(systemName: "trash") }.buttonStyle(TBDButtonStyle(.icon)).help("Delete")
                    }
                }
                .padding(.vertical, TBDKit.s2)
                .overlay(alignment: .bottom) { Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair) }
            }
        }
    }
}

struct TBDQuickPromptSheet: View {
    @State var item: TBDQuickPromptItem
    let onSave: (TBDQuickPromptItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            Text(item.label.isEmpty ? "New quick prompt" : "Edit quick prompt").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
            TBDLabel("Label (shown on the chip)")
            TextField("Label", text: $item.label).tbdField()
            TBDLabel("Prompt (sent to the model)")
            TextEditor(text: $item.prompt).font(TBDTokens.Typography.body).frame(height: 120).scrollContentBackground(.hidden)
                .padding(6).background(TBDColor.fieldFill, in: TBDBrickShape()).foregroundStyle(TBDColor.fieldOn)
                .overlay(TBDBrickShape().strokeBorder(TBDColor.fieldEdge, lineWidth: TBDKit.hair))
            TBDLabel("Group (optional)")
            TextField("For example CAPTURE", text: Binding(get: { item.groupLabel ?? "" }, set: { item.groupLabel = $0 })).tbdField()
            Toggle("Pinned to the after-answer strip", isOn: $item.isPinned).toggleStyle(TBDSwitchStyle())
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(TBDButtonStyle(.quiet))
                Button("Save") { onSave(item); dismiss() }.buttonStyle(TBDButtonStyle(.primary))
                    .disabled(item.label.trimmingCharacters(in: .whitespaces).isEmpty || item.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(TBDTokens.Space.xl).frame(width: 460).background(TBDColor.tile)
    }
}
