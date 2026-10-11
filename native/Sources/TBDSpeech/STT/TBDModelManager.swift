import Foundation

/// Lists, downloads and deletes Listening models under `TBD/Listening/Models`.
/// Downloads happen only through `download(_:progress:)`, which the UI calls on user action.
public struct TBDModelManager: Sendable {
    public enum Model: String, CaseIterable, Sendable, Identifiable {
        case parakeetV3, parakeetV2, whisper, diarizer
        public var id: String { rawValue }

        public init(engine: TBDEngineChoice) {
            switch engine {
            case .parakeetV3: self = .parakeetV3
            case .parakeetV2: self = .parakeetV2
            case .whisper: self = .whisper
            }
        }

        public var title: String {
            switch self {
            case .parakeetV3: "Parakeet v3"
            case .parakeetV2: "Parakeet v2"
            case .whisper: "Whisper Large v3 Turbo"
            case .diarizer: "Speaker detection"
            }
        }

        public var detail: String {
            switch self {
            case .parakeetV3: "Default. 25 European languages, word timestamps. About 470 MB."
            case .parakeetV2: "English only, slightly more accurate for English. About 470 MB."
            case .whisper: "99 languages, slower. About 630 MB."
            case .diarizer: "Labels speakers in meetings and files. About 30 MB."
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
    public init(modelsRoot: URL = TBDListeningPaths.models) { self.modelsRoot = modelsRoot }

    public func folder(_ model: Model) -> URL {
        switch model {
        case .parakeetV3: TBDParakeetEngine.directory(for: .parakeetV3, modelsRoot: modelsRoot)
        case .parakeetV2: TBDParakeetEngine.directory(for: .parakeetV2, modelsRoot: modelsRoot)
        case .whisper: TBDWhisperEngine.downloadBase(modelsRoot)
        case .diarizer: TBDDiarizer.directory(modelsRoot: modelsRoot)
        }
    }

    public func isDownloaded(_ model: Model) -> Bool {
        switch model {
        case .parakeetV3: TBDParakeetEngine.isDownloaded(.parakeetV3, modelsRoot: modelsRoot)
        case .parakeetV2: TBDParakeetEngine.isDownloaded(.parakeetV2, modelsRoot: modelsRoot)
        case .whisper: TBDWhisperEngine.modelFolder(modelsRoot: modelsRoot) != nil
        case .diarizer: TBDDiarizer.isDownloaded(modelsRoot: modelsRoot)
        }
    }

    public func status() -> [Status] {
        Model.allCases.map { Status(model: $0, downloaded: isDownloaded($0), bytes: TBDListeningPaths.diskUsage(of: folder($0))) }
    }

    public var totalBytes: Int64 { TBDListeningPaths.diskUsage(of: modelsRoot) }

    public func download(_ model: Model, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        switch model {
        case .parakeetV3: try await TBDParakeetEngine.download(.parakeetV3, modelsRoot: modelsRoot, progress: progress)
        case .parakeetV2: try await TBDParakeetEngine.download(.parakeetV2, modelsRoot: modelsRoot, progress: progress)
        case .whisper: try await TBDWhisperEngine.download(modelsRoot: modelsRoot, progress: progress)
        case .diarizer: try await TBDDiarizer.download(modelsRoot: modelsRoot, progress: progress)
        }
    }

    /// Removes a model's files. The caller must not delete the engine that is running a job.
    public func delete(_ model: Model) throws {
        let url = folder(model)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

extension Int64 {
    /// "1.2 GB" style size.
    public var tbdByteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
