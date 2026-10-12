import FluidAudio
import Foundation

/// Nemotron 3.5 ASR Streaming Multilingual 0.6B (1120 ms tier) through FluidAudio.
/// One shared weight set, one streaming manager per lane. Files are fed whole and finalised;
/// live dictation streams partials. The language hint selects the vocabulary-pruned "latin"
/// build for en/es/fr/it/pt/de and the full multilingual build otherwise (a separate download).
public actor TBDNemotronEngine: TBDStreamingSpeechEngine {
    public nonisolated let kind = TBDSpeechEngineKind.nemotronMultilingual
    static let chunkMs = 1120

    private let language: String?
    private let modelsRoot: URL
    private var shared: SharedNemotronMultilingualModels?
    private var managers: [TBDLane: StreamingNemotronMultilingualAsrManager] = [:]
    private var loading: Task<Void, Error>?
    private var activeLanes: Set<TBDLane> = []
    private var liveLanguage: String?

    public init(language: String?, modelsRoot: URL = TBDListeningPaths.models) {
        self.language = TBDListeningPreferences.normalizedLanguage(language)
        self.modelsRoot = modelsRoot
    }

    // MARK: Model files

    static func repoDirectory(modelsRoot: URL) -> URL {
        modelsRoot.appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
    }

    /// `<repo>/<latin|multilingual>/1120ms`.
    static func variantDirectory(language: String?, modelsRoot: URL) -> URL {
        let folder = StreamingNemotronMultilingualAsrManager.languageDirectory(for: language ?? "auto")
        return repoDirectory(modelsRoot: modelsRoot).appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("\(chunkMs)ms", isDirectory: true)
    }

    static func isDownloaded(language: String?, modelsRoot: URL = TBDListeningPaths.models) -> Bool {
        let metadata = variantDirectory(language: language, modelsRoot: modelsRoot)
            .appendingPathComponent(ModelNames.NemotronMultilingualStreaming.metadata)
        return FileManager.default.fileExists(atPath: metadata.path)
    }

    /// Downloads the variant for `language`. Only called from an explicit user action.
    static func download(language: String?, modelsRoot: URL = TBDListeningPaths.models,
                         progress: (@Sendable (Double) -> Void)?) async throws {
        try TBDListeningPaths.ensure(modelsRoot)
        _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: language ?? "auto", chunkMs: chunkMs, to: modelsRoot,
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
        guard Self.isDownloaded(language: language, modelsRoot: modelsRoot) else {
            throw TBDSpeechError.modelNotDownloaded(kind.capabilities.displayName)
        }
        let directory = Self.variantDirectory(language: language, modelsRoot: modelsRoot)
        // Loading compiles and warms CoreML programs: inference on macOS 14, so it takes the gate.
        let shared = try await TBDInferenceGate.run { try await StreamingNemotronMultilingualAsrManager.preloadShared(from: directory) }
        var loaded: [TBDLane: StreamingNemotronMultilingualAsrManager] = [:]
        for lane in [TBDLane.interactive, .background] {
            let manager = StreamingNemotronMultilingualAsrManager()
            try await TBDInferenceGate.run { try await manager.loadFromShared(shared) }
            await manager.configure(language: language)
            loaded[lane] = manager
        }
        self.shared = shared
        managers = loaded
    }

    public func unload() async {
        loading?.cancel()
        _ = try? await loading?.value
        let current = Array(managers.values)
        managers = [:]
        shared = nil
        for manager in current { await manager.cleanup() }
    }

    private func claim(_ lane: TBDLane) throws {
        guard activeLanes.insert(lane).inserted else { throw TBDSpeechError.busy("Nemotron") }
    }

    private func manager(_ lane: TBDLane) throws -> StreamingNemotronMultilingualAsrManager {
        guard let manager = managers[lane] else { throw TBDSpeechError.engineFailed("Nemotron is not loaded") }
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
            var transcript = try await run(samples, on: try manager(lane), progress: nil)
            transcript.durationMs = samples.count / 16
            return transcript
        } catch { throw TBDEngineSupport.map(error) }
    }

    private func run(_ samples: [Float], on manager: StreamingNemotronMultilingualAsrManager,
                     progress: (@Sendable (Double) -> Void)?) async throws -> TBDTranscript {
        await manager.configure(language: language)
        try Task.checkCancellation()
        _ = try await TBDInferenceGate.run { try await manager.process(samples: samples) }
        progress?(0.9)
        let final = try await TBDInferenceGate.run { try await manager.finishWithTokenTimings() }
        let detected = await manager.detectedLanguage()
        progress?(1)
        return makeTranscript(final, language: detected ?? language, durationMs: samples.count / 16)
    }

    private func makeTranscript(_ final: (text: String, timings: [TokenTiming]), language: String?, durationMs: Int) -> TBDTranscript {
        let tokens = final.timings.map { (token: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence) }
        return TBDTranscript(text: final.text.trimmingCharacters(in: .whitespacesAndNewlines), words: TBDWordTiming.words(tokens: tokens),
                             language: language, engine: kind.rawValue, durationMs: durationMs)
    }

    // MARK: Live

    public func beginLive(language: String?, onPartial: @escaping @Sendable (String) -> Void) async throws {
        try claim(.interactive)
        do {
            try await prepare()
            let manager = try manager(.interactive)
            let requested = TBDListeningPreferences.normalizedLanguage(language) ?? self.language
            await manager.configure(language: requested)
            await manager.setPartialCallback { onPartial($0) }
            liveLanguage = requested
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
            _ = try await TBDInferenceGate.run { try await manager.process(samples: samples) }
        } catch { throw TBDEngineSupport.map(error) }
    }

    public func finishLive() async throws -> TBDTranscript {
        guard activeLanes.contains(.interactive), let manager = managers[.interactive] else { throw TBDSpeechError.engineFailed("no live session") }
        defer { activeLanes.remove(.interactive); liveLanguage = nil }
        do {
            await manager.setPartialCallback { _ in }
            let final = try await TBDInferenceGate.run { try await manager.finishWithTokenTimings() }
            let detected = await manager.detectedLanguage()
            return makeTranscript(final, language: detected ?? liveLanguage, durationMs: final.timings.last.map { Int($0.endTime * 1000) } ?? 0)
        } catch { throw TBDEngineSupport.map(error) }
    }

    public func cancelLive() async {
        guard activeLanes.contains(.interactive) else { return }
        // Release the lane even when unload() already dropped the manager.
        if let manager = managers[.interactive] {
            await manager.setPartialCallback { _ in }
            await manager.reset()
        }
        liveLanguage = nil
        activeLanes.remove(.interactive)
    }
}

private extension StreamingNemotronMultilingualAsrManager {
    /// Fresh session with the language hint and terminal punctuation (donor configuration).
    func configure(language: String?) async {
        await reset()
        await setLanguage(language)
        appendTerminalPunctuation = true
    }
}
