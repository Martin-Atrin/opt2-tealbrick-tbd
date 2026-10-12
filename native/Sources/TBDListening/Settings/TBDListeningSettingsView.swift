import AppKit
import SwiftUI
import TBDDesign
import TBDModels
import TBDSpeech

/// Settings for one section: "engine", "ai", "dictation", "meetings" or "system".
struct TBDListeningSettingsView: View {
    let section: String
    let context: TBDListeningContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch section {
            case "engine": TBDEngineSettings(context: context)
            case "ai": TBDAISettings()
            case "dictation": TBDDictationSettings(context: context)
            case "meetings": TBDMeetingSettings(context: context)
            case "system": TBDSystemSettings(context: context)
            default: Text("Unknown section").foregroundStyle(TBDTokens.muted)
            }
        }
        .font(TBDTokens.Typography.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bool binding over a preferences property.
@MainActor
func tbdBinding<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void, refresh: @escaping () -> Void = {}) -> Binding<T> {
    nonisolated(unsafe) let read = get
    nonisolated(unsafe) let write = set
    nonisolated(unsafe) let after = refresh
    return Binding(get: { read() }, set: { write($0); after() })
}

// MARK: - Engine

@MainActor
final class TBDModelsModel: ObservableObject {
    @Published var statuses: [TBDModelManager.Status] = []
    @Published var progress: [TBDModelManager.Model: Double] = [:]
    @Published var error: String?
    let manager = TBDModelManager()

    func refresh() { statuses = manager.status() }

    func download(_ model: TBDModelManager.Model) {
        guard progress[model] == nil else { return }
        progress[model] = 0
        error = nil
        Task {
            do {
                try await manager.download(model) { value in Task { @MainActor in if self.progress[model] != nil { self.progress[model] = value } } }
            } catch { self.error = "\(model.title): \(error.localizedDescription)" }
            progress[model] = nil
            refresh()
        }
    }

    func delete(_ model: TBDModelManager.Model, inUse: Bool) {
        let alert = NSAlert()
        alert.messageText = "Delete \(model.title)?"
        alert.informativeText = inUse ? "This is the selected engine. Listening cannot transcribe until you download it again or choose another engine." : "You can download it again later."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try manager.delete(model) } catch { self.error = error.localizedDescription }
        refresh()
    }
}

struct TBDEngineSettings: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @StateObject private var models = TBDModelsModel()
    @State private var tick = 0

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            TBDSettingsRow("Speech engine", help: "One model stays loaded. Models download only when you click Download.") {
                Picker("", selection: tbdBinding({ prefs.engine }, { prefs.engine = $0 }, refresh: { tick += 1; Task { await env.speech.warmUp() } })) {
                    ForEach(TBDEngineChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: 240)
            }
            if prefs.engine == .whisper {
                TBDSettingsRow("Whisper language", help: "ISO code such as en, de, ko. Leave empty to detect automatically.") {
                    TextField("auto", text: tbdBinding({ prefs.whisperLanguage ?? "" }, { prefs.whisperLanguage = $0.trimmingCharacters(in: .whitespaces).lowercased() }))
                        .tbdField().frame(width: 80)
                }
            }
            TBDSettingsRow("Speaker detection", help: "Label speakers in meetings and files (needs the speaker model).") {
                Toggle("", isOn: tbdBinding({ prefs.diarize }, { prefs.diarize = $0 }, refresh: { tick += 1 })).labelsHidden().toggleStyle(.switch)
            }
            TBDLabel("Models").padding(.top, TBDTokens.Space.xl).padding(.bottom, TBDTokens.Space.xs)
            ForEach(models.statuses) { status in
                TBDSettingsRow(status.model.title, help: status.model.detail) {
                    HStack(spacing: TBDTokens.Space.sm) {
                        if let value = models.progress[status.model] {
                            ProgressView(value: value).frame(width: 120)
                        } else if status.downloaded {
                            Text(status.bytes.tbdByteString).foregroundStyle(TBDTokens.muted)
                            Button("Delete") { models.delete(status.model, inUse: TBDModelManager.Model(engine: prefs.engine) == status.model) }
                                .buttonStyle(TBDButtonStyle(.quiet))
                        } else {
                            Button("Download") { models.download(status.model) }.buttonStyle(TBDButtonStyle(.secondary))
                        }
                    }
                }
            }
            if let error = models.error { Text(error).foregroundStyle(TBDTokens.alert).padding(.top, TBDTokens.Space.sm) }
            Text("Models are stored in \(TBDListeningPaths.models.path) · \(models.manager.totalBytes.tbdByteString) used")
                .font(.system(size: 11)).foregroundStyle(TBDTokens.muted).padding(.top, TBDTokens.Space.md).textSelection(.enabled)
        }
        .id(tick)
        .onAppear { models.refresh() }
    }
}

// MARK: - AI

