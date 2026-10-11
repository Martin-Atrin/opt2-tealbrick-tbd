import FluidAudio
import Foundation

public struct TBDSpeakerTurn: Sendable, Equatable {
    public let speaker: String
    public let start: Int
    public let end: Int
}

/// Offline speaker diarization (FluidAudio pyannote-style pipeline on CoreML).
public actor TBDDiarizer {
    private let modelsRoot: URL
    private var models: OfflineDiarizerModels?

    public init(modelsRoot: URL = TBDListeningPaths.models) { self.modelsRoot = modelsRoot }

    static func directory(modelsRoot: URL) -> URL {
        modelsRoot.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    public static func isDownloaded(modelsRoot: URL = TBDListeningPaths.models) -> Bool {
        let folder = directory(modelsRoot: modelsRoot)
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Downloads the diarization models. Only called from an explicit user action.
    static func download(modelsRoot: URL = TBDListeningPaths.models, progress: (@Sendable (Double) -> Void)?) async throws {
        try TBDListeningPaths.ensure(modelsRoot)
        _ = try await OfflineDiarizerModels.load(from: modelsRoot, progressHandler: progress.map { report in { @Sendable value in report(value.fractionCompleted) } })
    }

    /// Speaker turns for `url`, labelled S1, S2… in order of first speech.
    public func diarize(_ url: URL) async throws -> [TBDSpeakerTurn] {
        if models == nil {
            guard Self.isDownloaded(modelsRoot: modelsRoot) else { throw TBDSpeechError.modelNotDownloaded("Speaker detection") }
            models = try await OfflineDiarizerModels.load(from: modelsRoot)
        }
        guard let models else { return [] }
        var config = OfflineDiarizerConfig.default
        config.segmentation.stepRatio = 0.1
        config.embedding.minSegmentDurationSeconds = 0
        config.zeroVoteReembed = OfflineDiarizerConfig.ZeroVoteReembed(enabled: true)
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let result: DiarizationResult
        do {
            result = try await TBDInferenceGate.run { try await manager.process(url) }
        } catch let error as OfflineDiarizationError {
            if case .noSpeechDetected = error { return [] }
            throw error
        }
        let ordered = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var mapping: [String: String] = [:]
        return ordered.map { segment in
            let id = mapping[segment.speakerId] ?? {
                let next = "S\(mapping.count + 1)"
                mapping[segment.speakerId] = next
                return next
            }()
            return TBDSpeakerTurn(speaker: id, start: Int(segment.startTimeSeconds * 1000), end: Int(segment.endTimeSeconds * 1000))
        }
    }

    public func unload() { models = nil }
}
