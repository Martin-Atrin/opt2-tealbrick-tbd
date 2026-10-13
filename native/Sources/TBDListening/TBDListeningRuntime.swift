import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// Native embedding facade for Listening. Retain one instance for the host lifetime.
/// The public shape is the contract with Companion.
@MainActor
public final class TBDListeningRuntime: ObservableObject {
    public static let shared = TBDListeningRuntime()
    public var activate: (() -> Void)?
    @Published public private(set) var voiceNoteRecording = false
    @Published public private(set) var captureBusy = false
    @Published public private(set) var captureMessage = ""
    @Published public private(set) var lastRawTranscript = ""

    private var started = false
    private var context: TBDListeningContext?

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        let context = TBDListeningContext(runtime: self)
        self.context = context
        context.voice.onMessage = { [weak self] in self?.captureMessage = $0 }
        context.voice.onRawTranscript = { [weak self] in self?.lastRawTranscript = $0 }
        context.start()
    }

    public func content() -> AnyView {
        guard let context else { return AnyView(Text("Listening is starting…").foregroundStyle(TBDTokens.muted)) }
        return AnyView(TBDListeningView(context: context).environmentObject(context.env))
    }

    /// Sections: `TBDListeningSettingsSection` raw values ("capture", "engine", "ai", "dictation", "meetings", "system").
    public func settingsContent(section: String) -> AnyView {
        guard let context else { return AnyView(EmptyView()) }
        return AnyView(TBDListeningSettingsView(section: section, context: context).environmentObject(context.env))
    }

    /// Refuses to quit while speech is being captured or saved.
    public func shouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard started, let context else { return .terminateNow }
        if voiceNoteRecording || captureBusy || context.isCapturing {
            let alert = NSAlert()
            alert.messageText = "Speech capture in progress"
            alert.informativeText = "Finish saving your speech capture before quitting."
            alert.addButton(withTitle: "Keep running")
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }

    public var meetingStatus: String { context?.meetings.statusText ?? "Idle" }

    /// Actions: "dictation", "meeting", "transcribeFile", "transcribeURL", "transform", "openLibrary".
    public func menuAction(_ action: TBDListeningAction) {
        guard let context else { captureMessage = "Listening is still initializing"; return }
        context.perform(action)
    }

    public func toggleVoiceNote() async {
        guard !captureBusy else { return }
        guard let context else { captureMessage = "Listening is still initializing"; return }
        captureBusy = true; captureMessage = ""
        defer { captureBusy = false }
        do {
            if context.voice.noteRecording {
                voiceNoteRecording = false
                let status = try await context.voice.finishNote()
                if captureMessage.isEmpty { captureMessage = status }
            } else {
                try await context.voice.startNote()
                voiceNoteRecording = true
            }
        } catch {
            voiceNoteRecording = context.voice.noteRecording
            captureMessage = error.localizedDescription
        }
    }

    /// Chat dictation: "start" → NSNull, "level" → Float, "cancel" → NSNull, "stop" → ["text", "rawText", "warning"].
    public func chatAudio(_ operation: String) async throws -> Any {
        guard let context else { throw TBDVoiceCapture.error(1, "Listening is still initializing") }
        return try await context.voice.chat(operation)
    }

    public func terminate() {
        guard started, let context else { return }
        context.stop()
        started = false
    }

    // MARK: Additions

    /// Hotkey dictation is recording or transcribing.
    public var dictationActive: Bool { context?.dictation.isBusy ?? false }

    // MARK: knowledge

    /// Set by the host: sends a "Save to Knowledge" request to the Chat helper, which calls
    /// Knowledge as TBD's own agent. Nil (no host, not signed in) makes saves fail with a plain message.
    public var saveToKnowledge: TBDKnowledgeSaver?

    func report(_ message: String) { captureMessage = message }
    func bringToFront() { activate?() }
}