struct TBDAISettings: View {
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0
    @State private var prompts: [TBDTransformPrompt] = []

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            Text("Listening uses your model routes: “cleanup” for transcript cleanup, “analysis” for summaries and questions, “general” for transforms. Assign them in Settings → Models. Raw transcripts are always kept.")
                .foregroundStyle(TBDTokens.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, TBDTokens.Space.md)
            TBDSettingsRow("Clean up hotkey dictation", help: "Send dictated text to the cleanup model before pasting.") {
                Toggle("", isOn: tbdBinding({ prefs.dictationCleanup }, { prefs.dictationCleanup = $0 }, refresh: { tick += 1 })).labelsHidden().toggleStyle(.switch)
            }
            TBDSettingsRow("Clean up chat dictation") {
                Toggle("", isOn: tbdBinding({ UserDefaults.standard.bool(forKey: TBDCleanupPolicy.chatKey) },
                                            { UserDefaults.standard.set($0, forKey: TBDCleanupPolicy.chatKey) }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(.switch)
            }
            TBDSettingsRow("Clean up voice notes") {
                Toggle("", isOn: tbdBinding({ UserDefaults.standard.bool(forKey: TBDCleanupPolicy.voiceNoteKey) },
                                            { UserDefaults.standard.set($0, forKey: TBDCleanupPolicy.voiceNoteKey) }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(.switch)
            }
            promptEditor("Cleanup prompt", text: tbdBinding({ prefs.cleanupPrompt }, { prefs.cleanupPrompt = $0 }),
                         reset: { prefs.cleanupPrompt = TBDListeningPreferences.defaultCleanupPrompt; tick += 1 })
            promptEditor("Summary prompt", text: tbdBinding({ prefs.summaryPrompt }, { prefs.summaryPrompt = $0 }),
                         reset: { prefs.summaryPrompt = TBDListeningPreferences.defaultSummaryPrompt; tick += 1 })
            HStack {
                TBDLabel("Transform prompts")
                Spacer()
                Button("Add") { prompts.append(TBDTransformPrompt(name: "New prompt", instruction: "Rewrite the text.")); save() }
                    .buttonStyle(TBDButtonStyle(.quiet))
                Button("Reset") { prompts = TBDTransformPrompt.defaults; save() }.buttonStyle(TBDButtonStyle(.quiet))
            }
            .padding(.top, TBDTokens.Space.xl)
            ForEach($prompts) { $prompt in
                HStack(alignment: .top, spacing: TBDTokens.Space.sm) {
                    TextField("Name", text: $prompt.name, onCommit: save).tbdField().frame(width: 160)
                    TextField("Instruction", text: $prompt.instruction, onCommit: save).tbdField()
                    Button { prompts.removeAll { $0.id == prompt.id }; save() } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(TBDButtonStyle(.icon)).disabled(prompts.count <= 1).accessibilityLabel("Remove prompt")
                }
                .padding(.vertical, TBDTokens.Space.xs)
            }
        }
        .id(tick)
        .onAppear { prompts = prefs.transformPrompts }
        .onDisappear(perform: save)
    }

    private func save() { env.preferences.transformPrompts = prompts }

    private func promptEditor(_ title: String, text: Binding<String>, reset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
            HStack { TBDLabel(title); Spacer(); Button("Reset", action: reset).buttonStyle(TBDButtonStyle(.quiet)) }
            TextEditor(text: text).font(TBDTokens.Typography.body).frame(height: 70).scrollContentBackground(.hidden)
                .padding(6).background(TBDTokens.paper)
                .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border))
        }
        .padding(.top, TBDTokens.Space.lg)
    }
}

// MARK: - Meetings

struct TBDMeetingSettings: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            TBDSettingsRow("Meeting reminders", help: "A minute before a calendar meeting, offer to record it. Uses your calendars on this Mac.") {
                Toggle("", isOn: tbdBinding({ prefs.calendarReminders }, { prefs.calendarReminders = $0 },
                                            refresh: { tick += 1; context.meetings.configureCalendar() })).labelsHidden().toggleStyle(.switch)
            }
            TBDSettingsRow("Start recording automatically", help: "Record calendar meetings when they begin. Off by default; tell participants you record.") {
                Toggle("", isOn: tbdBinding({ prefs.calendarAutoStart }, { prefs.calendarAutoStart = $0 },
                                            refresh: { tick += 1; context.meetings.configureCalendar() })).labelsHidden().toggleStyle(.switch)
            }
            TBDSettingsRow("Other participants", help: "Recording system audio needs Screen & System Audio Recording permission for TBD. Without it, only your microphone is recorded.") {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(TBDButtonStyle(.secondary))
            }
        }
        .id(tick)
    }
}

// MARK: - System

