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

/// A line of live preview text.
public struct TBDPreviewLine: Sendable, Identifiable, Equatable {
    public enum Source: String, Sendable { case me, others }
    public let id = UUID()
    public let source: Source
    public let startMs: Int
    public let text: String
}

/// Records a meeting: microphone and system audio to separate crash-safe WAV tracks, with a
/// live transcript preview from VAD-guided chunks. `finalize` produces the stored transcript.
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
    private var micChunker = TBDLiveChunker()
    private var systemChunker = TBDLiveChunker()
    private var micLevel: Float = 0
    private var systemLevel: Float = 0

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

    // Recording clock (excludes pauses); both tracks are padded against it so they stay aligned
    // across late starts, route changes and capture gaps.
    private var session: UUID?
    private var clockAccumulated: TimeInterval = 0
    private var clockStarted: Date?
    private var recordedSeconds: TimeInterval { clockAccumulated + (clockStarted.map { Date().timeIntervalSince($0) } ?? 0) }
    private func isCurrent(_ id: UUID) -> Bool { lock.withLock { session == id } }

    public func start(title: String) async throws -> TBDMeetingManifest {
        guard await TBDSharedMicrophone.requestPermission() else { throw TBDSpeechError.microphoneDenied }
        let id = tbdNewID()
        let folder = try TBDListeningPaths.ensure(TBDListeningPaths.meetings.appendingPathComponent(id, isDirectory: true))
        let manifest = TBDMeetingManifest(id: id, title: title, startedAt: Date(), state: .recording, durationMs: 0, transcriptionID: tbdNewID())
        try manifest.write(to: folder)
        let micWriter = try TBDWAVWriter(url: folder.appendingPathComponent("microphone.wav"))
        let current = UUID()
        try lock.withLock {
            guard state == .idle else { throw TBDSpeechError.busy("A meeting recording") }
            state = .recording
            session = current
            clockAccumulated = 0; clockStarted = Date()
            self.manifest = manifest; self.folder = folder; self.micWriter = micWriter; systemWriter = nil
            micChunker = TBDLiveChunker(); systemChunker = TBDLiveChunker()
        }
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
            lock.withLock {
                if session == current { state = .idle; session = nil; self.micWriter = nil; self.manifest = nil; self.folder = nil }
            }
            try? micWriter.close()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        await startSystemAudio(folder: folder, session: current)
        return manifest
    }

    private func startSystemAudio(folder: URL, session current: UUID) async {
        let capture = TBDSystemAudioCapture()
        do {
            let writer = try TBDWAVWriter(url: folder.appendingPathComponent("system.wav"))
            lock.withLock { if session == current { systemWriter = writer; system = capture } }
            try await capture.start(handler: { [weak self] samples in self?.consumeSystem(samples) }, onStop: { [weak self] error in
                self?.onWarning?("System audio stopped: \(error.localizedDescription)")
            })
            if !isCurrent(current) { await capture.stop() }
        } catch {
            let writer = lock.withLock { () -> TBDWAVWriter? in
                guard session == current else { return nil }
                defer { systemWriter = nil; system = nil }
                return systemWriter
            }
            if let writer { try? writer.close(); try? FileManager.default.removeItem(at: writer.url) }
            if isCurrent(current) {
                onWarning?("Recording the microphone only. Allow Screen & System Audio Recording for TBD to include other participants.")
            }
        }
    }

    /// Appends samples, first padding with silence when the track fell more than a second behind the clock.
    private func appendLocked(_ samples: [Float], to writer: TBDWAVWriter, chunker: inout TBDLiveChunker) -> [TBDLiveChunker.Chunk] {
        var chunks: [TBDLiveChunker.Chunk] = []
        let expected = Int(recordedSeconds * 16_000)
        let gap = expected - writer.samplesWritten - samples.count
        if gap > 16_000 {
            let silence = [Float](repeating: 0, count: gap)
            writer.append(silence)
            chunks += chunker.append(silence)
        }
        writer.append(samples)
        return chunks + chunker.append(samples)
    }

    private func consumeMic(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let chunks: [TBDLiveChunker.Chunk] = lock.withLock {
            guard state == .recording, let micWriter else { return [] }
            micLevel = TBDAudioLevel.normalized(samples)
            return appendLocked(samples, to: micWriter, chunker: &micChunker)
        }
        for chunk in chunks { preview(chunk, source: .me) }
    }

    private func consumeSystem(_ samples: [Float]) {
        let chunks: [TBDLiveChunker.Chunk] = lock.withLock {
            guard state == .recording, let systemWriter else { return [] }
            systemLevel = TBDAudioLevel.normalized(samples)
            return appendLocked(samples, to: systemWriter, chunker: &systemChunker)
        }
        for chunk in chunks { preview(chunk, source: .others) }
    }

    private func preview(_ chunk: TBDLiveChunker.Chunk, source: TBDPreviewLine.Source) {
        let speech = self.speech
        Task { [weak self] in
            guard let transcript = try? await speech.transcribe(samples: chunk.samples, kind: .meetingLive) else { return }
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
        if let token { await microphone.unsubscribe(token) }
        await system?.stop()
        let writers = lock.withLock { () -> [TBDWAVWriter] in
            defer {
                state = .idle; session = nil; micToken = nil; self.system = nil; micWriter = nil; systemWriter = nil
                self.manifest = nil; self.folder = nil; micLevel = 0; systemLevel = 0; clockStarted = nil
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
    public func finalize(folder: URL, database: TBDListeningDatabase, keepAudio: Bool,
                         progress: (@Sendable (String) -> Void)? = nil) async throws -> TBDTranscription {
        guard var manifest = TBDMeetingManifest.read(from: folder) else { throw TBDSpeechError.audioUnreadable("meeting manifest missing") }
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
                let result = try await speech.transcribe(url: mic, kind: .meetingFinal)
                words += result.words.map { var word = $0; word.speaker = "me"; return word }
                if !result.words.isEmpty { speakers.append(TBDSpeaker(id: "me", label: "Me")) }
                language = result.language; engine = result.engine
            }
            if tracks.contains(system), TBDAudioDecoder.durationMs(of: system) > 500 {
                progress?("Transcribing other participants…")
                let result = try await speech.transcribe(url: system, kind: .meetingFinal)
                var others = result.words.map { var word = $0; word.speaker = "S1"; return word }
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
    public static func pendingRecoveries() -> [URL] {
        let root = TBDListeningPaths.meetings
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { folder in
            guard let manifest = TBDMeetingManifest.read(from: folder) else { return false }
            return manifest.state != .done
        }
    }
}
