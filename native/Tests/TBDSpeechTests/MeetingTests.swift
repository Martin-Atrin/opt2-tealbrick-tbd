import XCTest
@testable import TBDSpeech

final class MeetingTests: XCTestCase {
    private func tone(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 0.07) }
    }

    func testLiveChunkerCutsAtPauses() {
        var chunker = TBDLiveChunker()
        XCTAssertTrue(chunker.append(tone(2)).isEmpty, "too short to cut")
        let chunks = chunker.append(tone(2) + [Float](repeating: 0, count: 9_600))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.startMs, 0)
        let next = chunker.append(tone(13))
        XCTAssertEqual(next.count, 1, "forced cut at 12 s")
        XCTAssertEqual(next.first?.startMs, 4_600)
        XCTAssertNotNil(chunker.flush())
    }

    func testLiveChunkerDropsSilence() {
        var chunker = TBDLiveChunker()
        XCTAssertTrue(chunker.append([Float](repeating: 0, count: 16_000 * 13)).isEmpty)
        XCTAssertNil(chunker.flush())
    }

    func testEchoRemoval() {
        let mic = [TBDWord(text: "Hello,", start: 1000, end: 1200), TBDWord(text: "mine", start: 5000, end: 5200)]
        let system = [TBDWord(text: "hello", start: 1100, end: 1300, speaker: "S1")]
        XCTAssertEqual(TBDMeetingRecorder.removeEcho(mic: mic, system: system).map(\.text), ["mine"])
    }

    /// Simulates a crash mid-meeting, then recovers: headers repaired, both tracks transcribed,
    /// echo removed, transcript stored, manifest marked done. Skips without the model.
    func testRecoveredMeetingIsFinalized() async throws {
        try XCTSkipUnless(TBDModelManager().isDownloaded(.parakeetV3), "Parakeet v3 is not downloaded")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/fixtures/tbd-speech.wav")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["microphone.wav", "system.wav"] {
            let track = folder.appendingPathComponent(name)
            try await TBDAudioDecoder.decodeToWAV(fixture, destination: track)
            let handle = try FileHandle(forWritingTo: track)
            try handle.seek(toOffset: 40); handle.write(Data(count: 4))
            try handle.close()
        }
        try TBDMeetingManifest(id: "m1", title: "Crash test", startedAt: Date(), state: .recording, durationMs: 0).write(to: folder)
        let database = try TBDListeningDatabase(inMemory: ())
        let defaults = UserDefaults(suiteName: "tbd.tests.\(UUID().uuidString)")!
        let speech = TBDSpeechService(preferences: TBDListeningPreferences(defaults: defaults))
        let item = try await TBDMeetingRecorder(speech: speech).finalize(folder: folder, database: database, keepAudio: false)
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.sourceKind, .meeting)
        XCTAssertFalse(item.text.isEmpty)
        XCTAssertFalse(item.speakers.contains { $0.id == "me" }, "mic echo of the system track is removed")
        XCTAssertEqual(TBDMeetingManifest.read(from: folder)?.state, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.wav").path))
        XCTAssertEqual(try database.transcriptions(kind: .meeting).count, 1)
        await speech.shutdown()
    }
}
