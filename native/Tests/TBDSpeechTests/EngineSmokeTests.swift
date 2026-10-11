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
        let engine = TBDParakeetEngine(choice: .parakeetV3)
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
        let defaults = UserDefaults(suiteName: "tbd.tests.\(UUID().uuidString)")!
        let speech = TBDSpeechService(preferences: TBDListeningPreferences(defaults: defaults))
        let item = try await TBDTranscriber(speech: speech, database: database).transcribe(file: fixture)
        XCTAssertEqual(item.status, .completed)
        XCTAssertGreaterThan(item.durationMs, 1000)
        XCTAssertFalse(item.segments.isEmpty)
        XCTAssertEqual(try database.transcriptions(matching: "meeting").first?.id, item.id)
        print("TRANSCRIBER_SMOKE: speakers=\(item.speakers.map(\.label)) segments=\(item.segments.count) text=\(item.text)")
        await speech.shutdown()
    }
}
