import Foundation

/// On-disk description of a meeting recording. Written at start, so a crash leaves a recoverable
/// folder: `meeting.json`, `microphone.wav`, `system.wav`.
public struct TBDMeetingManifest: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case recording, stopped, done }
    public var id: String
    public var title: String
    public var startedAt: Date
    public var state: State
    public var durationMs: Int
    public var transcriptionID: String?
    /// Final engine fixed when the meeting started (nil in older manifests: the current final route).
    public var finalEngine: TBDEngineSelection?
    /// The person's notes, rewritten on every save so a crash keeps them.
    public var notes: String?

    static let fileName = "meeting.json"

    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static func read(from folder: URL) -> TBDMeetingManifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: folder.appendingPathComponent(fileName))).flatMap { try? decoder.decode(Self.self, from: $0) }
    }
}

public enum TBDMeetingStartError: Error, LocalizedError, Equatable {
    case systemAudioUnavailable
    public var errorDescription: String? {
        "System audio could not start. Allow Screen & System Audio Recording for TBD in System Settings → Privacy & Security, or record the microphone too."
    }
}

/// A line of live preview text.
public struct TBDPreviewLine: Sendable, Identifiable, Equatable {
    public enum Source: String, Sendable { case me, others }
    public let id = UUID()
    public let source: Source
    public let startMs: Int
    public let text: String
}

/// Records a meeting: microphone and system audio to separate crash-safe WAV tracks, with a
/// live transcript preview cut at speech boundaries (Silero VAD; energy fallback when the VAD
/// model is absent). The engines are fixed at start (`TBDMeetingSpeechPlan`): preview on the
/// live route, the transcript on the final route. `finalize` produces the stored transcript.
public final class TBDMeetingRecorder: @unchecked Sendable {
    public enum State: Equatable, Sendable { case idle, recording, paused }

    public let speech: TBDSpeechService
    private let microphone: TBDSharedMicrophone
    private let lock = NSLock()
    private var state: State = .idle
    private var manifest: TBDMeetingManifest?
    private var folder: URL?
    private var micWriter: TBDWAVWriter?
    private var systemWriter: TBDWAVWriter?
    private var micToken: TBDSharedMicrophone.Token?
    private var system: TBDSystemAudioCapture?
    private let micResampler = TBDMonoResampler()
    private var plan: TBDMeetingSpeechPlan?
    private var micFeed: AsyncStream<[Float]>.Continuation?
    private var systemFeed: AsyncStream<[Float]>.Continuation?
    private var feedTasks: [Task<Void, Never>] = []
    private var micLevel: Float = 0
    private var systemLevel: Float = 0
    private var source: TBDMeetingAudioSource = .microphoneAndSystem
    private var micMuted = false

    public var onPreview: (@Sendable (TBDPreviewLine) -> Void)?
    public var onWarning: (@Sendable (String) -> Void)?

    public init(speech: TBDSpeechService = .shared, microphone: TBDSharedMicrophone = .shared) {
        self.speech = speech
        self.microphone = microphone
    }

    public var currentState: State { lock.withLock { state } }
    /// Recorded (unpaused) time.
    public var elapsedMs: Int { lock.withLock { Int(recordedSeconds * 1000) } }
    public var levels: (mic: Float, system: Float) { lock.withLock { (micLevel, systemLevel) } }
    public var hasSystemAudio: Bool { lock.withLock { systemWriter != nil } }
    /// The sources this recording captures (fixed at start).
    public var audioSource: TBDMeetingAudioSource { lock.withLock { source } }
    public var isMicMuted: Bool { lock.withLock { micMuted } }
    /// The mute control works while a recording runs and the microphone is part of it.
    public var canMuteMic: Bool { lock.withLock { TBDMicMute.canMute(source: source, recording: state != .idle) } }

