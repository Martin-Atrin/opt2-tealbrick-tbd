import CoreML
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT v2/v3 through FluidAudio (CoreML, Neural Engine).
/// One shared model bundle; each lane owns an `AsrManager` so dictation never waits for a file job.
public final class TBDParakeetEngine: TBDSpeechEngine, @unchecked Sendable {
    public let kind: TBDSpeechEngineKind
    private let version: AsrModelVersion
    private let directory: URL
    private let lock = NSLock()
    private var managers: [TBDLane: AsrManager] = [:]
    private var decoderLayers = 0
    private var loading: Task<Void, Error>?

    /// TDT v2 or v3 (`kind` is `.parakeetV2` or `.parakeetV3`).
    public init(kind: TBDSpeechEngineKind, modelsRoot: URL = TBDListeningPaths.models) {
        precondition(kind == .parakeetV2 || kind == .parakeetV3)
        self.kind = kind
        version = kind == .parakeetV2 ? .v2 : .v3
        directory = Self.directory(for: kind, modelsRoot: modelsRoot)
    }

    static func directory(for kind: TBDSpeechEngineKind, modelsRoot: URL) -> URL {
        let repo: Repo = kind == .parakeetV2 ? .parakeetV2 : .parakeetV3
        return modelsRoot.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    static func isDownloaded(_ kind: TBDSpeechEngineKind, modelsRoot: URL = TBDListeningPaths.models) -> Bool {
        AsrModels.modelsExist(at: directory(for: kind, modelsRoot: modelsRoot), version: kind == .parakeetV2 ? .v2 : .v3)
    }

    /// Downloads (or validates) the model files. Only called from an explicit user action.
    static func download(_ kind: TBDSpeechEngineKind, modelsRoot: URL = TBDListeningPaths.models,
                         progress: (@Sendable (Double) -> Void)?) async throws {
        try TBDListeningPaths.ensure(modelsRoot)
        try await AsrModels.download(to: directory(for: kind, modelsRoot: modelsRoot),
                                     version: kind == .parakeetV2 ? .v2 : .v3,
                                     progressHandler: TBDEngineSupport.progressHandler(progress))
    }

    public func prepare() async throws {
        let task: Task<Void, Error> = lock.withLock {
            if !managers.isEmpty { return Task {} }
            if let loading { return loading }
            let task = Task { try await self.load() }
            loading = task
            return task
        }
        defer { lock.withLock { loading = nil } }
        try await task.value
    }

    private func load() async throws {
        guard Self.isDownloaded(kind, modelsRoot: directory.deletingLastPathComponent()) else {
            throw TBDSpeechError.modelNotDownloaded(kind.displayName)
        }
        // macOS 14: the conformer encoder on GPU and one chunk at a time avoid the ANE reentrancy crash.
        let models = try await AsrModels.load(from: directory, version: version,
                                              encoderComputeUnits: TBDInferenceGate.required ? .cpuAndGPU : nil)
        let config = TBDInferenceGate.required ? ASRConfig(parallelChunkConcurrency: 1) : .default
        var loaded: [TBDLane: AsrManager] = [:]
        for lane in [TBDLane.interactive, .background] {
            let manager = AsrManager(config: config)
            try await manager.loadModels(models)
            loaded[lane] = manager
        }
        let layers = await loaded[.interactive]!.decoderLayerCount
        lock.withLock { managers = loaded; decoderLayers = layers }
    }

    private func manager(_ lane: TBDLane) async throws -> (AsrManager, Int) {
        try await prepare()
        guard let pair = lock.withLock({ managers[lane].map { ($0, decoderLayers) } }) else {
            throw TBDSpeechError.engineFailed("model not loaded")
        }
        return pair
    }

    public func transcribe(url: URL, lane: TBDLane, progress: (@Sendable (Double) -> Void)?) async throws -> TBDTranscript {
        let (manager, layers) = try await manager(lane)
        let progressTask: Task<Void, Never>? = progress.map { report in
            Task {
                let stream = await manager.transcriptionProgressStream
                do { for try await value in stream { report(value) } } catch {}
            }
        }
        defer { progressTask?.cancel() }
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await TBDInferenceGate.run { try await manager.transcribe(url, decoderState: &state) }
        return makeTranscript(result)
    }

    public func transcribe(samples: [Float], lane: TBDLane) async throws -> TBDTranscript {
        guard !samples.isEmpty else { return TBDTranscript(text: "", engine: kind.rawValue) }
        let (manager, layers) = try await manager(lane)
        // A short trailing pad lets the TDT decoder emit a final word that lands on the last frame.
        var padded = samples
        if lane == .interactive, samples.count + 8_000 <= ASRConstants.maxModelSamples {
            padded.append(contentsOf: repeatElement(0, count: 8_000))
        }
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await TBDInferenceGate.run { try await manager.transcribe(padded, decoderState: &state) }
        var transcript = makeTranscript(result)
        transcript.durationMs = samples.count / 16
        return transcript
    }

    private func makeTranscript(_ result: ASRResult) -> TBDTranscript {
        let tokens = (result.tokenTimings ?? []).map { (token: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence) }
        return TBDTranscript(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                             words: TBDWordTiming.words(tokens: tokens), language: nil,
                             engine: kind.rawValue, durationMs: Int(result.duration * 1000))
    }

    public func unload() async {
        let current = lock.withLock { () -> [AsrManager] in
            defer { managers = [:] }
            return Array(managers.values)
        }
        for manager in current { await manager.cleanup() }
    }
}