struct TBDSystemSettings: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0
    @State private var devices: [TBDAudioDevices.Input] = []
    @State private var usage: [(String, Int64)] = []

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            TBDSettingsRow("Microphone", help: "System Default follows the input chosen in macOS Sound settings.") {
                Picker("", selection: tbdBinding({ prefs.microphoneUID ?? "" }, { uid in
                    prefs.microphoneUID = uid.isEmpty ? nil : uid
                    env.microphone.setPreferredDevice(uid: prefs.microphoneUID)
                }, refresh: { tick += 1 })) {
                    Text("System Default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden().frame(width: 240)
            }
            TBDSettingsRow("Save dictation history", help: "Voice notes are always saved.") {
                Toggle("", isOn: tbdBinding({ prefs.keepHistory }, { prefs.keepHistory = $0 }, refresh: { tick += 1 })).labelsHidden().toggleStyle(.switch)
            }
            TBDRetentionSettingsView(retention: context.retention)
            TBDLabel("Storage").padding(.top, TBDTokens.Space.xl).padding(.bottom, TBDTokens.Space.xs)
            ForEach(usage, id: \.0) { name, bytes in
                HStack { Text(name); Spacer(); Text(bytes.tbdByteString).foregroundStyle(TBDTokens.muted) }.padding(.vertical, 3)
            }
            HStack(spacing: TBDTokens.Space.sm) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([TBDListeningPaths.root]) }
                    .buttonStyle(TBDButtonStyle(.secondary))
                Spacer()
                Button("Delete all Listening data…", role: .destructive) { context.retention.deleteAll(context: context); refreshUsage() }
                    .buttonStyle(TBDButtonStyle(.destructive))
            }
            .padding(.top, TBDTokens.Space.md)
        }
        .id(tick)
        .onAppear {
            devices = TBDAudioDevices.inputs()
            refreshUsage()
        }
    }

    private func refreshUsage() {
        usage = [("Models", TBDListeningPaths.models), ("Meetings", TBDListeningPaths.meetings), ("Dictations", TBDListeningPaths.dictations),
                 ("Voice notes", TBDListeningPaths.voiceNotes), ("Downloads", TBDListeningPaths.downloads), ("Library database", TBDListeningPaths.database)]
            .map { ($0.0, TBDListeningPaths.diskUsage(of: $0.1)) }
    }
}

/// Per-kind retention: keep forever, delete after N days, or drop audio after transcription.
struct TBDRetentionSettingsView: View {
    @ObservedObject var retention: TBDRetentionController
    @EnvironmentObject private var env: TBDListeningEnvironment

    var body: some View {
        let settings = env.preferences.retention
        VStack(alignment: .leading, spacing: 0) {
            TBDLabel("Retention").padding(.top, TBDTokens.Space.xl).padding(.bottom, TBDTokens.Space.xs)
            ForEach(TBDRetentionKind.allCases) { kind in
                let policy = settings[kind]
                TBDSettingsRow(kind.title, help: kind.help) {
                    HStack(spacing: TBDTokens.Space.sm) {
                        Picker("", selection: Binding(get: { policy.mode }, set: { mode in
                            retention.set(TBDRetentionPolicy(mode: mode, days: policy.days), for: kind)
                        })) {
                            ForEach(kind.modes, id: \.self) { Text($0.title(for: kind)).tag($0) }
                        }
                        .labelsHidden().frame(width: 240)
                        if policy.mode == .deleteAfterDays {
                            TBDRetentionDays(days: policy.days) { retention.set(TBDRetentionPolicy(mode: .deleteAfterDays, days: $0), for: kind) }
                        }
                    }
                }
            }
            Text("Only “Delete after” removes existing items; it runs at launch and daily. Your original files are never removed.")
                .font(.system(size: 11)).foregroundStyle(TBDTokens.muted).padding(.top, TBDTokens.Space.xs)
            if let result = retention.lastResult, result.changed {
                Text("Last cleanup removed \(result.deletedDictations + result.deletedTranscriptions) item(s) and audio from \(result.detachedAudio) meeting(s).")
                    .font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
            }
        }
    }
}

/// Day count editor, 1–365, committed on submit or stepper change.
struct TBDRetentionDays: View {
    let days: Int
    let commit: (Int) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: TBDTokens.Space.xs) {
            TextField("30", text: $text).tbdField().frame(width: 48)
                .onSubmit { apply(Int(text) ?? days) }
            Stepper("", value: Binding(get: { days }, set: { apply($0) }), in: TBDRetentionPolicy.dayRange).labelsHidden()
            Text(days == 1 ? "day" : "days").foregroundStyle(TBDTokens.muted)
        }
        .onAppear { text = "\(days)" }
        .onChange(of: days) { _, value in text = "\(value)" }
    }

    private func apply(_ value: Int) {
        let clamped = min(max(value, TBDRetentionPolicy.dayRange.lowerBound), TBDRetentionPolicy.dayRange.upperBound)
        text = "\(clamped)"
        if clamped != days { commit(clamped) }
    }
}
