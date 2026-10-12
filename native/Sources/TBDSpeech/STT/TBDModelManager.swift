import Foundation

/// Lists, downloads and deletes Listening models under `TBD/Listening/Models` (one FluidAudio
/// repo folder per model, `whisper/` for WhisperKit). Downloads happen only through
/// `download(_:progress:)`, which the UI and CLI call on an explicit user action.
public struct TBDModelManager: Sendable {
    public enum Model: String, CaseIterable, Sendable, Identifiable, Codable {
        case parakeetV3, parakeetV2, parakeetUnified, nemotronMultilingual, nemotronEnglish, cohere, whisper, diarizer, vad
        public var id: String { rawValue }

        public init(engine: TBDSpeechEngineKind) {
            switch engine {
            case .parakeetV3: self = .parakeetV3
            case .parakeetV2: self = .parakeetV2
            case .parakeetUnified: self = .parakeetUnified
            case .nemotronMultilingual: self = .nemotronMultilingual
            case .nemotronEnglish: self = .nemotronEnglish
            case .cohere: self = .cohere
            case .whisper: self = .whisper
            }
        }

        /// The speech engine this model runs, or nil for support models.
        public var engine: TBDSpeechEngineKind? { TBDSpeechEngineKind(rawValue: rawValue) }

        /// Id for `tbd-listen models`: the engine's CLI id, `speaker-detection` or `vad`.
        public var cliID: String {
            switch self {
            case .diarizer: "speaker-detection"
            case .vad: "vad"
            default: engine!.cliID
            }
        }

        public init?(identifier: String) {
            let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let model = Self.allCases.first(where: { $0.rawValue.lowercased() == value || $0.cliID == value }) {
                self = model
            } else if ["diarization", "speakers", "speaker"].contains(value) {
                self = .diarizer
            } else if ["silero-vad", "voice-activity"].contains(value) {
                self = .vad
            } else if let engine = TBDSpeechEngineKind(identifier: value) {
                self = Model(engine: engine)
            } else {
                return nil
            }
        }

        public var title: String {
            switch self {
            case .diarizer: "Speaker detection"
            case .vad: "Voice activity detection"
            default: engine!.capabilities.displayName
            }
        }

        public var detail: String {
            switch self {
            case .diarizer: return "Labels speakers in meetings and files. About 30 MB."
            case .vad: return "Cuts the meeting live transcript at pauses (Silero VAD). About 2 MB."
            default:
                let capabilities = engine!.capabilities
                return "\(capabilities.summary) \(capabilities.approximateSize)."
            }
        }

        public var approximateBytes: Int64 {
            switch self {
            case .diarizer: 30_000_000
            case .vad: 2_000_000
            default: engine!.capabilities.approximateBytes
            }
        }
    }

    public struct Status: Sendable, Identifiable {
        public let model: Model
        public let downloaded: Bool
        public let bytes: Int64
        public var id: String { model.rawValue }
    }

    public let modelsRoot: URL
    /// Language hint that picks the Nemotron Multilingual variant (latin or full multilingual).
    public let nemotronLanguage: String?

    public init(modelsRoot: URL = TBDListeningPaths.models, nemotronLanguage: String? = nil) {
        self.modelsRoot = modelsRoot
        self.nemotronLanguage = nemotronLanguage
    }

    /// Manager for the stored Nemotron language preference.
    public init(modelsRoot: URL = TBDListeningPaths.models, preferences: TBDListeningPreferences) {
        self.init(modelsRoot: modelsRoot, nemotronLanguage: preferences.nemotronLanguage)
    }

