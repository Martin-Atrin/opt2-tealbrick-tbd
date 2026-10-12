import AVFoundation
import FluidAudio
import Foundation

/// NVIDIA Parakeet Unified EN 0.6B through FluidAudio's streaming manager (int8 encoder).
/// A different runtime from TDT v2/v3: punctuation and capitals, token-derived word timings and
/// native streaming partials. English only.
public actor TBDParakeetUnifiedEngine: TBDStreamingSpeechEngine {
    public nonisolated let kind = TBDSpeechEngineKind.parakeetUnified
    static let sliceSamples = 160_000
    static let precision = UnifiedEncoderPrecision.int8

    private let modelsRoot: URL
    private var managers: [TBDLane: StreamingUnifiedAsrManager] = [:]
    private var loading: Task<Void, Error>?
    private var activeLanes: Set<TBDLane> = []

    public init(modelsRoot: URL = TBDListeningPaths.models) { self.modelsRoot = modelsRoot }

    // MARK: Model files

    static func directory(modelsRoot: URL) -> URL {
        modelsRoot.appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
    }

    static var streamingEncoderFile: String { ModelNames.ParakeetUnified.streamingEncoderFile(precision: precision) }

    /// Shared decoder/joint/vocab/metadata plus the int8 streaming encoder.
    static var requiredFiles: Set<String> {
        ModelNames.ParakeetUnified.requiredModels(variant: nil).union([streamingEncoderFile])
    }

    static func isDownloaded(modelsRoot: URL = TBDListeningPaths.models) -> Bool {
        TBDEngineSupport.filesExist(requiredFiles, in: directory(modelsRoot: modelsRoot))
    }

    /// Only called from an explicit user action. `variant: nil` is FluidAudio's int8 streaming export.
    static func download(modelsRoot: URL = TBDListeningPaths.models, progress: (@Sendable (Double) -> Void)?) async throws {
        try TBDListeningPaths.ensure(modelsRoot)
        try await ModelHub.download(.parakeetUnified, to: modelsRoot, variant: nil, additionalModelNames: [streamingEncoderFile],
                                    progressHandler: TBDEngineSupport.progressHandler(progress))
    }

    // MARK: Lifecycle

    public func prepare() async throws {
        if !managers.isEmpty { return }
        if let loading { return try await loading.value }
        let task = Task { try await self.load() }
        loading = task
        defer { loading = nil }
        do { try await task.value } catch { throw TBDEngineSupport.map(error) }
    }

    private func load() async throws {
        guard Self.isDownloaded(modelsRoot: modelsRoot) else { throw TBDSpeechError.modelNotDownloaded(kind.capabilities.displayName) }
        let directory = Self.directory(modelsRoot: modelsRoot)
        var loaded: [TBDLane: StreamingUnifiedAsrManager] = [:]
        do {
            for lane in [TBDLane.interactive, .background] {
                let manager = StreamingUnifiedAsrManager(encoderPrecision: Self.precision)
                loaded[lane] = manager
                try await TBDInferenceGate.run { try await manager.loadModels(from: directory) }
                try Task.checkCancellation()
            }
        } catch {
            for manager in loaded.values { await manager.cleanup() }
            throw error
        }
        managers = loaded
    }

    public func unload() async {
        loading?.cancel()
        _ = try? await loading?.value
        let current = Array(managers.values)
        managers = [:]
        for manager in current { await manager.cleanup() }
    }

    private func claim(_ lane: TBDLane) throws {
        guard activeLanes.insert(lane).inserted else { throw TBDSpeechError.busy("Parakeet Unified") }
    }

    private func manager(_ lane: TBDLane) throws -> StreamingUnifiedAsrManager {
        guard let manager = managers[lane] else { throw TBDSpeechError.engineFailed("Parakeet Unified is not loaded") }
        return manager
    }

    // MARK: Batch

    public func transcribe(url: URL, lane: TBDLane, progress: (@Sendable (Double) -> Void)?) async throws -> TBDTranscript {
        try claim(lane)
        defer { activeLanes.remove(lane) }
        do {
            try await prepare()
            progress?(0)
            let samples = try await Task.detached(priority: .userInitiated) { try AudioConverter().resampleAudioFile(url) }.value
            progress?(0.2)
            return try await run(samples, on: try manager(lane), progress: progress)
        } catch { throw TBDEngineSupport.map(error) }
    }

    /// Dictation gets trailing silence so a final fast word is decoded.
    public func transcribe(samples: [Float], lane: TBDLane) async throws -> TBDTranscript {
        guard !samples.isEmpty else { return TBDTranscript(text: "", engine: kind.rawValue) }
        try claim(lane)
        defer { activeLanes.remove(lane) }
        do {
            try await prepare()
            let input = lane == .interactive ? TBDEngineSupport.appendingTrailingSilence(samples) : samples
            var transcript = try await run(input, on: try manager(lane), progress: nil)
            transcript.durationMs = samples.count / 16
            return transcript
        } catch { throw TBDEngineSupport.map(error) }
    }

    private func run(_ samples: [Float], on manager: StreamingUnifiedAsrManager,
                     progress: (@Sendable (Double) -> Void)?) async throws -> TBDTranscript {
        try await manager.reset()
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(offset + Self.sliceSamples, samples.count)
            try await feed(samples[offset..<end], to: manager)
            offset = end
            progress?(0.2 + 0.7 * Double(offset) / Double(samples.count))
        }
        try Task.checkCancellation()
        let text = try await TBDInferenceGate.run { try await manager.finish() }
        let timings = await manager.consumeTokenTimings()
        progress?(1)
        return makeTranscript(text: text, timings: timings, durationMs: samples.count / 16)
    }

    private func feed(_ samples: ArraySlice<Float>, to manager: StreamingUnifiedAsrManager) async throws {
        let buffer = TBDUncheckedBuffer(try TBDEngineSupport.pcmBuffer(samples))
        try await manager.appendAudio(buffer.buffer)
        try await TBDInferenceGate.run { try await manager.processBufferedAudio() }
    }

    private func makeTranscript(text: String, timings: [TokenTiming], durationMs: Int) -> TBDTranscript {
        let tokens = timings.map { (token: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence) }
        return TBDTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines), words: TBDWordTiming.words(tokens: tokens),
                             language: "en", engine: kind.rawValue, durationMs: durationMs)
    }

    // MARK: Live

    public func beginLive(language: String?, onPartial: @escaping @Sendable (String) -> Void) async throws {
        try claim(.interactive)
        do {
            try await prepare()
            let manager = try manager(.interactive)
            try await manager.reset()
            await manager.setPartialTranscriptCallback { onPartial($0) }
        } catch {
            activeLanes.remove(.interactive)
            throw TBDEngineSupport.map(error)
        }
    }

    public func appendLive(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        guard activeLanes.contains(.interactive), let manager = managers[.interactive] else { throw TBDSpeechError.engineFailed("no live session") }
        do {
            try Task.checkCancellation()
            try await feed(samples[...], to: manager)
        } catch { throw TBDEngineSupport.map(error) }
    }

    public func finishLive() async throws -> TBDTranscript {
        guard activeLanes.contains(.interactive), let manager = managers[.interactive] else { throw TBDSpeechError.engineFailed("no live session") }
        defer { activeLanes.remove(.interactive) }
        do {
            await manager.setPartialTranscriptCallback { _ in }
            let text = try await TBDInferenceGate.run { try await manager.finish() }
            let timings = await manager.consumeTokenTimings()
            return makeTranscript(text: text, timings: timings, durationMs: timings.last.map { Int($0.endTime * 1000) } ?? 0)
        } catch { throw TBDEngineSupport.map(error) }
    }

    public func cancelLive() async {
        guard activeLanes.contains(.interactive) else { return }
        if let manager = managers[.interactive] {
            await manager.setPartialTranscriptCallback { _ in }
            try? await manager.reset()
        }
        activeLanes.remove(.interactive)
    }
}
