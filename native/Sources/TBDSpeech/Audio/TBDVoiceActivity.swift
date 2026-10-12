@preconcurrency import CoreML
import FluidAudio
import Foundation

/// A speech boundary reported by streaming voice activity detection.
public enum TBDVADEvent: Sendable, Equatable {
    case speechStart
    /// Speech ended; `sampleIndex` is absolute from the start of the stream.
    case speechEnd(sampleIndex: Int)
}

/// Opaque streaming VAD state. Detectors that are not FluidAudio (tests) keep their own state in `custom`.
public struct TBDVADStreamState: Sendable {
    var fluid: VadStreamState?
    var custom: Int = 0
    init(fluid: VadStreamState? = nil, custom: Int = 0) { self.fluid = fluid; self.custom = custom }
}

public struct TBDVADConfig: Sendable, Equatable {
    public var minSilenceDuration: TimeInterval = 0.50
    public var speechPadding: TimeInterval = 0.15
    public static let `default` = TBDVADConfig()
}

/// Streaming voice activity detection over 4096-sample (256 ms) windows of 16 kHz audio.
public protocol TBDVoiceActivityDetecting: Sendable {
    func makeStreamState() async -> TBDVADStreamState
    func process(_ window: [Float], state: TBDVADStreamState, config: TBDVADConfig) async throws -> (state: TBDVADStreamState, event: TBDVADEvent?)
}

/// Silero VAD on Core ML through FluidAudio (CPU only; it is tiny). Loaded once and shared.
public actor TBDSileroVAD: TBDVoiceActivityDetecting {
    private let manager: VadManager

    init(manager: VadManager) { self.manager = manager }

    static func directory(modelsRoot: URL) -> URL {
        modelsRoot.appendingPathComponent(Repo.vad.folderName, isDirectory: true)
    }

    public static func isDownloaded(modelsRoot: URL = TBDListeningPaths.models) -> Bool {
        TBDEngineSupport.filesExist(ModelNames.VAD.requiredModels, in: directory(modelsRoot: modelsRoot))
    }

    /// Only called from an explicit user action.
    static func download(modelsRoot: URL = TBDListeningPaths.models, progress: (@Sendable (Double) -> Void)?) async throws {
        try TBDListeningPaths.ensure(modelsRoot)
        try await ModelHub.download(.vad, to: modelsRoot, progressHandler: TBDEngineSupport.progressHandler(progress))
    }

    private static let cache = NSLockedValue<[String: TBDSileroVAD]>([:])

    /// The loaded detector, or nil when the model is not downloaded or fails to load (callers
    /// then fall back to energy-based chunking). Never downloads.
    public static func loadIfDownloaded(modelsRoot: URL = TBDListeningPaths.models) async -> TBDSileroVAD? {
        if let cached = cache.withLock({ $0[modelsRoot.path] }) { return cached }
        guard isDownloaded(modelsRoot: modelsRoot) else { return nil }
        do {
            let models = try await ModelHub.loadModels(.vad, modelNames: Array(ModelNames.VAD.requiredModels),
                                                       directory: modelsRoot, computeUnits: .cpuOnly)
            guard let model = models[ModelNames.VAD.sileroVadFile] else { return nil }
            let vad = TBDSileroVAD(manager: VadManager(config: VadConfig(computeUnits: .cpuOnly), vadModel: model))
            cache.withLock { $0[modelsRoot.path] = vad }
            return vad
        } catch {
            return nil
        }
    }

    public func makeStreamState() async -> TBDVADStreamState {
        TBDVADStreamState(fluid: await manager.makeStreamState())
    }

    public func process(_ window: [Float], state: TBDVADStreamState, config: TBDVADConfig) async throws -> (state: TBDVADStreamState, event: TBDVADEvent?) {
        var current = state.fluid
        if current == nil { current = await manager.makeStreamState() }
        let result = try await manager.processStreamingChunk(
            window, state: current!,
            config: VadSegmentationConfig(minSilenceDuration: config.minSilenceDuration, speechPadding: config.speechPadding))
        let event: TBDVADEvent? = result.event.map {
            switch $0.kind {
            case .speechStart: .speechStart
            case .speechEnd: .speechEnd(sampleIndex: $0.sampleIndex)
            }
        }
        return (TBDVADStreamState(fluid: result.state), event)
    }
}