    /// The folder `delete` removes (for Nemotron Multilingual, every language variant).
    public func folder(_ model: Model) -> URL {
        switch model {
        case .parakeetV3: TBDParakeetEngine.directory(for: .parakeetV3, modelsRoot: modelsRoot)
        case .parakeetV2: TBDParakeetEngine.directory(for: .parakeetV2, modelsRoot: modelsRoot)
        case .parakeetUnified: TBDParakeetUnifiedEngine.directory(modelsRoot: modelsRoot)
        case .nemotronMultilingual: TBDNemotronEngine.repoDirectory(modelsRoot: modelsRoot)
        case .nemotronEnglish: TBDNemotronEnglishEngine.directory(modelsRoot: modelsRoot)
        case .cohere: TBDCohereEngine.directory(modelsRoot: modelsRoot)
        case .whisper: TBDWhisperEngine.downloadBase(modelsRoot)
        case .diarizer: TBDDiarizer.directory(modelsRoot: modelsRoot)
        case .vad: TBDSileroVAD.directory(modelsRoot: modelsRoot)
        }
    }

    public func isDownloaded(_ model: Model) -> Bool {
        switch model {
        case .parakeetV3: TBDParakeetEngine.isDownloaded(.parakeetV3, modelsRoot: modelsRoot)
        case .parakeetV2: TBDParakeetEngine.isDownloaded(.parakeetV2, modelsRoot: modelsRoot)
        case .parakeetUnified: TBDParakeetUnifiedEngine.isDownloaded(modelsRoot: modelsRoot)
        case .nemotronMultilingual: TBDNemotronEngine.isDownloaded(language: nemotronLanguage, modelsRoot: modelsRoot)
        case .nemotronEnglish: TBDNemotronEnglishEngine.isDownloaded(modelsRoot: modelsRoot)
        case .cohere: TBDCohereEngine.isDownloaded(modelsRoot: modelsRoot)
        case .whisper: TBDWhisperEngine.modelFolder(modelsRoot: modelsRoot) != nil
        case .diarizer: TBDDiarizer.isDownloaded(modelsRoot: modelsRoot)
        case .vad: TBDSileroVAD.isDownloaded(modelsRoot: modelsRoot)
        }
    }

    public func isDownloaded(engine: TBDSpeechEngineKind) -> Bool { isDownloaded(Model(engine: engine)) }

    public func status(_ model: Model) -> Status {
        Status(model: model, downloaded: isDownloaded(model), bytes: TBDListeningPaths.diskUsage(of: folder(model)))
    }

    public func status() -> [Status] { Model.allCases.map(status) }

    public var totalBytes: Int64 { TBDListeningPaths.diskUsage(of: modelsRoot) }

    public func download(_ model: Model, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        switch model {
        case .parakeetV3: try await TBDParakeetEngine.download(.parakeetV3, modelsRoot: modelsRoot, progress: progress)
        case .parakeetV2: try await TBDParakeetEngine.download(.parakeetV2, modelsRoot: modelsRoot, progress: progress)
        case .parakeetUnified: try await TBDParakeetUnifiedEngine.download(modelsRoot: modelsRoot, progress: progress)
        case .nemotronMultilingual: try await TBDNemotronEngine.download(language: nemotronLanguage, modelsRoot: modelsRoot, progress: progress)
        case .nemotronEnglish: try await TBDNemotronEnglishEngine.download(modelsRoot: modelsRoot, progress: progress)
        case .cohere: try await TBDCohereEngine.download(modelsRoot: modelsRoot, progress: progress)
        case .whisper: try await TBDWhisperEngine.download(modelsRoot: modelsRoot, progress: progress)
        case .diarizer: try await TBDDiarizer.download(modelsRoot: modelsRoot, progress: progress)
        case .vad: try await TBDSileroVAD.download(modelsRoot: modelsRoot, progress: progress)
        }
    }

    /// Removes a model's files. The caller must not delete the engine that is running a job.
    public func delete(_ model: Model) throws {
        let url = folder(model)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        // Drop an empty parent such as `nemotron-streaming/` or `cohere-transcribe/`.
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL != modelsRoot.standardizedFileURL,
           (try? FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0 != ".DS_Store" }.isEmpty) == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}

extension Int64 {
    /// "1.2 GB" style size.
    public var tbdByteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
