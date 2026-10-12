import XCTest
@testable import TBDSpeech

/// Transcribes the repository fixture with Parakeet v3. Skips when the model is not downloaded;
/// tests never download models.
final class EngineSmokeTests: XCTestCase {
    func testParakeetTranscribesFixture() async throws {
        let manager = TBDModelManager()
        try XCTSkipUnless(manager.isDownloaded(.parakeetV3), "Parakeet v3 is not downloaded")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/fixtures/tbd-speech.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "fixture missing")
        let engine = TBDParakeetEngine(kind: .parakeetV3)
        let transcript = try await engine.transcribe(url: fixture, lane: .background, progress: nil)
        XCTAssertFalse(transcript.trimmedText.isEmpty)
        XCTAssertFalse(transcript.words.isEmpty)
        let samples = try TBDAudioDecoder.samples(from: fixture)
        let dictation = try await engine.transcribe(samples: samples, lane: .interactive)
        XCTAssertFalse(dictation.trimmedText.isEmpty)
        print("ENGINE_SMOKE_TEXT: \(transcript.trimmedText)")
        await engine.unload()
    }
}

/// File pipeline end to end (decode → transcribe → diarize → store). Skips without models.
final class TranscriberSmokeTests: XCTestCase {
    func testTranscribesFileIntoLibrary() async throws {
        try XCTSkipUnless(TBDModelManager().isDownloaded(.parakeetV3), "Parakeet v3 is not downloaded")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/fixtures/tbd-speech.aiff")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "fixture missing")
        let database = try TBDListeningDatabase(inMemory: ())
        try database.save(TBDCustomWord(word: "desktop companion", replacement: "Desktop Companion"))
        // Read-only defaults: engine and speaker detection fall back to their defaults; nothing is written.
        let speech = TBDSpeechService(preferences: TBDListeningPreferences(defaults: .standard))
        let item = try await TBDTranscriber(speech: speech, database: database).transcribe(file: fixture)
        XCTAssertEqual(item.status, .completed)
        XCTAssertGreaterThan(item.durationMs, 1000)
        XCTAssertFalse(item.segments.isEmpty)
        XCTAssertEqual(try database.transcriptions(matching: "meeting").first?.id, item.id)
        print("TRANSCRIBER_SMOKE: speakers=\(item.speakers.map(\.label)) segments=\(item.segments.count) text=\(item.text)")
        await speech.shutdown()
    }
}

/// Every new engine on the fixture, batch and (for streaming engines) a live session fed in
/// 100 ms pieces. Each skips unless its model is in TBD_LISTENING_MODELS (or the default folder).
final class NewEngineSmokeTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/fixtures/tbd-speech.wav")
    }

    private func run(_ kind: TBDSpeechEngineKind, language: String? = nil) async throws {
        try XCTSkipUnless(TBDModelManager().isDownloaded(engine: kind), "\(kind.displayName) is not downloaded")
        let engine = TBDSpeechService.makeEngine(TBDEngineSelection(kind: kind, language: language), modelsRoot: TBDListeningPaths.models)
        let transcript = try await engine.transcribe(url: fixture, lane: .background, progress: nil)
        print("ENGINE_SMOKE_\(kind.rawValue): \(transcript.trimmedText)")
        XCTAssertTrue(transcript.trimmedText.lowercased().contains("meeting"), transcript.text)
        XCTAssertEqual(transcript.words.isEmpty, !kind.capabilities.wordTimestamps)
        let samples = try TBDAudioDecoder.samples(from: fixture)
        let dictation = try await engine.transcribe(samples: samples, lane: .interactive)
        XCTAssertFalse(dictation.trimmedText.isEmpty)
        if let streaming = engine as? any TBDStreamingSpeechEngine {
            let partials = NSLockedValue<[String]>([])
            try await streaming.beginLive(language: language) { text in partials.withLock { $0.append(text) } }
            var index = 0
            while index < samples.count {
                let end = min(index + 1_600, samples.count)
                try await streaming.appendLive(Array(samples[index..<end]))
                index = end
            }
            let final = try await streaming.finishLive()
            let seen = partials.withLock { $0 }
            print("ENGINE_SMOKE_\(kind.rawValue)_LIVE: partials=\(seen.count) last=\(seen.last ?? "") final=\(final.trimmedText)")
            XCTAssertFalse(seen.isEmpty, "partials arrive while streaming")
            XCTAssertFalse(final.trimmedText.isEmpty)
        }
        await engine.unload()
    }

    func testParakeetUnified() async throws { try await run(.parakeetUnified) }
    func testNemotronEnglish() async throws { try await run(.nemotronEnglish) }
    func testNemotronMultilingual() async throws { try await run(.nemotronMultilingual, language: "en") }
    func testCohere() async throws { try await run(.cohere) }
}
