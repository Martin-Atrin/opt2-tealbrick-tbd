import Foundation

/// Cuts a live 16 kHz stream into chunks for preview transcription.
public protocol TBDLiveAudioChunking: Actor {
    func addSamples(_ samples: [Float]) async -> [TBDLiveChunker.Chunk]
    /// Emits what is buffered (end of recording).
    func flush() async -> TBDLiveChunker.Chunk?
}

/// The energy chunker behind the chunking protocol: the fallback when the VAD model is not
/// downloaded or fails to load.
public actor TBDEnergyChunker: TBDLiveAudioChunking {
    private var chunker = TBDLiveChunker()
    public init() {}
    public func addSamples(_ samples: [Float]) -> [TBDLiveChunker.Chunk] { chunker.append(samples) }
    public func flush() -> TBDLiveChunker.Chunk? { chunker.flush() }
}

/// Counters for tests (no audio, no text).
struct TBDChunkingDiagnostics: Sendable, Equatable {
    var chunksEmitted = 0
    var speechEndEvents = 0
    var forceEmits = 0
    var droppedSilenceWindows = 0
    var vadErrors = 0
    var fellBackToFixed = false
}

/// Live-preview chunker that cuts at voice-activity speech boundaries (ported from the donor's
/// speech-boundary chunker).
///
/// - Contiguous sample accounting: chunks tile the recording, so `lastEmittedSample` is always
///   the absolute index of `buffer[0]` and every chunk's `startMs` is its true position.
/// - Lockstep buffering: incoming samples are staged in `pendingVAD` and move into `buffer` only
///   once fed to VAD in exact 4096-sample windows, so force-emit and silence-drop decisions never
///   act on audio VAD has not examined.
/// - Silence between utterances becomes leading silence of the next chunk. The only overlap is a
///   0.25 s tail re-fed after a forced (10 s) cut, which lands mid-word.
/// - Three consecutive VAD errors switch to fixed 5 s windows with 1 s overlap for the rest of
///   the session, keeping the same sample counters so timestamps stay monotonic.
///
/// One caller at a time: methods mutate state across the VAD `await`, and actors are reentrant.
public actor TBDSpeechBoundaryChunker: TBDLiveAudioChunking {
    static let sampleRate = 16_000
    /// FluidAudio `VadManager.chunkSize`; VAD state advances by the count passed, so windows are exact.
    static let vadWindow = 4_096
    static let minChunkSamples = 2 * sampleRate
    static let maxChunkSamples = 10 * sampleRate
    static let forceEmitTailOverlap = sampleRate / 4
    static let flushMinSamples = sampleRate / 2
    static let fixedWindow = 5 * sampleRate
    static let fixedOverlap = 1 * sampleRate
    static let fixedFlushMinimum = 8_000
    static let maxConsecutiveVADErrors = 3

    private let vad: any TBDVoiceActivityDetecting
    private let config: TBDVADConfig
    private var buffer: [Float] = []
    private var pendingVAD: [Float] = []
    private var lastEmittedSample = 0
    private var sawSpeechSinceLastEmit = false
    private var vadState: TBDVADStreamState?
    private var consecutiveVADErrors = 0
    private var fellBackToFixed = false
    private var diag = TBDChunkingDiagnostics()

    public init(vad: any TBDVoiceActivityDetecting, config: TBDVADConfig = .default) {
        self.vad = vad
        self.config = config
    }

    var diagnostics: TBDChunkingDiagnostics { diag }

    public func addSamples(_ samples: [Float]) async -> [TBDLiveChunker.Chunk] {
        guard !samples.isEmpty else { return [] }
        if fellBackToFixed {
            buffer.append(contentsOf: samples)
            return drainFixed()
        }
        pendingVAD.append(contentsOf: samples)
        if vadState == nil { vadState = await vad.makeStreamState() }

        var emitted: [TBDLiveChunker.Chunk] = []
        while pendingVAD.count >= Self.vadWindow {
            let window = Array(pendingVAD.prefix(Self.vadWindow))
            pendingVAD.removeFirst(Self.vadWindow)
            // Into the emittable buffer first: a speech-end cut from this window needs its audio.
            buffer.append(contentsOf: window)
            await process(window, into: &emitted)
            if fellBackToFixed {
                buffer.append(contentsOf: pendingVAD)
                pendingVAD.removeAll()
                emitted.append(contentsOf: drainFixed())
                return emitted
            }
            if let forced = maybeForceEmitOrDropSilence() { emitted.append(forced) }
        }
        return emitted
    }

    public func flush() async -> TBDLiveChunker.Chunk? {
        if fellBackToFixed { return flushFixed() }
        // Feed the sub-window tail so a speech end in the last < 256 ms is still recognised.
        if !pendingVAD.isEmpty, let state = vadState {
            let tail = pendingVAD
            pendingVAD.removeAll()
            buffer.append(contentsOf: tail)
            if let result = try? await vad.process(tail, state: state, config: config) {
                vadState = result.state
                switch result.event {
                case .speechStart: sawSpeechSinceLastEmit = true
                case .speechEnd(let cut):
                    diag.speechEndEvents += 1
                    if let chunk = emitAtSpeechEnd(cutSample: cut) { return chunk }
                case nil: break
                }
            }
        }
        guard sawSpeechSinceLastEmit, buffer.count >= Self.flushMinSamples else { return nil }
        return makeChunk(length: buffer.count, tailOverlap: 0)
    }

    private func process(_ window: [Float], into emitted: inout [TBDLiveChunker.Chunk]) async {
        guard let state = vadState else { return }
        do {
            let result = try await vad.process(window, state: state, config: config)
            vadState = result.state
            consecutiveVADErrors = 0
            switch result.event {
            case .speechStart: sawSpeechSinceLastEmit = true
            case .speechEnd(let cut):
                diag.speechEndEvents += 1
                if let chunk = emitAtSpeechEnd(cutSample: cut) { emitted.append(chunk) }
            case nil: break
            }
        } catch {
            diag.vadErrors += 1
            consecutiveVADErrors += 1
            if consecutiveVADErrors >= Self.maxConsecutiveVADErrors {
                fellBackToFixed = true
                diag.fellBackToFixed = true
            }
        }
    }

    /// Emits `[lastEmittedSample, cutSample)` when speech ends. The cut is absolute and can land
    /// before the current ingest position.
    private func emitAtSpeechEnd(cutSample: Int) -> TBDLiveChunker.Chunk? {
        guard sawSpeechSinceLastEmit else { return nil }
        let length = cutSample - lastEmittedSample
        if length <= 0 {
            // A force-emit already passed where speech ended: speech is over, so clear the flag
            // (otherwise trailing silence would be force-emitted every 10 s).
            sawSpeechSinceLastEmit = false
            return nil
        }
        // Too short: keep buffering and let the next speech end extend the segment.
        guard length >= Self.minChunkSamples, length <= buffer.count else { return nil }
        let chunk = makeChunk(length: length, tailOverlap: 0)
        sawSpeechSinceLastEmit = false
        return chunk
    }

    /// At the 10 s cap: cut (keeping a tail for context) when there was speech, otherwise drop
    /// the silence down to one window so memory and latency stay bounded.
    private func maybeForceEmitOrDropSilence() -> TBDLiveChunker.Chunk? {
        guard buffer.count >= Self.maxChunkSamples else { return nil }
        guard sawSpeechSinceLastEmit else {
            let drop = buffer.count - Self.vadWindow
            if drop > 0 {
                buffer.removeFirst(drop)
                lastEmittedSample += drop
                diag.droppedSilenceWindows += 1
            }
            return nil
        }
        diag.forceEmits += 1
        return makeChunk(length: Self.maxChunkSamples, tailOverlap: Self.forceEmitTailOverlap)
    }

    /// Emits `buffer[0..<length]` and advances by `length - tailOverlap`. Times come from sample counters only.
    private func makeChunk(length: Int, tailOverlap: Int) -> TBDLiveChunker.Chunk {
        let startMs = lastEmittedSample * 1000 / Self.sampleRate
        let samples = Array(buffer.prefix(length))
        let advance = max(0, length - tailOverlap)
        buffer.removeFirst(min(advance, buffer.count))
        lastEmittedSample += advance
        diag.chunksEmitted += 1
        return TBDLiveChunker.Chunk(samples: samples, startMs: startMs)
    }

    private func drainFixed() -> [TBDLiveChunker.Chunk] {
        var out: [TBDLiveChunker.Chunk] = []
        while buffer.count >= Self.fixedWindow { out.append(makeChunk(length: Self.fixedWindow, tailOverlap: Self.fixedOverlap)) }
        return out
    }

    private func flushFixed() -> TBDLiveChunker.Chunk? {
        guard buffer.count >= Self.fixedFlushMinimum else {
            lastEmittedSample += buffer.count
            buffer = []
            return nil
        }
        return makeChunk(length: buffer.count, tailOverlap: 0)
    }
}
