import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

// Settings rows for the v1 dictation behaviour options and the transcript auto-save / notification options.
// Order and wording follow v1 Settings > Capture. Each view re-reads preferences after a change.

/// "Show dictation pill at all times", pill position and preview text size (v1 order).
struct TBDDictationPillSettings: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0

    var body: some View {
        let prefs = env.preferences
        let changed = { tick += 1; context.dictation.settingsChanged() }
        VStack(alignment: .leading, spacing: 0) {
            TBDSettingsRow("Show dictation pill at all times", help: "When off, the pill hides until you use a dictation shortcut.") {
                Toggle("", isOn: tbdBinding({ prefs.showIdlePill }, { prefs.showIdlePill = $0 }, refresh: changed)).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDSettingsRow("Pill position", help: "Screen edge for the dictation pill and live preview.") {
                TBDSegmented(selection: tbdBinding({ prefs.dictationOverlayPlacement }, { prefs.dictationOverlayPlacement = $0 }, refresh: changed),
                             options: TBDOverlayPlacement.allCases.map { ($0, $0.title) })
            }
            if prefs.dictationLivePreview {
                TBDSettingsRow("Preview text size", help: "Text size for the live transcript preview.") {
                    TBDSegmented(selection: tbdBinding({ prefs.dictationPreviewTextSize }, { prefs.dictationPreviewTextSize = $0 }, refresh: changed),
                                 options: TBDPreviewTextSize.allCases.map { ($0, $0.title) })
                }
            }
        }
        .id(tick)
    }
}

/// Escape, preserve discarded, silence stop, instant dictation, media, sounds, clipboard, streaming cursor (v1 order, after Undo window).
struct TBDDictationBehaviorSettings: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0

    var body: some View {
        let prefs = env.preferences
        let changed = { tick += 1; context.dictation.settingsChanged() }
        VStack(alignment: .leading, spacing: 0) {
            toggle("Escape cancels dictation", "Press Escape to cancel a live dictation. Turn off if other apps need Escape while you dictate. On by default.",
                   { prefs.escapeCancelsDictation }, { prefs.escapeCancelsDictation = $0 }, changed)
            toggle("Preserve discarded dictations", "When you cancel or the undo window expires, keep the transcript in History instead of deleting it. Audio follows the audio retention setting. Off by default. Requires Save dictation history. Nothing is pasted.",
                   { prefs.preserveDiscardedDictations }, { prefs.preserveDiscardedDictations = $0 }, changed)
            toggle("Auto-stop after silence", "Stops recording when speech pauses for the selected delay.",
                   { prefs.silenceAutoStop }, { prefs.silenceAutoStop = $0 }, changed)
            if prefs.silenceAutoStop {
                TBDSettingsRow("Silence delay", help: "How long silence must persist before dictation stops.") {
                    TBDSelect(selection: tbdBinding({ prefs.silenceDelay }, { prefs.silenceDelay = $0 }, refresh: changed),
                              options: TBDSilenceAutoStop.delays.map { ($0, Self.delayTitle($0)) })
                        .frame(width: 140)
                }
            }
            toggle("Instant dictation", "Keeps the mic ready so dictation starts faster and catches your first words; macOS shows the mic indicator while it's on. Pauses for Bluetooth mics like AirPods to protect playback quality.",
                   { prefs.instantDictationEnabled }, { prefs.instantDictationEnabled = $0 }, changed)
            toggle("Pause media while dictating", "Pauses playing media during dictation and resumes it when capture stops. On speakers, a moment of media sound can reach the mic before the pause lands. Speak as you press, or use headphones.",
                   { prefs.pauseMediaDuringDictation }, { prefs.pauseMediaDuringDictation = $0 }, changed)
            toggle("Play sounds when dictation starts and stops", "A short cue when the mic is live and another when it closes. Off by default. Follows the macOS sound effects setting. On speakers, the cues can reach the mic. Use headphones to keep them out of saved audio.",
                   { prefs.playDictationCaptureSounds }, { on in
                       prefs.playDictationCaptureSounds = on
                       if on { TBDSounds.shared.play(.recordStart) }
                   }, changed)
            toggle("Keep dictation on clipboard", "Leaves the same text TBD pastes on the clipboard, useful when remote desktops need a manual ⌘V.",
                   { prefs.keepDictationOnClipboard }, { prefs.keepDictationOnClipboard = $0 }, changed)
            toggle("Streaming cursor", "Types the finished transcript into the app with a fast caret. Off keeps instant paste. Reduce Motion always pastes. ⌘Z may undo in pieces. Multi-line results still paste.",
                   { prefs.dictationStreamingCursorEnabled }, { prefs.dictationStreamingCursorEnabled = $0 }, changed)
        }
        .id(tick)
    }

    static func delayTitle(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds)) sec" : "\(seconds) sec"
    }

    private func toggle(_ title: String, _ help: String, _ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void, _ refresh: @escaping () -> Void) -> some View {
        TBDSettingsRow(title, help: help) {
            Toggle("", isOn: tbdBinding(get, set, refresh: refresh)).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
        }
    }
}

