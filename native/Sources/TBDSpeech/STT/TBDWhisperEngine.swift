import Foundation
import WhisperKit

/// Whisper Large v3 Turbo through WhisperKit. Calls are serialised: WhisperKit is not reentrant.
public final class TBDWhisperEngine: TBDSpeechEngine, @unchecked Sendable {
    public static let variant = "large-v3-v20240930_turbo_632MB"
    public let kind = TBDSpeechEngineKind.whisper
    private let base: URL
    private let language: String?
    private let gate = TBDAsyncLock()
    private var whisper: WhisperKit?

    public init(language: String?, modelsRoot: URL = TBDListeningPaths.models) {
        self.language = language
        base = modelsRoot.appendingPathComponent("whisper", isDirectory: true)
    }

    static func downloadBase(_ modelsRoot: URL) -> URL { modelsRoot.appendingPathComponent("whisper", isDirectory: true) }

    /// Folder of the downloaded variant, if present.
    static func modelFolder(modelsRoot: URL = TBDListeningPaths.models) -> URL? {
        let root = downloadBase(modelsRoot)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in walker where url.lastPathComponent.caseInsensitiveCompare(variant) == .orderedSame {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlmodelc").path) { return url }
        }
        return nil
    }

    static func download(modelsRoot: URL = TBDListeningPaths.models, progress: (@Sendable (Double) -> Void)?) async throws {
        try TBDListeningPaths.ensure(downloadBase(modelsRoot))
        _ = try await WhisperKit.download(variant: variant, downloadBase: downloadBase(modelsRoot),
                                          progressCallback: { progress?($0.fractionCompleted) })
    }

    public func prepare() async throws {
        try await gate.withLock { try await prepareLocked() }
    }

    private func prepareLocked() async throws {
        if whisper != nil { return }
        guard let folder = Self.modelFolder(modelsRoot: base.deletingLastPathComponent()) else {
            throw TBDSpeechError.modelNotDownloaded("Whisper Large v3 Turbo")
        }
        whisper = try await WhisperKit(WhisperKitConfig(model: Self.variant, downloadBase: base, modelFolder: folder.path,
                                                        verbose: false, load: true, download: false))
    }

    private func options(_ language: String?) -> DecodingOptions {
        DecodingOptions(language: language, usePrefillPrompt: language != nil, detectLanguage: language == nil, wordTimestamps: true)
    }

    public func transcribe(url: URL, lane: TBDLane, progress: (@Sendable (Double) -> Void)?) async throws -> TBDTranscript {
        try await run { kit, options in
            let results: [TranscriptionResult] = try await TBDInferenceGate.run {
                try await kit.transcribe(audioPath: url.path, decodeOptions: options, callback: { _ in progress?(0.5); return true })
            }
            return results
        }
    }

    public func transcribe(samples: [Float], lane: TBDLane) async throws -> TBDTranscript {
        guard !samples.isEmpty else { return TBDTranscript(text: "", engine: kind.rawValue) }
        var transcript = try await run { kit, options in
            let results: [TranscriptionResult] = try await TBDInferenceGate.run {
                try await kit.transcribe(audioArray: samples, decodeOptions: options)
            }
            return results
        }
        transcript.durationMs = samples.count / 16
        return transcript
    }

    private func run(_ body: (WhisperKit, DecodingOptions) async throws -> [TranscriptionResult]) async throws -> TBDTranscript {
        try await gate.withLock {
            try await prepareLocked()
            guard let whisper else { throw TBDSpeechError.engineFailed("Whisper is not loaded") }
            var merged = TranscriptionUtilities.mergeTranscriptionResults(try await body(whisper, options(language)))
            // A forced language that yields nothing is retried with detection.
            if language != nil, merged.text.trimmingCharacters(in: .whitespaces).isEmpty {
                merged = TranscriptionUtilities.mergeTranscriptionResults(try await body(whisper, options(nil)))
            }
            let words = merged.allWords.map {
                TBDWord(text: $0.word.trimmingCharacters(in: .whitespaces), start: Int(max(0, $0.start) * 1000),
                        end: Int(max(0, $0.end) * 1000), confidence: Double($0.probability))
            }.filter { !$0.text.isEmpty }
            return TBDTranscript(text: Self.clean(merged.text), words: words, language: merged.language,
                                 engine: kind.rawValue, durationMs: words.last?.end ?? 0)
        }
    }

    /// Strips Whisper special tokens such as `<|startoftranscript|>` that can leak into text.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func unload() async {
        do { try await gate.acquire() } catch { return }
        defer { gate.release() }
        await whisper?.unloadModels()
        whisper = nil
    }
}
