import SwiftUI
import TBDDesign
import TBDSpeech

/// First-run practice: prove the dictation key works, then dictate into a box. Shown once, from the
/// Listening tab, while no dictation exists yet.
struct TBDPracticeDictation: View {
    let context: TBDListeningContext
    @ObservedObject private var dictation: TBDDictationController
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var phase: Phase = .hotkey
    @State private var keyWorked = false
    @State private var text = ""
    @State private var lastSeenID: String?
    @FocusState private var boxFocused: Bool

    enum Phase { case hotkey, dictation }

    init(context: TBDListeningContext) {
        self.context = context
        dictation = context.dictation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            HStack {
                TBDLabel("Try it")
                Spacer()
                Button(hasResult ? "Done" : "Skip for now") { finish() }.buttonStyle(TBDButtonStyle(.quiet))
            }
            switch phase {
            case .hotkey: hotkeyStep
            case .dictation: dictationStep
            }
        }
        .tbdCard(padding: TBDTokens.Space.lg)
        .onChange(of: dictation.isRecording) { _, recording in if recording { keyWorked = true } }
        .onChange(of: env.revision) { _, _ in deliverIfMissing() }
        .onAppear { lastSeenID = (try? env.database?.dictations(limit: 1))?.first?.id }
        .animation(TBDMotion.quick, value: phase)
    }

    private var hasResult: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var key: String { env.preferences.pushToTalkHotkeyLabel }

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            Text("Press your dictation key").font(TBDTokens.Typography.title).foregroundStyle(TBDTokens.ink)
            HStack(spacing: TBDTokens.Space.md) {
                Text(key).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(keyWorked ? TBDTokens.accent.opacity(0.25) : TBDTokens.paper, in: RoundedRectangle(cornerRadius: TBDTokens.Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.sm).strokeBorder(keyWorked ? TBDTokens.accent : TBDTokens.border))
                if context.hotkeyPermissionMissing {
                    TBDChip("Needs hotkey access", color: TBDTokens.alert)
                    Button("Allow…") { TBDPasteService.requestTrust(); TBDPasteService.openAccessibilitySettings() }
                        .buttonStyle(TBDButtonStyle(.secondary))
                } else {
                    TBDChip(keyWorked ? "Your key works" : "Waiting for a press", color: keyWorked ? TBDTokens.accent : TBDTokens.muted)
                }
            }
            Text("Change the key in Settings → Listening → Dictation.").font(.system(size: 12)).foregroundStyle(TBDTokens.muted)
            Button("Continue") { phase = .dictation; boxFocused = true }
                .buttonStyle(TBDButtonStyle(.primary)).disabled(!keyWorked)
        }
    }

    private var dictationStep: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            Text("Dictate into this box").font(TBDTokens.Typography.title).foregroundStyle(TBDTokens.ink)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text).focused($boxFocused).font(TBDTokens.Typography.body)
                    .scrollContentBackground(.hidden).padding(TBDTokens.Space.xs).frame(height: 90)
                if text.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dictation.isRecording ? "Listening" : dictation.isProcessing ? "Transcribing" : "Hold \(key) and say something. Let go when you're done.")
                        Text("Or tap \(key) to talk hands-free, then tap it again to finish.").font(.system(size: 11))
                        Text("Try: “This is my first dictation, and it stays on my Mac.”").font(.system(size: 11))
                    }
                    .foregroundStyle(TBDTokens.muted).padding(TBDTokens.Space.sm).allowsHitTesting(false)
                }
            }
            .background(TBDTokens.paper, in: RoundedRectangle(cornerRadius: TBDTokens.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.sm).strokeBorder(boxFocused ? TBDTokens.accent : TBDTokens.border))
            .onTapGesture { boxFocused = true }
            if hasResult {
                HStack {
                    Text("Those words came from your voice, on this Mac.").font(TBDTokens.Typography.control).foregroundStyle(TBDTokens.accent)
                    Spacer()
                    Button("Try again") { text = ""; boxFocused = true }.buttonStyle(TBDButtonStyle(.quiet))
                }
            } else {
                Text("Your words land wherever the cursor is. Here, that's this box.").font(.system(size: 12)).foregroundStyle(TBDTokens.muted)
            }
        }
    }

    /// When the paste did not reach the box (focus elsewhere), add the newest dictation after a short grace.
    private func deliverIfMissing() {
        guard phase == .dictation, let latest = (try? env.database?.dictations(limit: 1))?.first, latest.id != lastSeenID else { return }
        lastSeenID = latest.id
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !text.contains(latest.text) { text = text.isEmpty ? latest.text : text + " " + latest.text }
        }
    }

    private func finish() {
        env.preferences.practiceCompleted = true
        env.changed()
    }
}
