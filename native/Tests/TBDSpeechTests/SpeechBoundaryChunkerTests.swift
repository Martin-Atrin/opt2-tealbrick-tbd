import XCTest
@testable import TBDSpeech

/// Deterministic stand-in for Silero: a window is speech when its RMS is above 0.05. Speech ends
/// at the start of the first silent window. State: absolute samples seen × 2 + in-speech flag.
private struct EnergyVAD: TBDVoiceActivityDetecting {
    func makeStreamState() async -> TBDVADStreamState { TBDVADStreamState() }
    func process(_ window: [Float], state: TBDVADStreamState, config: TBDVADConfig) async throws -> (state: TBDVADStreamState, event: TBDVADEvent?) {
        let position = state.custom / 2
        let inSpeech = state.custom % 2 == 1
        let speech = TBDAudioLevel.rms(window[...]) > 0.05
        var event: TBDVADEvent?
        if speech, !inSpeech { event = .speechStart }
        if !speech, inSpeech { event = .speechEnd(sampleIndex: position) }
        return (TBDVADStreamState(custom: (position + window.count) * 2 + (speech ? 1 : 0)), event)
    }
}

private struct FailingVAD: TBDVoiceActivityDetecting {
    struct Failure: Error {}
    func makeStreamState() async -> TBDVADStreamState { TBDVADStreamState() }
    func process(_ window: [Float], state: TBDVADStreamState, config: TBDVADConfig) async throws -> (state: TBDVADStreamState, event: TBDVADEvent?) {
        throw Failure()
    }
}

