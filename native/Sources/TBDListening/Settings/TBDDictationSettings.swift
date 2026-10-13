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

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            TBDDictationHotkeyRows(context: context) { tick += 1 }
            TBDHotkeyRow(title: "Transform hotkey", help: "Rewrites the selected text with the current transform prompt.",
                         surface: .transform, context: context) { tick += 1 }
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

/// v1 Capture > Dictation hotkey rows: push to talk, hands-free, clipboard-only, AI polish, and the mode guide.
struct TBDDictationHotkeyRows: View {
    let context: TBDListeningContext
    let onChanged: () -> Void

    var body: some View {
        let prefs = context.env.preferences
        let handsFree = prefs.hotkey(for: .handsFree)
        let pushToTalk = prefs.hotkey(for: .pushToTalk)
        let shared = TBDDictationHotkeyPlan.isSharedGesture(handsFree: handsFree, pushToTalk: pushToTalk)
        VStack(alignment: .leading, spacing: 0) {
            TBDHotkeyRow(title: "Push to talk", help: "Hold to dictate, release to stop.", surface: .pushToTalk, context: context,
                         displayOverride: TBDDictationHotkeyPlan.pushToTalkLabelOverride(pushToTalk: pushToTalk, handsFree: handsFree),
                         onChanged: onChanged)
            TBDHotkeyRow(title: "Hands-free mode", help: shared ? "Double-tap to start; tap again to stop." : "Tap to start; tap again to stop.",
                         surface: .handsFree, context: context,
                         displayOverride: TBDDictationHotkeyPlan.handsFreeLabelOverride(handsFree: handsFree, pushToTalk: pushToTalk),
                         defaultLabelOverride: TBDDictationHotkeyPlan.handsFreeLabelOverride(handsFree: .fn, pushToTalk: pushToTalk),
                         onChanged: onChanged)
            TBDHotkeyRow(title: "Clipboard-only dictation",
                         help: "Optional extra shortcut. Tap to start or stop like hands-free. Copies the transcript instead of pasting into the focused field.",
                         surface: .dictationClipboard, context: context, onChanged: onChanged)
            TBDHotkeyRow(title: "AI polish this dictation",
                         help: "Optional extra shortcut. Tap to start or stop like hands-free (no hold-to-talk). Always runs cleanup for that take, even when dictation cleanup is off. Needs a model on the Cleanup route.",
                         surface: .dictationAIPolish, context: context, onChanged: onChanged)
            let guide = Self.guide(handsFree: handsFree, pushToTalk: pushToTalk, clipboard: prefs.hotkey(for: .dictationClipboard),
                                   aiPolish: prefs.hotkey(for: .dictationAIPolish))
            if !guide.isEmpty {
                VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                    ForEach(guide, id: \.action) { row in
                        HStack(spacing: TBDTokens.Space.sm) {
                            TBDChip(row.key)
                            Text(row.verb).foregroundStyle(TBDTokens.muted).frame(width: 72, alignment: .leading)
                            Text(row.action).foregroundStyle(TBDTokens.ink)
                            Text(row.detail).foregroundStyle(TBDTokens.muted)
                        }
                    }
                }
                .padding(.vertical, TBDTokens.Space.md)
            }
        }
    }

    struct GuideRow: Equatable {
        let key: String
        let verb: String
        let action: String
        let detail: String
    }

    /// v1 `dictationModeGuide`: one line per enabled dictation key.
    static func guide(handsFree: TBDHotkey?, pushToTalk: TBDHotkey?, clipboard: TBDHotkey?, aiPolish: TBDHotkey?) -> [GuideRow] {
        var rows: [GuideRow] = []
        if let pushToTalk { rows.append(GuideRow(key: pushToTalk.shortSymbol, verb: "Hold", action: "Push to talk", detail: "Release to stop")) }
        if let handsFree {
            let verb = TBDDictationHotkeyPlan.isSharedGesture(handsFree: handsFree, pushToTalk: pushToTalk) ? "Double-tap" : "Tap"
            rows.append(GuideRow(key: handsFree.shortSymbol, verb: verb, action: "Hands-free mode", detail: "Tap again to stop"))
        }
        if let clipboard { rows.append(GuideRow(key: clipboard.shortSymbol, verb: "Tap", action: "Clipboard-only", detail: "Copies; does not paste")) }
        if let aiPolish { rows.append(GuideRow(key: aiPolish.shortSymbol, verb: "Tap", action: "AI polish", detail: "Cleans this dictation")) }
        return rows
    }
}
