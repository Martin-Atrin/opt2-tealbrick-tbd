import SwiftUI
import TBDDesign
import TBDSpeech

/// Hotkeys and dictation behaviour. Words, snippets and the text pipeline live on the Vocabulary page.
struct TBDDictationSettings: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0

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
            TBDSettingsRow("Accessibility", help: "Needed for global hotkeys and pasting into other apps.") {
                if TBDPasteService.isTrusted && !context.hotkeyPermissionMissing {
                    TBDChip("Allowed")
                } else {
                    Button("Allow…") { TBDPasteService.requestTrust(); TBDPasteService.openAccessibilitySettings() }
                        .buttonStyle(TBDButtonStyle(.secondary))
                }
            }
            TBDSettingsRow("Vocabulary", help: "Processing mode, filler removal, custom words, snippets, spoken punctuation and backup are on the Vocabulary page.") {
                Button("Open Vocabulary") { env.selectedTab = .vocabulary; context.bringToFront() }
                    .buttonStyle(TBDButtonStyle(.secondary))
            }
        }
        .id(tick)
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
