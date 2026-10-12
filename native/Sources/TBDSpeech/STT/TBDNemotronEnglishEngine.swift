import AVFoundation
import FluidAudio
import Foundation

/// Nemotron Speech Streaming EN 0.6B (1120 ms tier) through FluidAudio's English streaming manager.
/// Files are fed in 10 s slices and finalised; live dictation streams partials. English only.
public actor TBDNemotronEnglishEngine: TBDStreamingSpeechEngine {
    public nonisolated let kind = TBDSpeechEngineKind.nemotronEnglish
    /// 10 s at 16 kHz: bounds buffer copies and sets the cancellation/progress granularity.
    static let sliceSamples = 160_000

    private let modelsRoot: URL
    private var managers: [TBDLane: StreamingNemotronAsrManager] = [:]
    private var loading: Task<Void, Error>?
    private var activeLanes: Set<TBDLane> = []

    public init(modelsRoot: URL = TBDListeningPaths.models) { self.modelsRoot = modelsRoot }

    // MARK: Model files

    static func directory(modelsRoot: URL) -> URL {
        modelsRoot.appendingPathComponent(Repo.nemotronStreaming1120.folderName, isDirectory: true)
    }

    /// The files the manager loads are present. metadata.json is required too: without it the
    /// manager silently falls back to the 2240 ms chunk geometry (wrong tier for this build).
    static func isDownloaded(modelsRoot: URL = TBDListeningPaths.models) -> Bool {
        let names = ModelNames.NemotronStreaming.self
        return TBDEngineSupport.filesExist([names.metadata, names.encoderInt8File, names.decoderFile, names.jointFile, names.tokenizer],
                                           in: directory(modelsRoot: modelsRoot))
    }

    /// Only called from an explicit user action.
    static func download(modelsRoot: URL = TBDListeningPaths.models, progress: (@Sendable (Double) -> Void)?) async throws {
        try TBDListeningPaths.ensure(modelsRoot)
        try await ModelHub.download(.nemotronStreaming1120, to: modelsRoot, progressHandler: TBDEngineSupport.progressHandler(progress))
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
        var loaded: [TBDLane: StreamingNemotronAsrManager] = [:]
        // No shared-weights API: both lanes map the same compiled files (page cache shares them).
        // loadModels runs an encoder probe, so it is inference and takes the gate.
        for lane in [TBDLane.interactive, .background] {
            let manager = StreamingNemotronAsrManager(requestedChunkSize: .ms1120)
            try await TBDInferenceGate.run { try await manager.loadModels(from: directory) }
            loaded[lane] = manager
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
        guard activeLanes.insert(lane).inserted else { throw TBDSpeechError.busy("Nemotron English") }
    }

    private func manager(_ lane: TBDLane) throws -> StreamingNemotronAsrManager {
        guard let manager = managers[lane] else { throw TBDSpeechError.engineFailed("Nemotron English is not loaded") }
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
            progress?(0.25)
            return try await run(samples, on: try manager(lane), progress: progress)
        } catch { throw TBDEngineSupport.map(error) }
    }

    public func transcribe(samples: [Float], lane: TBDLane) async throws -> TBDTranscript {
        guard !samples.isEmpty else { return TBDTranscript(text: "", engine: kind.rawValue) }
        try claim(lane)
        defer { activeLanes.remove(lane) }
        do {
            try await prepare()
            return try await run(samples, on: try manager(lane), progress: nil)
        } catch { throw TBDEngineSupport.map(error) }
    }

    private func run(_ samples: [Float], on manager: StreamingNemotronAsrManager,
                     progress: (@Sendable (Double) -> Void)?) async throws -> TBDTranscript {
        // Fresh session: clears encoder caches, decoder state and audio a cancelled job left behind.
        await manager.reset()
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(offset + Self.sliceSamples, samples.count)
            try await feed(samples[offset..<end], to: manager)
            offset = end
            progress?(0.25 + 0.65 * Double(offset) / Double(samples.count))
        }
        let final = try await TBDInferenceGate.run { try await manager.finishWithTokenTimings() }
        progress?(1)
        return makeTranscript(final, durationMs: samples.count / 16)
    }

    private func feed(_ samples: ArraySlice<Float>, to manager: StreamingNemotronAsrManager) async throws {
        let buffer = TBDUncheckedBuffer(try TBDEngineSupport.pcmBuffer(samples))
        try await TBDInferenceGate.run { _ = try await manager.process(audioBuffer: buffer.buffer) }
    }

    private func makeTranscript(_ final: (text: String, timings: [TokenTiming]), durationMs: Int) -> TBDTranscript {
        let tokens = final.timings.map { (token: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence) }
        return TBDTranscript(text: final.text.trimmingCharacters(in: .whitespacesAndNewlines), words: TBDWordTiming.words(tokens: tokens),
                             language: "en", engine: kind.rawValue, durationMs: durationMs)
    }

    // MARK: Live

    public func beginLive(language: String?, onPartial: @escaping @Sendable (String) -> Void) async throws {
        try claim(.interactive)
        do {
            try await prepare()
            let manager = try manager(.interactive)
            await manager.reset()
            await manager.setPartialCallback { onPartial($0) }
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
            await manager.setPartialCallback { _ in }
            let final = try await TBDInferenceGate.run { try await manager.finishWithTokenTimings() }
            return makeTranscript(final, durationMs: final.timings.last.map { Int($0.endTime * 1000) } ?? 0)
        } catch { throw TBDEngineSupport.map(error) }
    }

    public func cancelLive() async {
        guard activeLanes.contains(.interactive) else { return }
        if let manager = managers[.interactive] {
            await manager.setPartialCallback { _ in }
            await manager.reset()
        }
        activeLanes.remove(.interactive)
    }
}

/// Carries an `AVAudioPCMBuffer` across an actor hop. The buffer is created for one call and
/// never touched again by the sender.
struct TBDUncheckedBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
