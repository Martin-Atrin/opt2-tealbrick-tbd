import GRDB
import XCTest
@testable import TBDSpeech

/// One-time import of the earlier library (`macparakeet.db`) into `listening.sqlite`.
/// The earlier file is built here with the earlier table and column names (temp folders only).
final class LegacyImportTests: XCTestCase {
    private var dir: URL!
    private var legacyURL: URL { dir.appendingPathComponent("macparakeet.db") }

    private let t0 = Date(timeIntervalSince1970: 1_767_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // Earlier ids: some stored as 16-byte UUID blobs, some as upper-case text.
    private let d1 = UUID(uuidString: "0B1C6F7E-1111-4A3B-9C8D-000000000001")!
    private let d2 = "0B1C6F7E-1111-4A3B-9C8D-000000000002"
    private let d3 = UUID(uuidString: "0B1C6F7E-1111-4A3B-9C8D-000000000003")!
    private let t1 = UUID(uuidString: "0B1C6F7E-2222-4A3B-9C8D-000000000001")!
    private let t2 = "0B1C6F7E-2222-4A3B-9C8D-000000000002"
    private let t3 = UUID(uuidString: "0B1C6F7E-2222-4A3B-9C8D-000000000003")!
    private let w1 = UUID(uuidString: "0B1C6F7E-3333-4A3B-9C8D-000000000001")!
    private let s1 = UUID(uuidString: "0B1C6F7E-4444-4A3B-9C8D-000000000001")!
    private let c1 = UUID(uuidString: "0B1C6F7E-5555-4A3B-9C8D-000000000001")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-legacy-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Tests

    func testImportsEveryKindWithExactValues() throws {
        try makeLegacyLibrary()
        let before = try Data(contentsOf: legacyURL)
        let db = try TBDListeningDatabase(inMemory: ())
        let report = try TBDLegacyImport.run(legacyURL: legacyURL, into: db, now: at(9_000))

        XCTAssertEqual(report.status, .imported)
        XCTAssertEqual(report.imported, [.dictations: 3, .transcripts: 2, .meetings: 1, .summaries: 2, .conversations: 1,
                                         .customWords: 2, .snippets: 2])
        XCTAssertEqual(report.alreadyPresent, [:])
        XCTAssertEqual(report.skipped, ["private dictation": 1, "unfinished or empty dictation": 1,
                                        "summary of a transcript not imported": 1, "empty Ask conversation": 1,
                                        "keystroke-action snippet": 1])
        XCTAssertEqual(report.notImported, ["prompts": 2])
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.message, "Imported 3 dictations, 2 transcripts, 1 meeting, 2 custom words and 2 snippets from the earlier TBD version.")

        // Row counts per kind.
        XCTAssertEqual(try counts(db), ["dictation": 3, "transcription": 3, "summary": 2, "askConversation": 1,
                                         "customWord": 2, "snippet": 2, "legacyImport": 1])

        // Dictations.
        let dictations = try db.writer.read { try TBDDictation.order(Column("createdAt")).fetchAll($0) }
        XCTAssertEqual(dictations.map(\.id), [d1.uuidString.lowercased(), d2.lowercased(), d3.uuidString.lowercased()])
        let first = dictations[0]
        XCTAssertEqual(first.createdAt, at(0))
        XCTAssertEqual(first.durationMs, 2500)
        XCTAssertEqual(first.rawText, "grüße an das team café ☕")
        XCTAssertEqual(first.cleanText, "Grüße an das Team, café ☕.")
        XCTAssertEqual(first.targetApp, "Notes")
        XCTAssertEqual(first.audioPath, "/Volumes/Archive/dictations/one.wav")
        XCTAssertEqual(first.engine, "parakeet")
        XCTAssertEqual(first.wordCount, 6)
        XCTAssertEqual(first.kind, .dictation)
        XCTAssertEqual(dictations[1].kind, .voiceNote)
        XCTAssertNil(dictations[1].cleanText)       // displayRawTranscript = 1 keeps the shown raw text
        XCTAssertEqual(dictations[1].rawText, "Einkaufsliste: Äpfel")
        XCTAssertNil(dictations[2].targetApp)       // NULL optional stays NULL
        XCTAssertNil(dictations[2].engine)
        XCTAssertEqual(dictations[2].durationMs, 900)

        // File transcript.
        let file = try XCTUnwrap(db.transcription(id: t1.uuidString.lowercased()))
        XCTAssertEqual(file.title, "Interview mit Jörg")
        XCTAssertEqual(file.sourceKind, .file)
        XCTAssertEqual(file.sourcePath, "/Volumes/Archive/interview.m4a")
        XCTAssertEqual(file.audioPaths, [])
        XCTAssertNil(file.audioRetentionStartedAt)
        XCTAssertEqual(file.createdAt, at(100))
        XCTAssertEqual(file.updatedAt, at(160))
        XCTAssertEqual(file.durationMs, 60_000)
        XCTAssertEqual(file.language, "de")
        XCTAssertEqual(file.engine, "parakeet")
        XCTAssertEqual(file.status, .completed)
        XCTAssertEqual(file.rawText, "Hallo Welt. Ça va?")
        XCTAssertNil(file.cleanText)
        XCTAssertEqual(file.words, [TBDWord(text: "Hallo", start: 0, end: 400, confidence: 0.9, speaker: "S1"),
                                    TBDWord(text: "Welt.", start: 450, end: 900, confidence: 0.8, speaker: "S1"),
                                    TBDWord(text: "Ça", start: 1000, end: 1200, confidence: 0.95, speaker: "S2"),
                                    TBDWord(text: "va?", start: 1250, end: 1500, confidence: 0.7, speaker: "S2")])
        XCTAssertEqual(file.speakers, [TBDSpeaker(id: "S1", label: "Ana"), TBDSpeaker(id: "S2", label: "Speaker 2")])
        XCTAssertEqual(file.segments, [TBDSegment(start: 0, end: 900, text: "Hallo Welt.", speaker: "S1"),
                                       TBDSegment(start: 1000, end: 1500, text: "Ça va?", speaker: "S2")])

        // Link transcript (older [String] speakers, NULL duration and text).
        let link = try XCTUnwrap(db.transcription(id: t2.lowercased()))
        XCTAssertEqual(link.title, "Derived title")
        XCTAssertEqual(link.sourceKind, .url)
        XCTAssertEqual(link.sourceURL, "https://example.com/watch?v=1")
        XCTAssertNil(link.sourcePath)
        XCTAssertEqual(link.audioPaths, ["/Volumes/Archive/youtube-downloads/one.m4a"])
        XCTAssertEqual(link.audioRetentionStartedAt, at(9_000))
        XCTAssertEqual(link.durationMs, 0)
        XCTAssertEqual(link.status, .failed)
        XCTAssertEqual(link.errorMessage, "Network down")
        XCTAssertEqual(link.rawText, "")
        XCTAssertEqual(link.speakers, [TBDSpeaker(id: "S1", label: "Host"), TBDSpeaker(id: "S2", label: "Guest")])
        XCTAssertEqual(link.words, [])
        XCTAssertEqual(link.segments, [])

        // Meeting (interrupted, segments built from words, audio path kept).
        let meeting = try XCTUnwrap(db.transcription(id: t3.uuidString.lowercased()))
        XCTAssertEqual(meeting.title, "Weekly sync 📅")
        XCTAssertEqual(meeting.sourceKind, .meeting)
        XCTAssertEqual(meeting.audioPaths, ["/Volumes/Archive/meeting-recordings/weekly/meeting.m4a"])
        XCTAssertEqual(meeting.userNotes, "Notizen [0:05] Budget")
        XCTAssertEqual(meeting.status, .failed)
        XCTAssertEqual(meeting.errorMessage, "Interrupted before it finished.")
        XCTAssertEqual(meeting.durationMs, 700)
        XCTAssertEqual(meeting.segments, [TBDSegment(start: 0, end: 700, text: "Guten Morgen")])
        XCTAssertEqual(meeting.speakers, [])

        // Summaries and Ask.
        let summary = try XCTUnwrap(db.writer.read { try TBDSummary.fetchOne($0, key: self.s1.uuidString.lowercased()) })
        XCTAssertEqual(summary.transcriptionId, t1.uuidString.lowercased())
        XCTAssertEqual(summary.kind, .summary)
        XCTAssertEqual(summary.prompt, "Summarize the transcript.\n\nBe brief.")
        XCTAssertEqual(summary.content, "Kurz: Hallo Welt — ça va.")
        XCTAssertEqual(summary.createdAt, at(200))
        let chat = try XCTUnwrap(db.writer.read { try TBDAskConversation.fetchOne($0, key: self.c1.uuidString.lowercased()) })
        XCTAssertEqual(chat.transcriptionId, t1.uuidString.lowercased())
        XCTAssertEqual(chat.title, "Wer spricht?")
        XCTAssertEqual(chat.messages, [TBDAskMessage(.user, "Wer spricht?", prompt: "List the speakers"),
                                       TBDAskMessage(.assistant, "Ana und Speaker 2.")])
        XCTAssertEqual(chat.createdAt, at(300))
        XCTAssertEqual(chat.updatedAt, at(310))

        // Vocabulary and snippets.
        let words = try db.customWords().sorted { $0.createdAt < $1.createdAt }
        XCTAssertEqual(words.map(\.word), ["chat gpt", "Jörg"])
        XCTAssertEqual(words[0].id, w1.uuidString.lowercased())
        XCTAssertEqual(words[0].replacement, "ChatGPT")
        XCTAssertTrue(words[0].isEnabled)
        XCTAssertEqual(words[0].createdAt, at(400))
        XCTAssertNil(words[1].replacement)
        XCTAssertFalse(words[1].isEnabled)
        let snippets = try db.snippets()
        XCTAssertEqual(snippets.map { [$0.trigger, $0.expansion] }, [["addr", "Hauptstraße 1, Zürich"], ["sig", "Grüße — das Team"]])
        XCTAssertEqual(snippets[0].useCount, 4)
        XCTAssertTrue(snippets[0].isEnabled)
        XCTAssertEqual(snippets[0].createdAt, at(500))
        XCTAssertFalse(snippets[1].isEnabled)

        // Full-text search sees imported rows.
        XCTAssertEqual(try db.dictations(matching: "café").map(\.id), [d1.uuidString.lowercased()])
        XCTAssertEqual(try db.transcriptions(matching: "Welt").map(\.id), [t1.uuidString.lowercased()])

        // The earlier file is untouched and no side files appear.
        XCTAssertEqual(try Data(contentsOf: legacyURL), before)
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path + suffix), suffix)
        }

        // Marker row.
        let marker = try XCTUnwrap(db.writer.read { try Row.fetchOne($0, sql: "SELECT * FROM legacyImport") })
        XCTAssertEqual(marker["source"] as String, "macparakeet-v1")
        XCTAssertEqual(marker["sourcePath"] as String, legacyURL.path)
        XCTAssertEqual(marker["completedAt"] as Date, at(9_000))
        XCTAssertEqual(marker["summary"] as String,
                       "dictations=3 transcripts=2 meetings=1 summaries=2 conversations=1 customWords=2 snippets=2 alreadyPresent=0 skipped=5 errors=0 favorites=0")
    }

    func testSecondRunImportsNothing() throws {
        try makeLegacyLibrary()
        let db = try TBDListeningDatabase(inMemory: ())
        try TBDLegacyImport.run(legacyURL: legacyURL, into: db)
        let after = try counts(db)
        let second = try TBDLegacyImport.run(legacyURL: legacyURL, into: db)
        XCTAssertEqual(second.status, .alreadyImported)
        XCTAssertEqual(second.totalImported, 0)
        XCTAssertNil(second.message)
        XCTAssertEqual(try counts(db), after)
        XCTAssertEqual(TBDLegacyImport.runAtStart(into: db, legacyURL: legacyURL), .init(message: nil, changed: false))
    }

    func testMissingLegacyFileIsNoOp() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let report = try TBDLegacyImport.run(legacyURL: legacyURL, into: db)
        XCTAssertEqual(report.status, .noLegacyLibrary)
        XCTAssertEqual(report.totalImported, 0)
        XCTAssertEqual(try counts(db).values.reduce(0, +), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(TBDLegacyImport.runAtStart(into: db, legacyURL: legacyURL), .init(message: nil, changed: false))
    }

    func testHalfDoneImportDoesNotDuplicate() throws {
        try makeLegacyLibrary()
        let db = try TBDListeningDatabase(inMemory: ())
        // Left by an interrupted earlier attempt: one dictation with its earlier id, one word typed again. No marker.
        try db.save(TBDDictation(id: d1.uuidString.lowercased(), createdAt: at(0), durationMs: 2500, rawText: "grüße an das team café ☕"))
        try db.save(TBDCustomWord(word: "CHAT GPT", replacement: "ChatGPT"))

        let report = try TBDLegacyImport.run(legacyURL: legacyURL, into: db)
        XCTAssertEqual(report.status, .imported)
        XCTAssertEqual(report.count(.dictations), 2)
        XCTAssertEqual(report.count(.customWords), 1)
        XCTAssertEqual(report.alreadyPresent, [.dictations: 1, .customWords: 1])
        XCTAssertEqual(try counts(db), ["dictation": 3, "transcription": 3, "summary": 2, "askConversation": 1,
                                         "customWord": 2, "snippet": 2, "legacyImport": 1])
        XCTAssertEqual(try db.customWords().map(\.word), ["CHAT GPT", "Jörg"])
    }

    func testUnreadableLegacyFileReportsErrorAndRetriesNextStart() throws {
        try Data("this is not a database, just text".utf8).write(to: legacyURL)
        let db = try TBDListeningDatabase(inMemory: ())
        XCTAssertThrowsError(try TBDLegacyImport.run(legacyURL: legacyURL, into: db))
        let outcome = TBDLegacyImport.runAtStart(into: db, legacyURL: legacyURL)
        XCTAssertFalse(outcome.changed)
        let message = try XCTUnwrap(outcome.message)
        XCTAssertTrue(message.hasPrefix("Could not import Listen data from the earlier TBD version: "), message)
        XCTAssertTrue(message.hasSuffix(" TBD tries again at next start."), message)
        XCTAssertEqual(try counts(db).values.reduce(0, +), 0)   // no marker: the next start tries again
        XCTAssertEqual(try Data(contentsOf: legacyURL), Data("this is not a database, just text".utf8))

        // A readable file at the next start imports normally.
        try FileManager.default.removeItem(at: legacyURL)
        try makeLegacyLibrary()
        XCTAssertEqual(TBDLegacyImport.runAtStart(into: db, legacyURL: legacyURL),
                       .init(message: "Imported 3 dictations, 2 transcripts, 1 meeting, 2 custom words and 2 snippets from the earlier TBD version.",
                             changed: true))
    }

    func testOnDiskLibraryGetsMarkerTable() throws {
        let url = dir.appendingPathComponent("listening.sqlite")
        try makeLegacyLibrary()
        do {
            let db = try TBDListeningDatabase(url: url)
            XCTAssertEqual(try TBDLegacyImport.run(legacyURL: legacyURL, into: db).count(.meetings), 1)
        }
        let reopened = try TBDListeningDatabase(url: url)
        XCTAssertEqual(try TBDLegacyImport.run(legacyURL: legacyURL, into: reopened).status, .alreadyImported)
    }

    // MARK: - Helpers

    private func counts(_ db: TBDListeningDatabase) throws -> [String: Int] {
        try db.writer.read { db in
            var result: [String: Int] = [:]
            for table in ["dictation", "transcription", "summary", "askConversation", "customWord", "snippet", "legacyImport"] {
                result[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return result
        }
    }

    /// Builds an earlier-version library: tables and columns as the earlier migrations created them
    /// (create blocks plus the later ALTER columns), rows bound the way GRDB stored them.
    private func makeLegacyLibrary() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false   // one summary points at a deleted transcript
        let queue = try DatabaseQueue(path: legacyURL.path, configuration: configuration)
        try queue.write { db in
            try createLegacySchema(db)
            try insertLegacyRows(db)
        }
        try queue.close()
    }

    private func createLegacySchema(_ db: Database) throws {
        // v0.1-dictations (+ v0.5 hidden/wordCount, v0.8 engine, v0.12 displayRawTranscript, v0.19 language, v0.21 formatter)
        try db.create(table: "dictations") { t in
            t.column("id", .text).primaryKey()
            t.column("createdAt", .text).notNull()
            t.column("durationMs", .integer).notNull()
            t.column("rawTranscript", .text).notNull()
            t.column("cleanTranscript", .text)
            t.column("audioPath", .text)
            t.column("pastedToApp", .text)
            t.column("processingMode", .text).notNull().defaults(to: "raw")
            t.column("status", .text).notNull().defaults(to: "completed")
            t.column("errorMessage", .text)
            t.column("updatedAt", .text).notNull()
        }
        try db.alter(table: "dictations") { t in
            t.add(column: "hidden", .boolean).notNull().defaults(to: false)
            t.add(column: "wordCount", .integer).notNull().defaults(to: 0)
            t.add(column: "engine", .text)
            t.add(column: "engineVariant", .text)
            t.add(column: "displayRawTranscript", .boolean).notNull().defaults(to: false)
            t.add(column: "language", .text)
            t.add(column: "aiFormatterProfileID", .text)
            t.add(column: "aiFormatterProfileName", .text)
            t.add(column: "aiFormatterProfileMatchKind", .text)
        }
        // v0.1-transcriptions (+ later columns)
        try db.create(table: "transcriptions") { t in
            t.column("id", .text).primaryKey()
            t.column("createdAt", .text).notNull()
            t.column("fileName", .text).notNull()
            t.column("filePath", .text)
            t.column("fileSizeBytes", .integer)
            t.column("durationMs", .integer)
            t.column("rawTranscript", .text)
            t.column("cleanTranscript", .text)
            t.column("wordTimestamps", .text)
            t.column("language", .text).defaults(to: "en")
            t.column("speakerCount", .integer)
            t.column("speakers", .text)
            t.column("status", .text).notNull().defaults(to: "processing")
            t.column("errorMessage", .text)
            t.column("exportPath", .text)
            t.column("updatedAt", .text).notNull()
        }
        try db.alter(table: "transcriptions") { t in
            t.add(column: "sourceURL", .text)
            t.add(column: "diarizationSegments", .text)
            t.add(column: "chatMessages", .text)
            t.add(column: "thumbnailURL", .text)
            t.add(column: "channelName", .text)
            t.add(column: "videoDescription", .text)
            t.add(column: "isFavorite", .boolean).notNull().defaults(to: false)
            t.add(column: "sourceType", .text).notNull().defaults(to: "file")
            t.add(column: "recoveredFromCrash", .boolean).notNull().defaults(to: false)
            t.add(column: "isTranscriptEdited", .boolean).notNull().defaults(to: false)
            t.add(column: "userNotes", .text)
            t.add(column: "engine", .text)
            t.add(column: "engineVariant", .text)
            t.add(column: "derivedTitle", .text)
            t.add(column: "derivedSnippet", .text)
            t.add(column: "meetingArtifactFolderPath", .text)
            t.add(column: "audioTrackOrdinal", .integer)
        }
        for column in ["transcriptSegments", "meetingStartContext", "calendarEventSnapshot", "titleOverride",
                       "meetingCaptureReport", "splitProvenance", "audioRetentionStartedAt"] {
            try db.execute(sql: "ALTER TABLE transcriptions ADD COLUMN \(column) TEXT")
        }
        // v0.2-custom-words
        try db.create(table: "custom_words") { t in
            t.column("id", .text).primaryKey()
            t.column("word", .text).notNull()
            t.column("replacement", .text)
            t.column("source", .text).notNull().defaults(to: "manual")
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("createdAt", .text).notNull()
            t.column("updatedAt", .text).notNull()
        }
        try db.execute(sql: "CREATE UNIQUE INDEX idx_custom_words_word ON custom_words(word COLLATE NOCASE)")
        // v0.2-text-snippets (+ v0.7 action)
        try db.create(table: "text_snippets") { t in
            t.column("id", .text).primaryKey()
            t.column("trigger", .text).notNull()
            t.column("expansion", .text).notNull()
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("useCount", .integer).notNull().defaults(to: 0)
            t.column("createdAt", .text).notNull()
            t.column("updatedAt", .text).notNull()
        }
        try db.execute(sql: "CREATE UNIQUE INDEX idx_text_snippets_trigger ON text_snippets(\"trigger\" COLLATE NOCASE)")
        try db.alter(table: "text_snippets") { t in t.add(column: "action", .text) }
        // v0.5-chat-conversations
        try db.create(table: "chat_conversations") { t in
            t.column("id", .text).primaryKey()
            t.column("transcriptionId", .text).notNull().references("transcriptions", onDelete: .cascade)
            t.column("title", .text).notNull().defaults(to: "")
            t.column("messages", .text)
            t.column("createdAt", .text).notNull()
            t.column("updatedAt", .text).notNull()
        }
        // v0.7-prompts-and-summaries (+ v0.8 userNotesSnapshot)
        try db.create(table: "summaries") { t in
            t.column("id", .text).primaryKey()
            t.column("transcriptionId", .text).notNull().references("transcriptions", onDelete: .cascade)
            t.column("promptName", .text).notNull()
            t.column("promptContent", .text).notNull()
            t.column("extraInstructions", .text)
            t.column("content", .text).notNull()
            t.column("createdAt", .text).notNull()
            t.column("updatedAt", .text).notNull()
        }
        try db.alter(table: "summaries") { t in t.add(column: "userNotesSnapshot", .text) }
        // A table with no place in the new library (counted, not imported).
        try db.create(table: "prompts") { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
        }
    }

    private func insertLegacyRows(_ db: Database) throws {
        let dictationSQL = """
            INSERT INTO dictations (id, createdAt, durationMs, rawTranscript, cleanTranscript, audioPath, pastedToApp,
                                    processingMode, status, updatedAt, hidden, wordCount, engine, displayRawTranscript)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        try db.execute(sql: dictationSQL, arguments: [d1, at(0), 2500, "grüße an das team café ☕", "Grüße an das Team, café ☕.",
                                                      "/Volumes/Archive/dictations/one.wav", "Notes", "clean", "completed", at(1), false, 6, "parakeet", false])
        try db.execute(sql: dictationSQL, arguments: [d2, at(10), 1200, "Einkaufsliste: Äpfel", "Einkaufsliste: Äpfel.",
                                                      nil, "TBD Voice note", "clean", "completed", at(11), false, 2, "whisper", true])
        try db.execute(sql: dictationSQL, arguments: [d3, at(20), 900, "ok", nil, nil, nil, "raw", "completed", at(21), false, 1, nil, false])
        try db.execute(sql: dictationSQL, arguments: [UUID(), at(30), 800, "", nil, nil, nil, "raw", "completed", at(31), true, 0, nil, false])
        try db.execute(sql: dictationSQL, arguments: [UUID(), at(40), 0, "", nil, nil, nil, "raw", "error", at(41), false, 0, nil, false])

        let wordsJSON = """
            [{"word":"Hallo","startMs":0,"endMs":400,"confidence":0.9,"speakerId":"S1"},
             {"word":"Welt.","startMs":450,"endMs":900,"confidence":0.8,"speakerId":"S1"},
             {"word":"Ça","startMs":1000,"endMs":1200,"confidence":0.95,"speakerId":"S2"},
             {"word":"va?","startMs":1250,"endMs":1500,"confidence":0.7,"speakerId":"S2"}]
            """
        let segmentsJSON = """
            [{"id":"6A0F1B2C-0000-4000-8000-000000000001","startMs":0,"endMs":900,"speakerId":"S1","speakerLabel":"Ana",
              "text":"Hallo Welt.","wordRange":{"startIndex":0,"endIndexExclusive":2}},
             {"id":"6A0F1B2C-0000-4000-8000-000000000002","startMs":1000,"endMs":1500,"speakerId":"S2","speakerLabel":"Speaker 2",
              "text":"Ça va?","wordRange":{"startIndex":2,"endIndexExclusive":4}}]
            """
        let transcriptionSQL = """
            INSERT INTO transcriptions (id, createdAt, fileName, filePath, durationMs, rawTranscript, cleanTranscript, wordTimestamps,
                                        language, speakers, status, errorMessage, updatedAt, sourceURL, sourceType, userNotes, engine,
                                        derivedTitle, transcriptSegments, titleOverride)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        try db.execute(sql: transcriptionSQL, arguments: [
            t1, at(100), "interview.m4a", "/Volumes/Archive/interview.m4a", 60_000, "Hallo Welt. Ça va?", nil, wordsJSON,
            "de", #"[{"id":"S1","label":"Ana"},{"id":"S2","label":"Speaker 2"}]"#, "completed", nil, at(160), nil, "file", nil,
            "parakeet", nil, segmentsJSON, "Interview mit Jörg",
        ])
        try db.execute(sql: transcriptionSQL, arguments: [
            t2, at(110), "video title", "/Volumes/Archive/youtube-downloads/one.m4a", nil, nil, nil, nil,
            "en", #"["Host","Guest"]"#, "error", "Network down", at(111), "https://example.com/watch?v=1", "youtube", nil,
            nil, "Derived title", nil, nil,
        ])
        try db.execute(sql: transcriptionSQL, arguments: [
            t3, at(120), "Weekly sync 📅", "/Volumes/Archive/meeting-recordings/weekly/meeting.m4a", 700, "Guten Morgen", nil,
            #"[{"word":"Guten","startMs":0,"endMs":300,"confidence":1},{"word":"Morgen","startMs":350,"endMs":700,"confidence":1}]"#,
            "de", nil, "processing", nil, at(121), nil, "meeting", "Notizen [0:05] Budget", "parakeet", nil, nil, nil,
        ])

        let summarySQL = """
            INSERT INTO summaries (id, transcriptionId, promptName, promptContent, extraInstructions, content, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        try db.execute(sql: summarySQL, arguments: [s1, t1, "Summary", "Summarize the transcript.", "Be brief.",
                                                    "Kurz: Hallo Welt — ça va.", at(200), at(200)])
        try db.execute(sql: summarySQL, arguments: [UUID(), t3, "Action items", "List action items.", nil, "- Budget", at(210), at(210)])
        try db.execute(sql: summarySQL, arguments: [UUID(), UUID(), "Summary", "Summarize.", nil, "orphan", at(220), at(220)])

        let chatSQL = "INSERT INTO chat_conversations (id, transcriptionId, title, messages, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)"
        try db.execute(sql: chatSQL, arguments: [c1, t1, "Wer spricht?", """
            [{"role":"system","content":"You are helpful."},
             {"role":"user","content":"Wer spricht?","modelPromptOverride":"List the speakers"},
             {"role":"assistant","content":"Ana und Speaker 2."}]
            """, at(300), at(310)])
        try db.execute(sql: chatSQL, arguments: [UUID(), t3, "", nil, at(320), at(320)])

        let wordSQL = "INSERT INTO custom_words (id, word, replacement, source, isEnabled, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)"
        try db.execute(sql: wordSQL, arguments: [w1, "chat gpt", "ChatGPT", "manual", true, at(400), at(400)])
        try db.execute(sql: wordSQL, arguments: ["0B1C6F7E-3333-4A3B-9C8D-000000000002", "Jörg", nil, "learned", false, at(410), at(410)])

        let snippetSQL = """
            INSERT INTO text_snippets (id, "trigger", expansion, isEnabled, useCount, createdAt, updatedAt, action)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        try db.execute(sql: snippetSQL, arguments: [UUID(), "addr", "Hauptstraße 1, Zürich", true, 4, at(500), at(500), nil])
        try db.execute(sql: snippetSQL, arguments: [UUID(), "sig", "Grüße — das Team", false, 0, at(510), at(510), nil])
        try db.execute(sql: snippetSQL, arguments: [UUID(), "new line", "", true, 9, at(520), at(520), "return"])

        try db.execute(sql: "INSERT INTO prompts (id, name) VALUES (?, ?), (?, ?)", arguments: [UUID(), "Summary", UUID(), "Mine"])
    }
}