    /// Mutes or unmutes the microphone for this recording. The microphone stays open and the track keeps running,
    /// carrying silence while muted, so the two tracks stay aligned. Returns the state now in effect.
    @discardableResult
    public func setMicMuted(_ muted: Bool) -> Bool {
        lock.withLock {
            guard TBDMicMute.canMute(source: source, recording: state != .idle) else { return micMuted }
            micMuted = muted
            if muted { micLevel = 0 }
            return micMuted
        }
    }

    // Recording clock (excludes pauses); both tracks are padded against it so they stay aligned
    // across late starts, route changes and capture gaps.
    private var session: UUID?
    private var clockAccumulated: TimeInterval = 0
    private var clockStarted: Date?
    private var recordedSeconds: TimeInterval { clockAccumulated + (clockStarted.map { Date().timeIntervalSince($0) } ?? 0) }
    private func isCurrent(_ id: UUID) -> Bool { lock.withLock { session == id } }

    /// `source` picks the tracks: the microphone, system audio, or both. `startMuted` begins with the microphone
    /// muted (ignored when the microphone is not recorded).
    public func start(title: String, source: TBDMeetingAudioSource = .default, startMuted: Bool = false) async throws -> TBDMeetingManifest {
        if source.capturesMicrophone {
            guard await TBDSharedMicrophone.requestPermission() else { throw TBDSpeechError.microphoneDenied }
        }
        let id = tbdNewID()
        let folder = try TBDListeningPaths.ensure(TBDListeningPaths.meetings.appendingPathComponent(id, isDirectory: true))
        let plan = TBDMeetingSpeechPlan.resolve(live: speech.selection(for: .live), final: speech.selection(for: .final),
                                                previewEnabled: speech.preferences.meetingLivePreview && speech.isReady(.live))
        var manifest = TBDMeetingManifest(id: id, title: title, startedAt: Date(), state: .recording, durationMs: 0, transcriptionID: tbdNewID())
        manifest.finalEngine = plan.final
        try manifest.write(to: folder)
        let micWriter = source.capturesMicrophone ? try TBDWAVWriter(url: folder.appendingPathComponent("microphone.wav")) : nil
        let feeds = await makePreviewFeeds(plan)
        let current = UUID()
        do {
            try lock.withLock {
                guard state == .idle else { throw TBDSpeechError.busy("A meeting recording") }
                state = .recording
                session = current
                clockAccumulated = 0; clockStarted = Date()
                self.manifest = manifest; self.folder = folder; self.micWriter = micWriter; systemWriter = nil
                self.plan = plan
                self.source = source
                micMuted = TBDMicMute.startsMuted(setting: startMuted, source: source)
                micFeed = feeds?.mic; systemFeed = feeds?.system; feedTasks = feeds?.tasks ?? []
            }
        } catch {
            feeds?.mic.finish(); feeds?.system.finish()
            throw error
        }
        if source.capturesMicrophone {
            do {
                let token = try await microphone.subscribe(onInterruption: { [weak self] error in
                    self?.onWarning?("Microphone stopped: \(error.localizedDescription)")
                }) { [weak self] buffer in
                    guard let self else { return }
                    self.consumeMic(self.micResampler.convert(buffer))
                }
                // stop() may have run while subscribing: never leave the microphone on.
                guard lock.withLock({ () -> Bool in
                    guard session == current else { return false }
                    micToken = token
                    return true
                }) else {
                    await microphone.unsubscribe(token)
                    throw CancellationError()
                }
            } catch {
                let feeds = lock.withLock { () -> [AsyncStream<[Float]>.Continuation] in
                    guard session == current else { return [] }
                    state = .idle; session = nil; self.micWriter = nil; self.manifest = nil; self.folder = nil; self.plan = nil
                    micMuted = false; self.source = .default
                    defer { micFeed = nil; systemFeed = nil; feedTasks = [] }
                    return [micFeed, systemFeed].compactMap { $0 }
                }
                for feed in feeds { feed.finish() }
                try? micWriter?.close()
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        if source.capturesSystemAudio {
            let started = await startSystemAudio(folder: folder, session: current, warnOnFailure: source != .systemOnly)
            // System audio is the only track of this recording: without it there is nothing to record.
            if !started, source == .systemOnly {
                _ = try? await stop()
                try? FileManager.default.removeItem(at: folder)
                throw TBDMeetingStartError.systemAudioUnavailable
            }
        }
        return manifest
    }

    /// Starts the system track. Returns false when it could not start (the track is removed).
    private func startSystemAudio(folder: URL, session current: UUID, warnOnFailure: Bool) async -> Bool {
        let capture = TBDSystemAudioCapture()
        do {
            let writer = try TBDWAVWriter(url: folder.appendingPathComponent("system.wav"))
            lock.withLock { if session == current { systemWriter = writer; system = capture } }
            try await capture.start(handler: { [weak self] samples in self?.consumeSystem(samples) }, onStop: { [weak self] error in
                self?.onWarning?("System audio stopped: \(error.localizedDescription)")
            })
            if !isCurrent(current) { await capture.stop() }
            return true
        } catch {
            let writer = lock.withLock { () -> TBDWAVWriter? in
                guard session == current else { return nil }
                defer { systemWriter = nil; system = nil }
                return systemWriter
            }
            if let writer { try? writer.close(); try? FileManager.default.removeItem(at: writer.url) }
            if warnOnFailure, isCurrent(current) {
                onWarning?("Recording the microphone only. Allow Screen & System Audio Recording for TBD to include other participants.")
            }
            return false
        }
    }

    /// One chunker and one serial consumer per track (the chunker must see one caller at a time).
    /// Nil when the plan has no preview.
    private func makePreviewFeeds(_ plan: TBDMeetingSpeechPlan) async
        -> (mic: AsyncStream<[Float]>.Continuation, system: AsyncStream<[Float]>.Continuation, tasks: [Task<Void, Never>])? {
        guard let engine = plan.preview else { return nil }
        let vad = await TBDSileroVAD.loadIfDownloaded(modelsRoot: speech.modelsRoot)
        func chunker() -> any TBDLiveAudioChunking { vad.map { TBDSpeechBoundaryChunker(vad: $0) } ?? TBDEnergyChunker() }
        var tasks: [Task<Void, Never>] = []
        func feed(_ source: TBDPreviewLine.Source) -> AsyncStream<[Float]>.Continuation {
            let (stream, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
            let chunker = chunker()
            tasks.append(Task { [weak self] in
                for await samples in stream {
                    for chunk in await chunker.addSamples(samples) { self?.preview(chunk, source: source, engine: engine) }
                }
                if let last = await chunker.flush() { self?.preview(last, source: source, engine: engine) }
            })
            return continuation
        }
        let mic = feed(.me), system = feed(.others)
        return (mic, system, tasks)
    }

    /// Appends samples, first padding with silence when the track fell more than a second behind
    /// the clock. Returns what was written (for the preview feed, so its timeline matches the track).
    private func appendLocked(_ samples: [Float], to writer: TBDWAVWriter) -> [Float] {
        let expected = Int(recordedSeconds * 16_000)
        let gap = expected - writer.samplesWritten - samples.count
        var written = samples
        if gap > 16_000 {
            let silence = [Float](repeating: 0, count: gap)
            writer.append(silence)
            written = silence + samples
        }
        writer.append(samples)
        return written
    }

    private func consumeMic(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            guard state == .recording, let micWriter else { return }
            let (recorded, level) = TBDMicMute.apply(samples, muted: micMuted)
            micLevel = level
            let written = appendLocked(recorded, to: micWriter)
            micFeed?.yield(written)
        }
    }

    private func consumeSystem(_ samples: [Float]) {
        lock.withLock {
            guard state == .recording, let systemWriter else { return }
            systemLevel = TBDAudioLevel.normalized(samples)
            let written = appendLocked(samples, to: systemWriter)
            systemFeed?.yield(written)
        }
    }

    private func preview(_ chunk: TBDLiveChunker.Chunk, source: TBDPreviewLine.Source, engine: TBDEngineSelection) {
        let speech = self.speech
        Task { [weak self] in
            guard let transcript = try? await speech.transcribe(samples: chunk.samples, kind: .meetingLive, engine: engine) else { return }
            let text = transcript.trimmedText
            guard !text.isEmpty else { return }
            self?.onPreview?(TBDPreviewLine(source: source, startMs: chunk.startMs, text: text))
        }
    }

    /// Saves the notes into the recording's manifest (crash-safe). Blank text clears them.
    public func updateNotes(_ text: String) {
        lock.withLock {
            guard var manifest, let folder else { return }
            manifest.notes = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            self.manifest = manifest
            try? manifest.write(to: folder)
        }
    }

    /// The transcript id the recording will be saved under.
    public var currentTranscriptionID: String? { lock.withLock { manifest?.transcriptionID } }

    public func pause() {
        lock.withLock {
            guard state == .recording else { return }
            state = .paused
            clockAccumulated = recordedSeconds; clockStarted = nil
        }
    }

    public func resume() {
        lock.withLock {
            guard state == .paused else { return }
            state = .recording
            clockStarted = Date()
        }
    }

    /// Stops capture and closes the tracks. The folder stays recoverable until `finalize` succeeds.
    public func stop() async throws -> (manifest: TBDMeetingManifest, folder: URL) {
        let (token, system, manifest, folder) = lock.withLock { (micToken, self.system, self.manifest, self.folder) }
        guard var manifest, let folder else { throw TBDSpeechError.audioUnreadable("no meeting is recording") }
        // Trailing chunks of the live preview are flushed in the background.
        let feeds = lock.withLock { () -> [AsyncStream<[Float]>.Continuation] in
            defer { micFeed = nil; systemFeed = nil; feedTasks = []; plan = nil }
            return [micFeed, systemFeed].compactMap { $0 }
        }
        for feed in feeds { feed.finish() }
        if let token { await microphone.unsubscribe(token) }
        await system?.stop()
        let writers = lock.withLock { () -> [TBDWAVWriter] in
            defer {
                state = .idle; session = nil; micToken = nil; self.system = nil; micWriter = nil; systemWriter = nil
                self.manifest = nil; self.folder = nil; micLevel = 0; systemLevel = 0; clockStarted = nil
                micMuted = false; source = .default
            }
            return [micWriter, systemWriter].compactMap { $0 }
        }
        for writer in writers { try? writer.close() }
        manifest.durationMs = writers.first?.durationMs ?? 0
        manifest.state = .stopped
        try? manifest.write(to: folder)
        return (manifest, folder)
    }

    /// Transcribes both tracks, detects speakers on the system track and stores the merged transcript.
    /// Safe to call again on a recovered or failed meeting.
    @discardableResult
    /// Transcribes a meeting folder with the final engine fixed in its manifest. `currentFinalEngine`
    /// (retranscribe) switches the meeting to the final route chosen now and records it in the manifest.
    public func finalize(folder: URL, database: TBDListeningDatabase, keepAudio: Bool, currentFinalEngine: Bool = false,
                         progress: (@Sendable (String) -> Void)? = nil) async throws -> TBDTranscription {
        guard var manifest = TBDMeetingManifest.read(from: folder) else { throw TBDSpeechError.audioUnreadable("meeting manifest missing") }
        if currentFinalEngine { manifest.finalEngine = speech.selection(for: .final) }
        let mic = folder.appendingPathComponent("microphone.wav")
        let system = folder.appendingPathComponent("system.wav")
        let tracks = [mic, system].filter { FileManager.default.fileExists(atPath: $0.path) }
        for track in tracks { _ = try? TBDWAVWriter.repairHeader(at: track) }
        var item = (manifest.transcriptionID.flatMap { try? database.transcription(id: $0) })
            ?? TBDTranscription(id: manifest.transcriptionID ?? tbdNewID(), title: manifest.title, sourceKind: .meeting)
        item.createdAt = manifest.startedAt
        if item.userNotes == nil { item.userNotes = manifest.notes }
        item.status = .processing
        item.errorMessage = nil
        item.audioPaths = tracks.map(\.path)
        item.durationMs = tracks.map { TBDAudioDecoder.durationMs(of: $0) }.max() ?? manifest.durationMs
        manifest.transcriptionID = item.id
        try? manifest.write(to: folder)
        try database.save(item)
        do {
            var words: [TBDWord] = []
            var speakers: [TBDSpeaker] = []
            var language: String?
            var engine = ""
            if tracks.contains(mic) {
                progress?("Transcribing your microphone…")
                let result = try await speech.transcribe(url: mic, kind: .meetingFinal, engine: manifest.finalEngine)
                words += result.timedWords.map { var word = $0; word.speaker = "me"; return word }
                if !words.isEmpty { speakers.append(TBDSpeaker(id: "me", label: "Me")) }
                language = result.language; engine = result.engine
            }
            if tracks.contains(system), TBDAudioDecoder.durationMs(of: system) > 500 {
                progress?("Transcribing other participants…")
                let result = try await speech.transcribe(url: system, kind: .meetingFinal, engine: manifest.finalEngine)
                var others = result.timedWords.map { var word = $0; word.speaker = "S1"; return word }
                progress?("Detecting speakers…")
                if let turns = try? await speech.speakerTurns(system), !turns.isEmpty {
                    others = TBDTranscriptAssembler.attribute(others, turns: turns)
                }
                words = Self.removeEcho(mic: words, system: others) + others
                speakers += TBDTranscriptAssembler.speakers(in: others)
                language = language ?? result.language; engine = result.engine
            }
            words.sort { $0.start < $1.start }
            let transcript = TBDTranscript(text: TBDTranscriptAssembler.segments(words: words).map(\.text).joined(separator: " "),
                                           words: words, language: language, engine: engine, durationMs: item.durationMs)
            item.speakers = speakers
            try TBDTranscriber(speech: speech, database: database).apply(transcript, words: words, to: &item)
            item.speakers = speakers.filter { speaker in item.words.contains { $0.speaker == speaker.id } }
            item.status = .completed
            if !keepAudio {
                for track in tracks { try? FileManager.default.removeItem(at: track) }
                item.audioPaths = []
            }
            // The title and notes may have been edited while this ran.
            if let latest = try? database.transcription(id: item.id) {
                item.title = latest.title
                item.userNotes = latest.userNotes
            }
            try database.save(item)
            manifest.state = .done
            try? manifest.write(to: folder)
            return item
        } catch {
            item.status = error is CancellationError ? .cancelled : .failed
            item.errorMessage = error.localizedDescription
            try? database.save(item)
            throw error
        }
    }

    /// Drops microphone words that repeat a system-audio word at the same moment (speaker echo
    /// picked up by the microphone when no headphones are used).
    static func removeEcho(mic: [TBDWord], system: [TBDWord]) -> [TBDWord] {
        guard !system.isEmpty else { return mic }
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return mic.filter { word in
            let normalized = key(word.text)
            guard !normalized.isEmpty else { return true }
            return !system.contains { abs($0.start - word.start) < 1_500 && key($0.text) == normalized }
        }
    }

    /// Meeting folders that were interrupted (crash, quit) and still need a transcript.
    public static func pendingRecoveries(root: URL = TBDListeningPaths.meetings) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { folder in
            guard let manifest = TBDMeetingManifest.read(from: folder) else { return false }
            return manifest.state != .done
        }
    }
}