/// Insertion style and Voice Return (v1 put these on the Vocabulary page).
struct TBDDictationTextSettings: View {
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0
    @State private var newTrigger = ""
    @State private var triggerError: String?

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            TBDSettingsRow("Insertion style", help: prefs.dictationInsertionStyle.detail) {
                HStack(spacing: TBDTokens.Space.sm) {
                    Text(prefs.dictationInsertionStyle.previewText).font(TBDFonts.mono(12)).foregroundStyle(TBDColor.muted)
                    TBDSegmented(selection: tbdBinding({ prefs.dictationInsertionStyle }, { prefs.dictationInsertionStyle = $0 }, refresh: { tick += 1 }),
                                 options: TBDInsertionStyle.allCases.map { ($0, $0.title) })
                }
            }
            TBDSettingsRow("Voice Return", help: "Submit commands, send messages, or confirm prompts, hands-free. Say a trigger phrase at the end of a dictation to press Return. A phrase in the middle is pasted as text.") {
                Toggle("", isOn: tbdBinding({ prefs.voiceReturnEnabled }, { prefs.voiceReturnEnabled = $0 }, refresh: { tick += 1 })).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            if prefs.voiceReturnEnabled {
                TBDLabel("Trigger phrases").padding(.top, TBDTokens.Space.sm)
                ForEach(Array(prefs.voiceReturnTriggers.enumerated()), id: \.element) { index, phrase in
                    HStack {
                        Text(phrase)
                        Spacer()
                        Button { remove(at: index) } label: { Image(systemName: "trash") }
                            .buttonStyle(TBDButtonStyle(.icon)).disabled(prefs.voiceReturnTriggers.count <= 1)
                            .accessibilityLabel("Delete \(phrase)")
                    }
                }
                HStack(spacing: TBDTokens.Space.sm) {
                    TextField("Add a phrase, e.g. press return", text: $newTrigger).tbdField().onSubmit(add)
                    Button("Add", action: add).buttonStyle(TBDButtonStyle(.secondary))
                }
                .padding(.top, TBDTokens.Space.xs)
                if let triggerError { Text(triggerError).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk) }
            }
        }
        .id(tick)
    }

    private func add() {
        let prefs = env.preferences
        guard let phrase = TBDVoiceReturn.normalized([newTrigger]).first else { triggerError = "Enter a trigger phrase."; return }
        guard !prefs.voiceReturnTriggers.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) else {
            triggerError = "That trigger phrase is already in the list."; return
        }
        prefs.voiceReturnTriggers = prefs.voiceReturnTriggers + [phrase]
        newTrigger = ""; triggerError = nil; tick += 1
    }

    private func remove(at index: Int) {
        let prefs = env.preferences
        var phrases = prefs.voiceReturnTriggers
        guard phrases.indices.contains(index), phrases.count > 1 else { triggerError = "Voice Return needs at least one trigger phrase."; return }
        phrases.remove(at: index)
        prefs.voiceReturnTriggers = phrases
        triggerError = nil; tick += 1
    }
}

