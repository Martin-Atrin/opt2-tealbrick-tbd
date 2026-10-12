import XCTest
@testable import TBDSpeech

/// Fake streaming engine: echoes the number of samples received as the partial.
private actor FakeStreamingEngine: TBDStreamingSpeechEngine {
    nonisolated let kind = TBDSpeechEngineKind.nemotronEnglish
    private var received = 0
    private var onPartial: (@Sendable (String) -> Void)?
    private(set) var cancelled = false
    private(set) var language: String?

    func prepare() async throws {}
    func transcribe(url: URL, lane: TBDLane, progress: (@Sendable (Double) -> Void)?) async throws -> TBDTranscript { TBDTranscript(text: "", engine: "fake") }
    func transcribe(samples: [Float], lane: TBDLane) async throws -> TBDTranscript { TBDTranscript(text: "", engine: "fake") }
    func unload() async {}
    func beginLive(language: String?, onPartial: @escaping @Sendable (String) -> Void) async throws {
        self.language = language
        self.onPartial = onPartial
    }
    func appendLive(_ samples: [Float]) async throws {
        received += samples.count
        onPartial?("heard \(received)")
    }
    func finishLive() async throws -> TBDTranscript { TBDTranscript(text: "heard \(received)", engine: "fake") }
    func cancelLive() async { cancelled = true }
}

/// Fake batch engine: reports the window length it was asked to transcribe.
private final class FakeBatchEngine: TBDSpeechEngine, @unchecked Sendable {
    let kind = TBDSpeechEngineKind.parakeetV3
    let lock = NSLock()
    var windows: [Int] = []
    func prepare() async throws {}
    func transcribe(url: URL, lane: TBDLane, progress: (@Sendable (Double) -> Void)?) async throws -> TBDTranscript { TBDTranscript(text: "", engine: "fake") }
    func transcribe(samples: [Float], lane: TBDLane) async throws -> TBDTranscript {
        lock.withLock { windows.append(samples.count) }
        return TBDTranscript(text: " window \(samples.count) ", engine: "fake")
    }
    func unload() async {}
}

@MainActor
private final class PartialSink {
    var values: [String] = []
}

final class LivePreviewTests: XCTestCase {
    func testModesFollowCapabilities() {
        XCTAssertEqual(TBDLivePreview.mode(for: .nemotronMultilingual), .streaming)
        XCTAssertEqual(TBDLivePreview.mode(for: .parakeetUnified), .streaming)
        XCTAssertEqual(TBDLivePreview.mode(for: .parakeetV3), .tail)
        XCTAssertEqual(TBDLivePreview.mode(for: .parakeetV2), .tail)
        XCTAssertNil(TBDLivePreview.mode(for: .cohere))
        XCTAssertNil(TBDLivePreview.mode(for: .whisper))
    }

    func testTailWindowKeepsTheNewestSamples() {
        var window = TBDTailWindow(capacity: 10)
        window.append(Array(repeating: 1, count: 6))
        XCTAssertEqual(window.samples.count, 6)
        window.append((0..<30).map(Float.init))
        XCTAssertEqual(window.samples, (20..<30).map(Float.init))
        window.append([99])
        XCTAssertEqual(window.samples.count, 10)
        XCTAssertEqual(window.samples.last, 99)
    }

    func testStreamingPreviewDeliversPartialsInOrderAndReleasesTheLane() async throws {
        let sink = await PartialSink()
        let engine = FakeStreamingEngine()
        let preview = TBDLivePreview { text in sink.values.append(text) }
        // Samples that arrive before the engine attaches are buffered, not lost.
        preview.append([Float](repeating: 0.1, count: 1_600))
        let ended = expectation(description: "released")
        XCTAssertTrue(preview.start(engine: engine, mode: .streaming, language: "de") { ended.fulfill() })
        for _ in 0..<4 { preview.append([Float](repeating: 0.1, count: 1_600)) }
        try await Task.sleep(for: .milliseconds(200))
        await preview.stop()
        await fulfillment(of: [ended], timeout: 2)
        let values = await sink.values
        XCTAssertEqual(values.last, "heard 8000", "every sample reached the engine")
        let cancelled = await engine.cancelled
        XCTAssertTrue(cancelled, "the live session is ended so the final pass can use the lane")
        let language = await engine.language
        XCTAssertEqual(language, "de")
        XCTAssertFalse(preview.start(engine: engine, mode: .streaming, language: nil) {}, "a stopped preview cannot restart")
    }

    func testTailPreviewTranscribesTheRecentWindowOncePerInterval() async throws {
        let sink = await PartialSink()
        let engine = FakeBatchEngine()
        let preview = TBDLivePreview { text in sink.values.append(text) }
        XCTAssertTrue(preview.start(engine: engine, mode: .tail, language: nil) {})
        // 20 s of audio delivered over ~1.3 s: at most two passes, each on ≤ 15 s.
        for _ in 0..<20 {
            preview.append([Float](repeating: 0.1, count: 16_000))
            try await Task.sleep(for: .milliseconds(65))
        }
        await preview.stop()
        let windows = engine.lock.withLock { engine.windows }
        XCTAssertFalse(windows.isEmpty)
        XCTAssertLessThanOrEqual(windows.count, 2)
        XCTAssertTrue(windows.allSatisfy { $0 <= TBDLivePreview.tailWindowSamples })
        let values = await sink.values
        XCTAssertEqual(values.last, "window \(windows.last!)", "partials are trimmed")
    }
}
