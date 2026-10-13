import GRDB
import XCTest
@testable import TBDSpeech

final class RetentionTests: XCTestCase {
    private var root: URL!
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Meetings"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url)
        return url.path
    }

    private func sweeper(_ db: TBDListeningDatabase) -> TBDRetentionSweeper {
        TBDRetentionSweeper(database: db, managedRoot: root, meetingsRoot: root.appendingPathComponent("Meetings"))
    }

    private func meeting(_ db: TBDListeningDatabase, ageDays: Double, state: TBDMeetingManifest.State = .done,
                         status: TBDTranscriptionStatus = .completed) throws -> (TBDTranscription, URL) {
        let folder = root.appendingPathComponent("Meetings/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var item = TBDTranscription(title: "Meeting", sourceKind: .meeting, status: status)
        item.createdAt = now.addingTimeInterval(-ageDays * day)
        item.audioPaths = [try file("Meetings/\(folder.lastPathComponent)/microphone.wav")]
        item.rawText = "hello"
        try db.save(item)
        try TBDMeetingManifest(id: folder.lastPathComponent, title: "Meeting", startedAt: item.createdAt, state: state,
                               durationMs: 1000, transcriptionID: item.id).write(to: folder)
        return (item, folder)
    }

    func testPolicyCutoffOnlyForDeleteAfterDays() {
        XCTAssertNil(TBDRetentionPolicy(mode: .keepForever).cutoff(now: now))
        XCTAssertNil(TBDRetentionPolicy(mode: .deleteAudioAfterTranscription).cutoff(now: now), "never sweeps the existing library")
        XCTAssertEqual(TBDRetentionPolicy(mode: .deleteAfterDays, days: 7).cutoff(now: now), now.addingTimeInterval(-7 * day))
        XCTAssertEqual(TBDRetentionPolicy(mode: .deleteAfterDays, days: 0).days, 30, "out-of-range days fall back to 30")
        XCTAssertEqual(TBDRetentionPolicy(mode: .deleteAfterDays, days: 400).days, 30)
        XCTAssertFalse(TBDRetentionPolicy(mode: .deleteAudioAfterTranscription).keepsFreshAudio(.dictations))
        XCTAssertTrue(TBDRetentionPolicy(mode: .deleteAfterDays).keepsFreshAudio(.meetingAudio))
        XCTAssertFalse(TBDRetentionKind.meetingTranscripts.modes.contains(.deleteAudioAfterTranscription))
    }

    func testSettingsDefaultToKeepAndPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "retention-\(UUID().uuidString)"))
        let prefs = TBDListeningPreferences(defaults: defaults)
        // No stored retention: every kind keeps audio; an earlier single "keep audio" key is not read (C133).
        defaults.set(false, forKey: "tbd.listening.keepAudio")
        XCTAssertTrue(prefs.keepsAudio(.meetingAudio))
        XCTAssertTrue(prefs.keepsAudio(.dictations))
        XCTAssertEqual(prefs.retention[.meetingTranscripts].mode, .keepForever)
        var settings = prefs.retention
        settings[.dictations] = TBDRetentionPolicy(mode: .deleteAfterDays, days: 14)
        prefs.retention = settings
        XCTAssertEqual(prefs.retention[.dictations], TBDRetentionPolicy(mode: .deleteAfterDays, days: 14))
        XCTAssertTrue(prefs.retention.sweeps)
    }

    func testDictationsExpireByKindWithTheirAudio() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let oldAudio = try file("Dictations/old.wav")
        let old = TBDDictation(createdAt: now.addingTimeInterval(-10 * day), durationMs: 1, rawText: "old", audioPath: oldAudio)
        let fresh = TBDDictation(createdAt: now.addingTimeInterval(-2 * day), durationMs: 1, rawText: "fresh")
        let oldChat = TBDDictation(createdAt: now.addingTimeInterval(-10 * day), durationMs: 1, rawText: "chat", targetApp: "TBD Chat")
        let oldNote = TBDDictation(createdAt: now.addingTimeInterval(-10 * day), durationMs: 1, rawText: "note", targetApp: "TBD Voice note")
        for item in [old, fresh, oldChat, oldNote] { try db.save(item) }
        XCTAssertEqual(oldNote.kind, .voiceNote)

        var settings = TBDRetentionSettings()
        settings[.dictations] = TBDRetentionPolicy(mode: .deleteAfterDays, days: 7)
        let result = try sweeper(db).sweep(settings, now: now)
        XCTAssertEqual(result.deletedDictations, 2)
        XCTAssertEqual(Set(try db.dictations().map(\.id)), [fresh.id, oldNote.id], "voice notes follow their own policy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAudio))
    }

    func testVoiceNotesAndFileTranscriptionsExpireButSourceFilesStay() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let noteAudio = try file("VoiceNotes/n.wav")
        var note = TBDTranscription(title: "Voice note", sourceKind: .voiceNote, status: .completed)
        note.createdAt = now.addingTimeInterval(-40 * day)
        note.audioPaths = [noteAudio]
        try db.save(note)
        // A user's own file outside the Listening root.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("own-\(UUID().uuidString).m4a")
        try Data([0]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        var local = TBDTranscription(title: "Lecture", sourceKind: .file, sourcePath: outside.path, status: .completed)
        local.createdAt = now.addingTimeInterval(-40 * day)
        try db.save(local)
        var link = TBDTranscription(title: "Podcast", sourceKind: .url, status: .completed)
        link.createdAt = now.addingTimeInterval(-40 * day)
        link.audioPaths = [try file("Downloads/p.wav")]
        try db.save(link)
        var running = TBDTranscription(title: "Running", sourceKind: .file, status: .processing)
        running.createdAt = now.addingTimeInterval(-40 * day)
        try db.save(running)

        var settings = TBDRetentionSettings()
        settings[.voiceNotes] = TBDRetentionPolicy(mode: .deleteAfterDays, days: 30)
        settings[.fileTranscriptions] = TBDRetentionPolicy(mode: .deleteAfterDays, days: 30)
        let result = try sweeper(db).sweep(settings, now: now)
        XCTAssertEqual(result.deletedTranscriptions, 3)
        XCTAssertEqual(try db.transcriptions().map(\.id), [running.id], "processing items are never swept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteAudio))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.audioPaths[0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "original files are never removed")
    }

    func testMeetingAudioIsDetachedButTranscriptStays() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let (old, _) = try meeting(db, ageDays: 10)
        let (fresh, _) = try meeting(db, ageDays: 1)
        let (locked, _) = try meeting(db, ageDays: 10, state: .stopped)
        // An import: old recording date, but the retention clock started today.
        var (imported, _) = try meeting(db, ageDays: 100)
        imported.audioRetentionStartedAt = now.addingTimeInterval(-day)
        try db.save(imported)

        var settings = TBDRetentionSettings()
        settings[.meetingAudio] = TBDRetentionPolicy(mode: .deleteAfterDays, days: 7)
        let result = try sweeper(db).sweep(settings, now: now)
        XCTAssertEqual(result.detachedAudio, 1)
        XCTAssertEqual(result.skippedLocked, 1)
        let swept = try XCTUnwrap(db.transcription(id: old.id))
        XCTAssertTrue(swept.audioPaths.isEmpty)
        XCTAssertEqual(swept.rawText, "hello")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.audioPaths[0]))
        for id in [fresh.id, locked.id, imported.id] {
            XCTAssertEqual(try db.transcription(id: id)?.audioPaths.count, 1)
        }
    }

    func testMeetingTranscriptsExpireWithFolderUnlessRecoveryPending() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let (old, oldFolder) = try meeting(db, ageDays: 60)
        let (pending, pendingFolder) = try meeting(db, ageDays: 60, state: .recording, status: .failed)
        var settings = TBDRetentionSettings()
        settings[.meetingTranscripts] = TBDRetentionPolicy(mode: .deleteAfterDays, days: 30)
        settings[.meetingAudio] = TBDRetentionPolicy(mode: .deleteAudioAfterTranscription)
        let result = try sweeper(db).sweep(settings, now: now)
        XCTAssertEqual(result.deletedTranscriptions, 1)
        XCTAssertNil(try db.transcription(id: old.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.path))
        XCTAssertNotNil(try db.transcription(id: pending.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingFolder.path))
    }

    func testKeepForeverAndAudioOnlyModesNeverSweep() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        _ = try meeting(db, ageDays: 1000)
        try db.save(TBDDictation(createdAt: now.addingTimeInterval(-1000 * day), durationMs: 1, rawText: "x"))
        var settings = TBDRetentionSettings()
        for kind in TBDRetentionKind.allCases where kind.modes.contains(.deleteAudioAfterTranscription) {
            settings[kind] = TBDRetentionPolicy(mode: .deleteAudioAfterTranscription)
        }
        XCTAssertFalse(settings.sweeps)
        XCTAssertEqual(try sweeper(db).sweep(settings, now: now), TBDRetentionSweeper.Result())
        XCTAssertEqual(try db.dictations().count, 1)
        XCTAssertEqual(try db.transcriptions().first?.audioPaths.count, 1)
    }

    func testDeleteAllListeningDataKeepsVocabulary() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        try db.save(TBDDictation(durationMs: 1, rawText: "x"))
        let item = TBDTranscription(title: "t", sourceKind: .file, status: .completed)
        try db.save(item)
        try db.save(TBDSummary(transcriptionId: item.id, kind: .summary, prompt: "p", content: "c"))
        try db.save(TBDCustomWord(word: "grdb", replacement: "GRDB"))
        try db.deleteAllListeningData()
        XCTAssertTrue(try db.dictations().isEmpty)
        XCTAssertTrue(try db.transcriptions().isEmpty)
        XCTAssertTrue(try db.summaries(for: item.id).isEmpty)
        XCTAssertEqual(try db.customWords().count, 1)
    }

    func testRetentionMigrationBackfillsDictationKinds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("listening.sqlite")
        // A v1 library with a voice note and a chat dictation.
        let queue = try DatabaseQueue(path: url.path)
        var migrator = TBDListeningDatabase.migrator
        try migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            for (id, app) in [("a", "TBD Voice note"), ("b", "TBD Chat"), ("c", "Notes")] {
                try db.execute(sql: "INSERT INTO dictation (id, createdAt, durationMs, rawText, targetApp) VALUES (?, ?, 1, 'x', ?)",
                               arguments: [id, Date(), app])
            }
        }
        try queue.close()
        let db = try TBDListeningDatabase(url: url)
        let kinds = Dictionary(uniqueKeysWithValues: try db.dictations().map { ($0.id, $0.kind) })
        XCTAssertEqual(kinds, ["a": .voiceNote, "b": .chat, "c": .dictation])
        let columns = try db.writer.read { try $0.columns(in: "transcription").map(\.name) }
        XCTAssertTrue(columns.contains("audioRetentionStartedAt"))
    }
}