/// The auto-save switch and options for one scope (v1 "Auto-save transcripts to disk" / "Also save meetings to a folder").
struct TBDAutoSaveSettings: View {
    let scope: TBDAutoSaveScope
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0

    var body: some View {
        let config = env.preferences.autoSave(scope)
        VStack(alignment: .leading, spacing: 0) {
            TBDSettingsRow(scope == .transcription ? "Auto-save transcripts to disk" : "Also save meetings to a folder",
                           help: scope == .transcription ? "Automatically write a file to the chosen folder after every transcription completes."
                           : "TBD keeps the complete meeting in its own storage. Turn this on to also save the selected format to a folder you choose.") {
                Toggle("", isOn: tbdBinding({ config.enabled }, { on in
                    config.enabled = on
                    if on { config.ensureFolderConfigured() }
                }, refresh: { tick += 1 })).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            if config.enabled { options(config) }
        }
        .id(tick)
    }

    @ViewBuilder
    private func options(_ config: TBDAutoSaveConfig) -> some View {
        TBDSettingsRow("Format", help: "File format for saved \(scope.noun)s.") {
            TBDSelect(selection: tbdBinding({ config.format }, { config.format = $0 }, refresh: { tick += 1 }),
                      options: TBDAutoSaveConfig.formats.map { ($0, $0.title + " (." + $0.fileExtension + ")") })
                .frame(width: 220)
        }
        let folder = config.resolvedFolder()
        TBDSettingsRow("Folder", help: folder?.path ?? (config.hasFolder ? "This folder is unavailable. Choose another folder before the next \(scope.noun)." : "No folder selected")) {
            HStack(spacing: TBDTokens.Space.sm) {
                Button("Reset") { config.resetFolderToDefault(); tick += 1 }.buttonStyle(TBDButtonStyle(.secondary))
                    .help("Reset to the default folder (\(TBDAutoSaveConfig.defaultFolder(for: scope).path))")
                Button("Choose…") { chooseFolder(config) }.buttonStyle(TBDButtonStyle(.secondary))
            }
        }
        if scope == .meeting, config.format == .txt || config.format == .md {
            let options = config.options
            if config.format == .md {
                option("Include timestamps", "Add a timestamp at the start of each paragraph.", options.includeTimestamps) { var o = config.options; o.includeTimestamps = $0; config.options = o }
            }
            option("Include speaker labels", "Show speaker names when speaker information is available.", options.includeSpeakerLabels) { var o = config.options; o.includeSpeakerLabels = $0; config.options = o }
            if config.format == .md {
                option("Include meeting details", "Add the source, date and duration.", options.includeMetadata) { var o = config.options; o.includeMetadata = $0; config.options = o }
            }
        }
    }

    private func option(_ title: String, _ help: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        TBDSettingsRow(title, help: help) {
            Toggle("", isOn: tbdBinding({ value }, set, refresh: { tick += 1 })).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
        }
    }

    private func chooseFolder(_ config: TBDAutoSaveConfig) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select a folder for auto-saved \(scope.noun)s"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.setFolder(url)
        tick += 1
    }
}

/// v1 "Transcription" workflow: completion notice and auto-save.
struct TBDTranscriptionSettings: View {
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            TBDSettingsRow("Notify when transcription finishes", help: "Play a sound when a file, link or batch transcription completes, plus a notification banner when TBD is in the background.") {
                Toggle("", isOn: tbdBinding({ prefs.notifyOnTranscriptionComplete }, { prefs.notifyOnTranscriptionComplete = $0 }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDAutoSaveSettings(scope: .transcription)
        }
        .id(tick)
    }
}
