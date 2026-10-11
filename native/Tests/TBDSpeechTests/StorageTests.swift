import XCTest
@testable import TBDSpeech

final class StorageTests: XCTestCase {
    func testMigrationsCreateSchemaOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("listening.sqlite")
        do {
            let db = try TBDListeningDatabase(url: url)
            try db.save(TBDDictation(durationMs: 1200, rawText: "hello there", targetApp: "Notes"))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
        // Reopen (migrations are idempotent) and read back, also read-only.
        XCTAssertEqual(try TBDListeningDatabase(url: url).dictations().count, 1)
        XCTAssertEqual(try TBDListeningDatabase(url: url, readOnly: true).dictations().first?.rawText, "hello there")
        let tables = try TBDListeningDatabase(url: url).writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for table in ["dictation", "transcription", "customWord", "snippet", "summary", "transcription_ft", "dictation_ft"] {
            XCTAssertTrue(tables.contains(table), table)
        }
    }

    func testTranscriptionRoundTripAndFullTextSearch() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        var meeting = TBDTranscription(title: "Weekly planning", sourceKind: .meeting)
        meeting.rawText = "We agreed to ship the budget review on Friday."
        meeting.words = [TBDWord(text: "We", start: 0, end: 200, speaker: "S1")]
        meeting.segments = [TBDSegment(start: 0, end: 2000, text: meeting.rawText, speaker: "S1")]
        meeting.speakers = [TBDSpeaker(id: "S1", label: "Speaker 1")]
        meeting.status = .completed
        try db.save(meeting)
        var file = TBDTranscription(title: "Podcast", sourceKind: .file)
        file.rawText = "Gardening tips for spring."
        try db.save(file)

        let loaded = try XCTUnwrap(db.transcription(id: meeting.id))
        XCTAssertEqual(loaded.segments, meeting.segments)
        XCTAssertEqual(loaded.speakers, meeting.speakers)
        XCTAssertEqual(loaded.words.first?.speaker, "S1")
        XCTAssertEqual(try db.transcription(id: String(meeting.id.prefix(8)))?.id, meeting.id)

        XCTAssertEqual(try db.transcriptions(matching: "budg").map(\.id), [meeting.id])
        XCTAssertEqual(try db.transcriptions(matching: "garden").map(\.id), [file.id])
        XCTAssertEqual(try db.transcriptions(matching: "planning").map(\.id), [meeting.id])
        XCTAssertEqual(try db.transcriptions(kind: .meeting).count, 1)
        XCTAssertTrue(try db.transcriptions(matching: "nonexistentword").isEmpty)

        // FTS stays in sync on update and delete.
        var updated = loaded
        updated.cleanText = "Quarterly roadmap"
        try db.save(updated)
        XCTAssertEqual(try db.transcriptions(matching: "roadmap").count, 1)
        try db.save(TBDSummary(transcriptionId: meeting.id, kind: .summary, prompt: "p", content: "c"))
        try db.deleteTranscription(id: meeting.id)
        XCTAssertTrue(try db.transcriptions(matching: "roadmap").isEmpty)
        XCTAssertTrue(try db.summaries(for: meeting.id).isEmpty, "summaries cascade")
    }

    func testDictationSearchAndStats() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        try db.save(TBDDictation(durationMs: 60_000, rawText: "one two three four", cleanText: "One two three four."))
        try db.save(TBDDictation(createdAt: Date(timeIntervalSinceNow: -3 * 86_400), durationMs: 60_000, rawText: "alpha beta"))
        XCTAssertEqual(try db.dictations(matching: "alph").count, 1)
        let stats = try db.dictationStats()
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.words, 6)
        XCTAssertEqual(stats.today, 1)
        XCTAssertEqual(stats.wordsPerMinute, 3)
    }

    func testVocabularyAndSnippets() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let snippet = TBDSnippet(trigger: "sig", expansion: "Best regards")
        try db.save(snippet)
        try db.save(TBDCustomWord(word: "grdb", replacement: "GRDB"))
        try db.incrementSnippetUse(ids: [snippet.id])
        XCTAssertEqual(try db.snippets().first?.useCount, 1)
        XCTAssertEqual(try db.customWords().first?.replacement, "GRDB")
    }

    func testWAVWriterRepairsHeaderAfterCrash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TBDWAVWriter(url: url)
        writer.append([Float](repeating: 0.25, count: 16_000))
        try writer.close()
        XCTAssertEqual(TBDAudioDecoder.durationMs(of: url), 1000)
        // Simulate a crash: zero the size fields, append raw samples without a patch.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 40); handle.write(Data(count: 4))
        try handle.seekToEnd(); handle.write(Data(count: 16_000 * 2))
        try handle.close()
        XCTAssertEqual(try TBDWAVWriter.repairHeader(at: url), 2000)
        XCTAssertEqual(TBDAudioDecoder.durationMs(of: url), 2000)
        XCTAssertEqual(try TBDAudioDecoder.samples(from: url).count, 32_000)
    }
}
