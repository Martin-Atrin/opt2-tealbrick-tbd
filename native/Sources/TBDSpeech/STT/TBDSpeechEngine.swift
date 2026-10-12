import AVFoundation
import FluidAudio
import Foundation

/// Execution lane. Dictation gets its own lane so a long file never blocks push-to-talk.
public enum TBDLane: Hashable, Sendable { case interactive, background }

/// A loaded speech-to-text engine.
public protocol TBDSpeechEngine: AnyObject, Sendable {
    var kind: TBDSpeechEngineKind { get }
    /// Loads the model from disk. Never downloads: throws `modelNotDownloaded` instead.
    func prepare() async throws
    func transcribe(url: URL, lane: TBDLane, progress: (@Sendable (Double) -> Void)?) async throws -> TBDTranscript
    func transcribe(samples: [Float], lane: TBDLane) async throws -> TBDTranscript
    func unload() async
}

/// An engine with native streaming (Nemotron, Parakeet Unified): rolling partial text while audio
/// arrives. A live session holds the engine's interactive lane until it finishes or is cancelled.
/// Partials are display-only; the dictation result still comes from the recorded audio.
public protocol TBDStreamingSpeechEngine: TBDSpeechEngine {
    /// Starts a session. `language` is ignored by English-only builds.
    func beginLive(language: String?, onPartial: @escaping @Sendable (String) -> Void) async throws
    /// Feeds 16 kHz mono samples.
    func appendLive(_ samples: [Float]) async throws
    /// Flushes and returns the session's transcript.
    func finishLive() async throws -> TBDTranscript
    /// Ends the session without a result. Safe to call when no session is active.
    func cancelLive() async
}

enum TBDEngineSupport {
    /// Trailing silence added to dictation before the final pass so a last word that lands on
    /// the final frame is still decoded (donor issue #562).
    static let dictationTrailingSilenceSeconds = 0.5

    static func appendingTrailingSilence(_ samples: [Float], seconds: Double = dictationTrailingSilenceSeconds) -> [Float] {
        samples + [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    /// Wraps 16 kHz mono samples in a non-interleaved Float32 buffer (the streaming managers' input format).
    static func pcmBuffer(_ samples: ArraySlice<Float>) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))),
              let channel = buffer.floatChannelData else {
            throw TBDSpeechError.engineFailed("could not allocate an audio buffer")
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel[0].update(from: base, count: samples.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// Engine and FluidAudio errors as `TBDSpeechError`; cancellation passes through.
    static func map(_ error: Error) -> Error {
        if error is CancellationError || error is TBDSpeechError { return error }
        if let url = error as? URLError, url.code == .cancelled { return CancellationError() }
        return TBDSpeechError.engineFailed(error.localizedDescription)
    }

    /// Progress callback for FluidAudio downloads.
    static func progressHandler(_ report: (@Sendable (Double) -> Void)?) -> ProgressHandler? {
        report.map { report in { @Sendable value in report(value.fractionCompleted) } }
    }

    /// Whether every listed file or bundle exists under `folder`.
    static func filesExist(_ names: some Sequence<String>, in folder: URL) -> Bool {
        names.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
}

enum TBDWordTiming {
    /// Joins SentencePiece tokens ("▁hel", "lo") into words with averaged confidence.
    static func words(tokens: [(token: String, start: Double, end: Double, confidence: Float)]) -> [TBDWord] {
        var words: [TBDWord] = []
        var text = "", start = 0.0, end = 0.0
        var confidences: [Float] = []
        func flush() {
            guard !text.isEmpty else { return }
            let confidence = confidences.isEmpty ? 0 : Double(confidences.reduce(0, +) / Float(confidences.count))
            words.append(TBDWord(text: text, start: Int((start * 1000).rounded()), end: Int((end * 1000).rounded()), confidence: confidence))
            text = ""; confidences = []
        }
        for token in tokens {
            let normalized = token.token.replacingOccurrences(of: "▁", with: " ")
            let startsWord = normalized.first?.isWhitespace == true
            let piece = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { if startsWord { flush() }; continue }
            if startsWord || text.isEmpty {
                flush(); text = piece; start = token.start
            } else {
                text += piece
            }
            end = token.end
            confidences.append(token.confidence)
        }
        flush()
        return words
    }
}
