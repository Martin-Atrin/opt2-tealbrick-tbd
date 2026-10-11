import AppKit
import TBDModels
import TBDSpeech

/// Voice notes and chat dictation for the Companion host. Behaviour matches the previous facade:
/// voice notes keep their audio in `VoiceNotes` (when audio retention is on) and land in dictation
/// history; failed chat audio is kept there for recovery.
@MainActor
final class TBDVoiceCapture {
    private let env: TBDListeningEnvironment
    private var noteRecorder: TBDAudioRecorder?
    private var noteStartedAt = Date()
    private var chatRecorder: TBDAudioRecorder?
    private(set) var chatStarting = false
    private(set) var chatProcessing = false
    private var chatCancelled = false
    var onMessage: ((String) -> Void)?
    var onRawTranscript: ((String) -> Void)?

    init(env: TBDListeningEnvironment) { self.env = env }

    var noteRecording: Bool { noteRecorder != nil }
    var chatActive: Bool { chatRecorder != nil || chatStarting || chatProcessing }

    static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "TBD.Listening", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Voice notes

    func startNote() async throws {
        let recorder = TBDAudioRecorder(microphone: env.microphone)
        try await recorder.start()
        noteStartedAt = Date()
        noteRecorder = recorder
    }

    /// Stops the note, transcribes it and saves it. Returns the user-facing status.
    func finishNote() async throws -> String {
        guard let recorder = noteRecorder else { return "" }
        noteRecorder = nil
        let recording = try await recorder.stop()
        let url = try env.keep(recording.url, in: TBDListeningPaths.voiceNotes, name: tbdNewID() + ".wav")
        let output = try await transcribe(url, voiceNote: true, durationMs: recording.durationMs)
        if !env.preferences.keepAudio { try? FileManager.default.removeItem(at: url) }
        return output["warning"].flatMap { $0.isEmpty ? nil : $0 } ?? "Voice note saved in dictation history"
    }

    // MARK: Chat dictation

    func chat(_ operation: String) async throws -> Any {
        switch operation {
        case "start":
            guard chatRecorder == nil, !chatStarting, !chatProcessing else { throw Self.error(2, "Dictation is already active") }
            chatStarting = true; chatCancelled = false
            defer { chatStarting = false }
            guard await TBDSharedMicrophone.requestPermission() else { throw Self.error(3, "Microphone permission denied") }
            let recorder = TBDAudioRecorder(microphone: env.microphone)
            try await recorder.start()
            if chatCancelled { await recorder.cancel(); throw CancellationError() }
            chatRecorder = recorder
            return NSNull()
        case "level":
            return chatRecorder?.audioLevel ?? Float(0)
        case "cancel":
            chatCancelled = true
            if let recorder = chatRecorder { chatRecorder = nil; await recorder.cancel() }
            return NSNull()
        case "stop":
            // Stop while start is still running: cancel the start so the microphone is not orphaned.
            if chatStarting { chatCancelled = true }
            guard let recorder = chatRecorder else { return ["text": ""] }
            chatRecorder = nil; chatProcessing = true
            defer { chatProcessing = false }
            let recording = try await recorder.stop()
            do {
                let output = try await transcribe(recording.url, voiceNote: false, durationMs: recording.durationMs)
                try? FileManager.default.removeItem(at: recording.url)
                return output
            } catch {
                _ = try? env.keep(recording.url, in: TBDListeningPaths.voiceNotes, name: "chat-recovery-\(tbdNewID()).wav")
                onMessage?("Transcription failed. Captured audio retained for recovery.")
                throw error
            }
        default:
            throw Self.error(4, "Unknown audio operation")
        }
    }

    // MARK: Shared

    private func transcribe(_ url: URL, voiceNote: Bool, durationMs: Int) async throws -> [String: String] {
        let samples = try TBDAudioDecoder.samples(from: url)
        let transcript = try await env.speech.transcribe(samples: samples, kind: .dictation)
        let raw = transcript.trimmedText
        onRawTranscript?(raw)
        let cleaned = try await TBDCleanup.apply(raw: raw, enabled: TBDCleanupPolicy.enabled(voiceNote: voiceNote),
                                                 formatter: TBDCleanup.modelFormatter(prompt: env.preferences.cleanupPrompt))
        if !cleaned.warning.isEmpty { onMessage?(cleaned.warning) }
        let keepAudio = env.preferences.keepAudio
        if voiceNote || env.preferences.keepHistory {
            try env.database?.save(TBDDictation(durationMs: durationMs, rawText: raw, cleanText: cleaned.text == raw ? nil : cleaned.text,
                                                targetApp: voiceNote ? "TBD Voice note" : "TBD Chat",
                                                audioPath: voiceNote && keepAudio ? url.path : nil, engine: transcript.engine))
        }
        if voiceNote, let database = env.database, !raw.isEmpty {
            // Voice notes also appear in the library with timestamps, ready for summaries.
            var item = TBDTranscription(title: "Voice note " + Date().formatted(date: .abbreviated, time: .shortened),
                                        sourceKind: .voiceNote, status: .completed)
            item.durationMs = durationMs
            item.rawText = raw
            item.cleanText = cleaned.text == raw ? nil : cleaned.text
            item.words = transcript.words
            item.engine = transcript.engine
            item.segments = TBDTranscriptAssembler.segments(words: transcript.words, fallbackText: raw, durationMs: durationMs)
            item.audioPaths = keepAudio ? [url.path] : []
            try? database.save(item)
        }
        env.changed()
        return ["text": cleaned.text, "rawText": raw, "warning": cleaned.warning]
    }
}
