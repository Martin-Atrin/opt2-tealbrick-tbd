import SwiftUI
import TBDDesign
import TBDSpeech

/// Hotkeys, text pipeline, vocabulary and snippets.
struct TBDDictationSettings: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0
    @State private var words: [TBDCustomWord] = []
    @State private var snippets: [TBDSnippet] = []
    @State private var newWord = ""
    @State private var newReplacement = ""
    @State private var newTrigger = ""
    @State private var newExpansion = ""

    private static let presets = ["fn", "right_option", "right_command", "ctrl+opt", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "ctrl+opt+space"]

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            TBDHotkeyField(title: "Dictation hotkey", help: "Hold to talk, release to paste. Tap once for hands-free, tap again to stop. Esc cancels.",
                           value: prefs.dictationHotkey, presets: Self.presets, allowEmpty: false) { value in
                prefs.dictationHotkey = value
                context.reloadHotkeys()
            }
            TBDHotkeyField(title: "Transform hotkey", help: "Rewrites the selected text with the current transform prompt. Empty disables it.",
                           value: prefs.transformHotkey, presets: ["ctrl+opt+t", "f18", "f19"], allowEmpty: true) { value in
                prefs.transformHotkey = value
                context.reloadHotkeys()
            }
            TBDSettingsRow("Undo window", help: "How long cancel waits before discarding a dictation. Undo in the pill transcribes and pastes it.") {
                Picker("", selection: tbdBinding({ prefs.dictationUndoWindow }, { prefs.dictationUndoWindow = $0 }, refresh: { tick += 1 })) {
                    ForEach(TBDCancelUndo.Window.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            TBDSettingsRow("Remove filler words", help: "Drops “um”, “uh” and similar from dictation.") {
                Toggle("", isOn: tbdBinding({ prefs.removeFillers }, { prefs.removeFillers = $0 }, refresh: { tick += 1 })).labelsHidden().toggleStyle(.switch)
            }
            TBDSettingsRow("Accessibility", help: "Needed for global hotkeys and pasting into other apps.") {
                if TBDPasteService.isTrusted && !context.hotkeyPermissionMissing {
                    TBDChip("Allowed")
                } else {
                    Button("Allow…") { TBDPasteService.requestTrust(); TBDPasteService.openAccessibilitySettings() }
                        .buttonStyle(TBDButtonStyle(.secondary))
                }
            }
            TBDLabel("Vocabulary").padding(.top, TBDTokens.Space.xl)
            Text("Fix words the engine gets wrong. Leave the replacement empty to fix capitalisation only.")
                .foregroundStyle(TBDTokens.muted).padding(.vertical, TBDTokens.Space.xs)
            HStack(spacing: TBDTokens.Space.sm) {
                TextField("Heard as", text: $newWord).tbdField()
                TextField("Replace with", text: $newReplacement).tbdField()
                Button("Add") { addWord() }.buttonStyle(TBDButtonStyle(.secondary)).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(words) { word in
                HStack {
                    Toggle("", isOn: Binding(get: { word.isEnabled }, set: { var w = word; w.isEnabled = $0; try? env.database?.save(w); reload() }))
                        .labelsHidden().toggleStyle(.checkbox)
                    Text(word.word)
                    Image(systemName: "arrow.right").foregroundStyle(TBDTokens.muted)
                    Text(word.replacement ?? word.word).foregroundStyle(TBDTokens.ink)
                    Spacer()
                    Button { try? env.database?.deleteCustomWord(id: word.id); reload() } label: { Image(systemName: "trash") }
                        .buttonStyle(TBDButtonStyle(.icon)).accessibilityLabel("Delete \(word.word)")
                }
            }
            TBDLabel("Snippets").padding(.top, TBDTokens.Space.xl)
            Text("Say the trigger phrase to insert the text.").foregroundStyle(TBDTokens.muted).padding(.vertical, TBDTokens.Space.xs)
            HStack(spacing: TBDTokens.Space.sm) {
                TextField("Trigger, e.g. my address", text: $newTrigger).tbdField()
                TextField("Text to insert", text: $newExpansion).tbdField()
                Button("Add") { addSnippet() }.buttonStyle(TBDButtonStyle(.secondary))
                    .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty || newExpansion.isEmpty)
            }
            ForEach(snippets) { snippet in
                HStack {
                    Toggle("", isOn: Binding(get: { snippet.isEnabled }, set: { var s = snippet; s.isEnabled = $0; try? env.database?.save(s); reload() }))
                        .labelsHidden().toggleStyle(.checkbox)
                    Text(snippet.trigger)
                    Image(systemName: "arrow.right").foregroundStyle(TBDTokens.muted)
                    Text(snippet.expansion).lineLimit(1)
                    Spacer()
                    Text("used \(snippet.useCount)×").font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
                    Button { try? env.database?.deleteSnippet(id: snippet.id); reload() } label: { Image(systemName: "trash") }
                        .buttonStyle(TBDButtonStyle(.icon)).accessibilityLabel("Delete \(snippet.trigger)")
                }
            }
        }
        .id(tick)
        .onAppear(perform: reload)
    }

    private func reload() {
        words = (try? env.database?.customWords()) ?? []
        snippets = (try? env.database?.snippets()) ?? []
    }

    private func addWord() {
        let replacement = newReplacement.trimmingCharacters(in: .whitespaces)
        try? env.database?.save(TBDCustomWord(word: newWord.trimmingCharacters(in: .whitespaces), replacement: replacement.isEmpty ? nil : replacement))
        newWord = ""; newReplacement = ""
        reload()
    }

    private func addSnippet() {
        try? env.database?.save(TBDSnippet(trigger: newTrigger.trimmingCharacters(in: .whitespaces), expansion: newExpansion))
        newTrigger = ""; newExpansion = ""
        reload()
    }
}

/// Text hotkey editor with validation and presets.
struct TBDHotkeyField: View {
    let title: String
    let help: String
    let presets: [String]
    let allowEmpty: Bool
    let onSave: (String) -> Void
    @State private var draft: String
    @State private var error: String?

    init(title: String, help: String, value: String, presets: [String], allowEmpty: Bool, onSave: @escaping (String) -> Void) {
        self.title = title; self.help = help; self.presets = presets; self.allowEmpty = allowEmpty; self.onSave = onSave
        _draft = State(initialValue: value)
    }

    var body: some View {
        TBDSettingsRow(title, help: error ?? help) {
            HStack(spacing: TBDTokens.Space.sm) {
                if let hotkey = try? TBDHotkey.parse(draft) { TBDChip(hotkey.displayName) }
                TextField(allowEmpty ? "none" : "fn", text: $draft).tbdField().frame(width: 140).onSubmit(save)
                Menu("Presets") {
                    ForEach(presets, id: \.self) { preset in Button(preset) { draft = preset; save() } }
                    if allowEmpty { Button("None") { draft = ""; save() } }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button("Save", action: save).buttonStyle(TBDButtonStyle(.secondary))
            }
        }
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        if value.isEmpty && allowEmpty { error = nil; onSave(""); return }
        do {
            let hotkey = try TBDHotkey.parse(value)
            draft = hotkey.serialized
            error = nil
            onSave(hotkey.serialized)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
