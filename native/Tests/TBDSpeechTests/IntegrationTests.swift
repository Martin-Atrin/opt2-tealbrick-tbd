import XCTest
@testable import TBDSpeech

/// Seams between the engines work (routes, config) and the depth work (retention, retranscribe).
final class IntegrationTests: XCTestCase {
    private func preferences() throws -> (TBDListeningPreferences, () -> Void) {
        let name = "integration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (TBDListeningPreferences(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }

    /// Retranscribe switches a meeting to the final route chosen now; recovery keeps the engine fixed at start.
    func testRetranscribeUsesCurrentFinalEngine() async throws {
        let (prefs, cleanup) = try preferences()
        defer { cleanup() }
        prefs.liveEngine = .parakeetV3
        prefs.finalEngineOverride = .parakeetV2
        let speech = TBDSpeechService(preferences: prefs)
        let database = try TBDListeningDatabase(inMemory: ())
        for (current, expected) in [(false, TBDSpeechEngineKind.whisper), (true, .parakeetV2)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var manifest = TBDMeetingManifest(id: "m", title: "Seam", startedAt: Date(), state: .stopped, durationMs: 0)
            manifest.finalEngine = TBDEngineSelection(kind: .whisper)
            try manifest.write(to: folder)
            // No audio tracks: nothing is transcribed, so no model is needed.
            _ = try await TBDMeetingRecorder(speech: speech).finalize(folder: folder, database: database, keepAudio: false,
                                                                     currentFinalEngine: current)
            XCTAssertEqual(TBDMeetingManifest.read(from: folder)?.finalEngine?.kind, expected)
        }
        await speech.shutdown()
    }

    /// `tbd-listen config keepAudio` reads and writes the per-kind retention policies.
    func testConfigKeepAudioFollowsRetention() throws {
        let (prefs, cleanup) = try preferences()
        defer { cleanup() }
        XCTAssertEqual(try prefs.configValue("keepAudio"), .bool(true))
        var settings = prefs.retention
        settings[.meetingTranscripts] = TBDRetentionPolicy(mode: .deleteAfterDays, days: 7)
        prefs.retention = settings
        try prefs.setConfig("keepAudio", to: "false")
        XCTAssertEqual(try prefs.configValue("keepAudio"), .bool(false))
        XCTAssertFalse(prefs.keepsAudio(.dictations))
        XCTAssertFalse(prefs.keepsAudio(.fileTranscriptions))
        XCTAssertEqual(prefs.retention[.meetingTranscripts], TBDRetentionPolicy(mode: .deleteAfterDays, days: 7))
        try prefs.setConfig("keepAudio", to: "true")
        XCTAssertEqual(try prefs.configValue("keepAudio"), .bool(true))
        XCTAssertTrue(prefs.keepsAudio(.meetingAudio))
        XCTAssertEqual(prefs.retention[.meetingTranscripts].mode, .deleteAfterDays)
    }
}
