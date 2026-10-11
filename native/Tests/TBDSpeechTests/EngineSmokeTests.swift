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