final class SpeechBoundaryChunkerTests: XCTestCase {
    private func speech(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.3 * sin(Float($0) * 0.05) }
    }
    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

    /// Feeds in 100 ms pieces like a capture tap.
    private func feed(_ chunker: TBDSpeechBoundaryChunker, _ audio: [Float]) async -> [TBDLiveChunker.Chunk] {
        var out: [TBDLiveChunker.Chunk] = []
        var index = 0
        while index < audio.count {
            let end = min(index + 1_600, audio.count)
            out += await chunker.addSamples(Array(audio[index..<end]))
            index = end
        }
        return out
    }

    func testCutsAtSpeechEndsWithContiguousTimestamps() async {
        let chunker = TBDSpeechBoundaryChunker(vad: EnergyVAD())
        let chunks = await feed(chunker, speech(3) + silence(1) + speech(3) + silence(1))
        XCTAssertEqual(chunks.count, 2, "one chunk per utterance")
        XCTAssertEqual(chunks[0].startMs, 0)
        // The first cut lands on the first silent VAD window after 3 s (window grid of 4096).
        let firstEnd = chunks[0].startMs + chunks[0].samples.count / 16
        XCTAssertEqual(chunks[1].startMs, firstEnd, "chunks tile the recording: no gaps, no overlap")
        XCTAssertGreaterThanOrEqual(chunks[0].samples.count, 3 * 16_000)
        XCTAssertLessThan(chunks[0].samples.count, 3 * 16_000 + 4_096 + 1)
        let diagnostics = await chunker.diagnostics
        XCTAssertEqual(diagnostics.speechEndEvents, 2)
        XCTAssertEqual(diagnostics.forceEmits, 0)
    }

    func testShortUtterancesMergeUntilTheMinimum() async {
        let chunker = TBDSpeechBoundaryChunker(vad: EnergyVAD())
        // 1 s of speech is below the 2 s minimum: it is kept and extended by the next utterance.
        let chunks = await feed(chunker, speech(1) + silence(0.6) + speech(2) + silence(1))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].startMs, 0)
        XCTAssertGreaterThan(chunks[0].samples.count, 3 * 16_000)
    }

    func testLongSpeechIsForceCutAtTenSecondsWithTailOverlap() async {
        let chunker = TBDSpeechBoundaryChunker(vad: EnergyVAD())
        let chunks = await feed(chunker, speech(25))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].samples.count, TBDSpeechBoundaryChunker.maxChunkSamples)
        XCTAssertEqual(chunks[1].startMs, (TBDSpeechBoundaryChunker.maxChunkSamples - TBDSpeechBoundaryChunker.forceEmitTailOverlap) / 16,
                       "the next chunk re-includes 0.25 s after a forced cut")
        let tail = await chunker.flush()
        XCTAssertNotNil(tail, "the remaining speech is emitted on stop")
        let forced = await chunker.diagnostics.forceEmits
        XCTAssertEqual(forced, 2)
    }

    func testSilenceIsDroppedAndNeverEmitted() async {
        let chunker = TBDSpeechBoundaryChunker(vad: EnergyVAD())
        let chunks = await feed(chunker, silence(30))
        XCTAssertTrue(chunks.isEmpty)
        let flushed = await chunker.flush()
        XCTAssertNil(flushed)
        let dropped = await chunker.diagnostics.droppedSilenceWindows
        XCTAssertGreaterThan(dropped, 0)
        // Speech after a long silence keeps its true position; at most 10 s of the silence
        // before it is kept as leading context.
        let later = await feed(chunker, speech(3) + silence(1))
        XCTAssertFalse(later.isEmpty)
        XCTAssertGreaterThanOrEqual(later[0].startMs, 30_000 - 10_000 - 256)
        let end = later.last.map { $0.startMs + $0.samples.count / 16 } ?? 0
        XCTAssertGreaterThanOrEqual(end, 33_000, "the speech at 30–33 s is inside the emitted audio")
    }

    func testOneLargeIngestOnlyActsOnExaminedAudio() async {
        let chunker = TBDSpeechBoundaryChunker(vad: EnergyVAD())
        let chunks = await chunker.addSamples(speech(3) + silence(1) + speech(12))
        XCTAssertEqual(chunks.first?.startMs, 0)
        XCTAssertGreaterThanOrEqual(chunks.count, 2, "speech end, then a forced cut")
        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.1.startMs, pair.0.startMs + pair.0.samples.count / 16)
        }
    }

    func testFlushEmitsAShortSpokenTail() async {
        let chunker = TBDSpeechBoundaryChunker(vad: EnergyVAD())
        let none = await feed(chunker, speech(1.2))
        XCTAssertTrue(none.isEmpty)
        let tail = await chunker.flush()
        XCTAssertEqual(tail?.startMs, 0)
        XCTAssertGreaterThanOrEqual(tail?.samples.count ?? 0, TBDSpeechBoundaryChunker.flushMinSamples)
    }

    func testRepeatedVADErrorsFallBackToFixedWindows() async {
        let chunker = TBDSpeechBoundaryChunker(vad: FailingVAD())
        let chunks = await feed(chunker, speech(12))
        let diagnostics = await chunker.diagnostics
        XCTAssertTrue(diagnostics.fellBackToFixed)
        XCTAssertEqual(diagnostics.vadErrors, TBDSpeechBoundaryChunker.maxConsecutiveVADErrors)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.map(\.startMs), [0, 4_000], "5 s windows with 1 s overlap")
        XCTAssertTrue(chunks.allSatisfy { $0.samples.count == TBDSpeechBoundaryChunker.fixedWindow })
    }

    func testEnergyFallbackChunkerKeepsWorking() async {
        let chunker = TBDEnergyChunker()
        var chunks = await chunker.addSamples(speech(4) + silence(0.6))
        XCTAssertEqual(chunks.count, 1)
        chunks = await chunker.addSamples(silence(13))
        XCTAssertTrue(chunks.isEmpty)
    }

    func testSileroLoaderReturnsNilWithoutTheModel() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-vad-\(UUID().uuidString)")
        let vad = await TBDSileroVAD.loadIfDownloaded(modelsRoot: root)
        XCTAssertNil(vad, "never downloads; meetings fall back to energy chunking")
    }
}
