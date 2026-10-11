import Foundation

/// Entry point for transcription: one resident engine (the user's choice), a priority scheduler
/// and the diarizer. Switching engines unloads the previous model once its jobs finish.
public actor TBDSpeechService {
    public static let shared = TBDSpeechService()

    public nonisolated let scheduler: TBDSTTScheduler
    public nonisolated let diarizer: TBDDiarizer
    private let preferences: TBDListeningPreferences
    private let modelsRoot: URL
    private var engine: (any TBDSpeechEngine)?
    private var engineKey = ""
    private var inFlight: [ObjectIdentifier: Int] = [:]
    private var retired: [any TBDSpeechEngine] = []

    public init(preferences: TBDListeningPreferences = TBDListeningPreferences(), modelsRoot: URL = TBDListeningPaths.models,
                scheduler: TBDSTTScheduler = TBDSTTScheduler()) {
        self.preferences = preferences
        self.modelsRoot = modelsRoot
        self.scheduler = scheduler
        diarizer = TBDDiarizer(modelsRoot: modelsRoot)
    }

    /// The engine matching current preferences, created on demand.
    private func resident() -> any TBDSpeechEngine {
        let choice = preferences.engine
        let language = preferences.whisperLanguage
        let key = choice.rawValue + "|" + (choice == .whisper ? language ?? "auto" : "")
        if let engine, key == engineKey { return engine }
        if let old = engine { retired.append(old) }
        let created: any TBDSpeechEngine = choice == .whisper
            ? TBDWhisperEngine(language: language, modelsRoot: modelsRoot)
            : TBDParakeetEngine(choice: choice, modelsRoot: modelsRoot)
        engine = created
        engineKey = key
        unloadRetired()
        return created
    }

    private func unloadRetired() {
        let idle = retired.filter { (inFlight[ObjectIdentifier($0)] ?? 0) == 0 }
        retired.removeAll { (inFlight[ObjectIdentifier($0)] ?? 0) == 0 }
        for engine in idle { Task { await engine.unload() } }
    }

    private func begin() -> any TBDSpeechEngine {
        let engine = resident()
        inFlight[ObjectIdentifier(engine), default: 0] += 1
        return engine
    }

    private func end(_ engine: any TBDSpeechEngine) {
        inFlight[ObjectIdentifier(engine), default: 1] -= 1
        unloadRetired()
    }

    /// Whether the selected engine's model is on disk.
    public nonisolated func isReady() -> Bool {
        TBDModelManager(modelsRoot: modelsRoot).isDownloaded(TBDModelManager.Model(engine: preferences.engine))
    }

    /// Loads the selected model in the background when it is downloaded.
    public func warmUp() async {
        guard isReady() else { return }
        try? await resident().prepare()
    }

    public func transcribe(url: URL, kind: TBDJobKind, progress: (@Sendable (Double) -> Void)? = nil) async throws -> TBDTranscript {
        let engine = begin()
        defer { end(engine) }
        return try await scheduler.run(kind) { try await engine.transcribe(url: url, lane: kind.lane, progress: progress) }
    }

    public func transcribe(samples: [Float], kind: TBDJobKind) async throws -> TBDTranscript {
        let engine = begin()
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
        let current = engine
        engine = nil; engineKey = ""
        await current?.unload()
        await diarizer.unload()
    }
}
