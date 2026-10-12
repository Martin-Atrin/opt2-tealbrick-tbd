import Foundation

/// Entry point for transcription. Two routes, each with its own engine choice: live (dictation,
/// meeting preview) and final (files, links, meeting transcript). At most one engine per route
/// stays loaded; an engine no route uses any more is unloaded once its jobs finish. One priority
/// scheduler (unchanged) orders all jobs.
public actor TBDSpeechService {
    public static let shared = TBDSpeechService()

    public nonisolated let scheduler: TBDSTTScheduler
    public nonisolated let diarizer: TBDDiarizer
    public nonisolated let preferences: TBDListeningPreferences
    public nonisolated let modelsRoot: URL
    private var engines: [String: any TBDSpeechEngine] = [:]
    private var inFlight: [ObjectIdentifier: Int] = [:]
    private var retired: [any TBDSpeechEngine] = []

    public init(preferences: TBDListeningPreferences = TBDListeningPreferences(), modelsRoot: URL = TBDListeningPaths.models,
                scheduler: TBDSTTScheduler = TBDSTTScheduler()) {
        self.preferences = preferences
        self.modelsRoot = modelsRoot
        self.scheduler = scheduler
        diarizer = TBDDiarizer(modelsRoot: modelsRoot)
    }

    /// Engine and language for a route from current preferences.
    public nonisolated func selection(for route: TBDSpeechRoute) -> TBDEngineSelection { preferences.selection(for: route) }

    /// Creates the engine object for a selection. Never loads or downloads a model.
    static func makeEngine(_ selection: TBDEngineSelection, modelsRoot: URL) -> any TBDSpeechEngine {
        switch selection.kind {
        case .parakeetV3, .parakeetV2: TBDParakeetEngine(kind: selection.kind, modelsRoot: modelsRoot)
        case .parakeetUnified: TBDParakeetUnifiedEngine(modelsRoot: modelsRoot)
        case .nemotronMultilingual: TBDNemotronEngine(language: selection.language, modelsRoot: modelsRoot)
        case .nemotronEnglish: TBDNemotronEnglishEngine(modelsRoot: modelsRoot)
        case .cohere: TBDCohereEngine(language: selection.language, modelsRoot: modelsRoot)
        case .whisper: TBDWhisperEngine(language: selection.language, modelsRoot: modelsRoot)
        }
    }

    /// The engine for `selection`, created on demand. Engines that neither route (nor the
    /// requested selection) use any more are retired.
    func engine(for selection: TBDEngineSelection) -> any TBDSpeechEngine {
        let key = selection.residentKey
        let wanted: Set<String> = [key, self.selection(for: .live).residentKey, self.selection(for: .final).residentKey]
        for (oldKey, old) in engines where !wanted.contains(oldKey) {
            engines[oldKey] = nil
            retired.append(old)
        }
        unloadRetired()
        if let engine = engines[key] { return engine }
        let created = Self.makeEngine(selection, modelsRoot: modelsRoot)
        engines[key] = created
        return created
    }

    /// Keys of engine objects currently resident (for tests and diagnostics).
    var residentKeys: Set<String> { Set(engines.keys) }

    private func unloadRetired() {
        let idle = retired.filter { (inFlight[ObjectIdentifier($0)] ?? 0) == 0 }
        retired.removeAll { (inFlight[ObjectIdentifier($0)] ?? 0) == 0 }
        for engine in idle { Task { await engine.unload() } }
    }

    private func begin(_ selection: TBDEngineSelection) -> any TBDSpeechEngine {
        let engine = engine(for: selection)
        inFlight[ObjectIdentifier(engine), default: 0] += 1
        return engine
    }

    private func end(_ engine: any TBDSpeechEngine) {
        inFlight[ObjectIdentifier(engine), default: 1] -= 1
        unloadRetired()
    }

    /// Whether the model for a route's engine is on disk.
    public nonisolated func isReady(_ route: TBDSpeechRoute = .live) -> Bool {
        let selection = selection(for: route)
        return TBDModelManager(modelsRoot: modelsRoot, nemotronLanguage: selection.kind == .nemotronMultilingual ? selection.language : nil)
            .isDownloaded(engine: selection.kind)
    }

    /// Loads the downloaded route engines in the background (live first: dictation latency).
    public func warmUp() async {
        for route in [TBDSpeechRoute.live, .final] where isReady(route) {
            try? await engine(for: selection(for: route)).prepare()
        }
    }

    /// Transcribes a file. `engine` overrides the route's engine for this job (for example a
    /// meeting plan captured at start, or `tbd-listen --engine`).
    public func transcribe(url: URL, kind: TBDJobKind, engine override: TBDEngineSelection? = nil,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> TBDTranscript {
        let engine = begin(override ?? selection(for: kind.route))
        defer { end(engine) }
        return try await scheduler.run(kind) { try await engine.transcribe(url: url, lane: kind.lane, progress: progress) }
    }

    public func transcribe(samples: [Float], kind: TBDJobKind, engine override: TBDEngineSelection? = nil) async throws -> TBDTranscript {
        let engine = begin(override ?? selection(for: kind.route))
        defer { end(engine) }
        return try await scheduler.run(kind) { try await engine.transcribe(samples: samples, lane: kind.lane) }
    }

    /// Speaker turns for a recording, or nil when speaker detection is off or not downloaded.
    public func speakerTurns(_ url: URL, kind: TBDJobKind = .meetingFinal) async throws -> [TBDSpeakerTurn]? {
        guard preferences.diarize, TBDDiarizer.isDownloaded(modelsRoot: modelsRoot) else { return nil }
        let diarizer = self.diarizer
        return try await scheduler.run(kind) { try await diarizer.diarize(url) }
    }

    public func shutdown() async {
        let current = Array(engines.values) + retired
        engines = [:]
        retired = []
        for engine in current { await engine.unload() }
        await diarizer.unload()
    }
}
