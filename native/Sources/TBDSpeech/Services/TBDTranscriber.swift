import Foundation

public enum TBDSpeechVersion {
    public static let string = "1.0.0"
}

/// Turns an audio or video file into a stored library item: decode, transcribe, optional speaker
/// detection, vocabulary, segments.
public final class TBDTranscriber: @unchecked Sendable {
    public typealias Progress = @Sendable (_ stage: String, _ fraction: Double) -> Void

    public let speech: TBDSpeechService
    public let database: TBDListeningDatabase
    /// Read at each run, so a change on the Vocabulary page applies to the next file.
    private let processing: @Sendable () -> TBDProcessingSettings

    public init(speech: TBDSpeechService = .shared, database: TBDListeningDatabase,
                processing: @escaping @Sendable () -> TBDProcessingSettings = { TBDListeningPreferences().processingSettings }) {
        self.speech = speech
        self.database = database
        self.processing = processing
    }

    /// Transcribes `file` and saves the result. The record exists (status `processing`) from the start,
    /// so the library shows progress; failures and cancellation are recorded on it.
    @discardableResult
    public func transcribe(file: URL, kind: TBDSourceKind = .file, title: String? = nil, sourceURL: String? = nil,
                           keepAudio: Bool = false, progress: Progress? = nil) async throws -> TBDTranscription {
        var item = TBDTranscription(title: title ?? file.deletingPathExtension().lastPathComponent, sourceKind: kind,
                                    sourcePath: kind == .file ? file.path : nil, sourceURL: sourceURL)
        try database.save(item)
        let wav = try TBDListeningPaths.ensure(TBDListeningPaths.temporary).appendingPathComponent(item.id + ".wav")
        defer { if !keepAudio { try? FileManager.default.removeItem(at: wav) } }
        do {
            progress?("Decoding", 0)
            item.durationMs = try await TBDAudioDecoder.decodeToWAV(file, destination: wav) { progress?("Decoding", $0 * 0.15) }
            progress?("Transcribing", 0.15)
            let transcript = try await speech.transcribe(url: wav, kind: .file) { progress?("Transcribing", 0.15 + $0 * 0.7) }
            var words = transcript.words
            if let turns = try? await speech.speakerTurns(wav, kind: .file), !turns.isEmpty {
                progress?("Detecting speakers", 0.9)
                words = TBDTranscriptAssembler.attribute(words, turns: turns)
            }
            try apply(transcript, words: words, to: &item)
            if keepAudio {
                let kept = try TBDListeningPaths.ensure(TBDListeningPaths.downloads).appendingPathComponent(item.id + ".wav")
                try? FileManager.default.moveItem(at: wav, to: kept)
                item.audioPaths = [kept.path]
            }
            item.status = .completed
            try database.save(item)
            progress?("Done", 1)
            return item
        } catch {
            item.status = error is CancellationError ? .cancelled : .failed
            item.errorMessage = error is CancellationError ? "Cancelled" : error.localizedDescription
            try? database.save(item)
            throw error
        }
    }

    /// Fills text, words, speakers and segments from an engine result, applying custom vocabulary.
    func apply(_ transcript: TBDTranscript, words: [TBDWord], to item: inout TBDTranscription) throws {
        let settings = processing()
        let vocabulary = settings.appliesVocabulary(to: item.sourceKind) ? ((try? database.customWords()) ?? []) : []
        item.rawText = transcript.trimmedText
        if settings.appliesCleanPipeline(to: item.sourceKind) {
            // v1 ran the full Clean pipeline on files and links.
            let snippets = ((try? database.snippets()) ?? [])
            let cleaned = TBDTextPipeline().process(item.rawText, customWords: vocabulary, snippets: snippets,
                                                    removeFillers: settings.removeFillers, mode: .clean,
                                                    spokenPunctuation: settings.spokenPunctuation)
            try? database.incrementSnippetUse(ids: cleaned.expandedSnippetIDs)
            item.cleanText = cleaned.text == item.rawText ? nil : cleaned.text
        } else {
            let corrected = TBDTextPipeline.applyCustomWords(item.rawText, words: vocabulary)
            item.cleanText = corrected == item.rawText ? nil : corrected
        }
        item.words = vocabulary.isEmpty ? words : words.map { word in
            var fixed = word
            fixed.text = TBDTextPipeline.applyCustomWords(word.text, words: vocabulary)
            return fixed
        }
        item.language = transcript.language
        item.engine = transcript.engine
        if item.durationMs == 0 { item.durationMs = transcript.durationMs }
        item.speakers = TBDTranscriptAssembler.speakers(in: item.words, fixed: item.speakers)
        item.segments = TBDTranscriptAssembler.segments(words: item.words, fallbackText: item.text, durationMs: item.durationMs)
    }
}
