import Foundation

/// Cuts a live 16 kHz stream into speech chunks for preview transcription. Energy-based voice
/// activity: a chunk ends at a pause after at least `minimum` seconds, or at `maximum` seconds.
/// Silent chunks are discarded.
public struct TBDLiveChunker: Sendable {
    public struct Chunk: Sendable, Equatable {
        public let samples: [Float]
        public let startMs: Int
    }

    public let minimumSamples: Int
    public let maximumSamples: Int
    public let pauseSamples: Int
    public let silenceRMS: Float
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var consumed = 0

    public init(minimum: Double = 3, maximum: Double = 12, pause: Double = 0.5, silenceRMS: Float = 0.01) {
        minimumSamples = Int(minimum * 16_000); maximumSamples = Int(maximum * 16_000)
        pauseSamples = Int(pause * 16_000); self.silenceRMS = silenceRMS
    }

    public mutating func append(_ samples: [Float]) -> [Chunk] {
        buffer += samples
        var chunks: [Chunk] = []
        while let cut = cutPoint() {
            let piece = Array(buffer[..<cut])
            if let chunk = makeChunk(piece) { chunks.append(chunk) }
            buffer.removeFirst(cut)
            bufferStart += cut
        }
        return chunks
    }

    /// Emits whatever is buffered (end of recording).
    public mutating func flush() -> Chunk? {
        defer { bufferStart += buffer.count; buffer = [] }
        return buffer.count >= 8_000 ? makeChunk(buffer) : nil
    }

    private func cutPoint() -> Int? {
        if buffer.count >= maximumSamples { return maximumSamples }
        guard buffer.count >= minimumSamples + pauseSamples else { return nil }
        let tail = buffer[(buffer.count - pauseSamples)...]
        return TBDAudioLevel.rms(tail) < silenceRMS ? buffer.count : nil
    }

    private func makeChunk(_ samples: [Float]) -> Chunk? {
        guard TBDAudioLevel.rms(samples[...]) >= silenceRMS * 0.8 else { return nil }
        return Chunk(samples: samples, startMs: bufferStart / 16)
    }
}
