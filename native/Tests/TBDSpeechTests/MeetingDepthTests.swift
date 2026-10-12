import XCTest
@testable import TBDSpeech

final class MeetingDepthTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("depth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func wav(_ url: URL, seconds: Double) throws {
        let writer = try TBDWAVWriter(url: url)
        let count = Int(seconds * 16_000)
        writer.append((0..<count).map { Float(sin(Double($0) * 0.05)) * 0.3 })
        try writer.close()
    }

    func testTimecodes() {
        XCTAssertEqual(TBDTimecode.parse("1:05"), 65_000)
        XCTAssertEqual(TBDTimecode.parse("1:02:03"), 3_723_000)
        XCTAssertEqual(TBDTimecode.parse("0:10.5"), 10_500)
        XCTAssertEqual(TBDTimecode.parse("75:00"), 4_500_000, "minutes may exceed 59 without hours")
        XCTAssertNil(TBDTimecode.parse("1:60"))
        XCTAssertNil(TBDTimecode.parse("1:61:00"))
        XCTAssertNil(TBDTimecode.parse("abc"))
        XCTAssertNil(TBDTimecode.parse("10"))
        XCTAssertEqual(TBDTimecode.format(10_500), "0:10.500")
        XCTAssertEqual(TBDTimecode.format(65_000), "1:05")
    }

    func testSplitRangesValidation() throws {
        XCTAssertEqual(try TBDMeetingSplitter.ranges(cuts: [1000], durationMs: 3000), [0..<1000, 1000..<3000])
        XCTAssertThrowsError(try TBDMeetingSplitter.ranges(cuts: [0], durationMs: 3000))
        XCTAssertThrowsError(try TBDMeetingSplitter.ranges(cuts: [3000], durationMs: 3000))
        XCTAssertThrowsError(try TBDMeetingSplitter.ranges(cuts: [2000, 1000], durationMs: 3000))
        XCTAssertEqual(TBDMeetingSplitter.defaultTitles("Sync", parts: 2), ["Sync — Part 1", "Sync — Part 2"])
    }

    func testSplitSlicesTracksAndLeavesSourceUntouched() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let folder = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try wav(folder.appendingPathComponent("microphone.wav"), seconds: 2)
        try wav(folder.appendingPathComponent("system.wav"), seconds: 0.8)
        var source = TBDTranscription(title: "Weekly", sourceKind: .meeting, status: .completed)
        source.audioPaths = ["microphone.wav", "system.wav"].map { folder.appendingPathComponent($0).path }
        source.durationMs = 2000
        source.rawText = "original"
        source.userNotes = "keep me"
        try db.save(source)
        try TBDMeetingManifest(id: "source", title: "Weekly", startedAt: source.createdAt, state: .done, durationMs: 2000,
                               transcriptionID: source.id).write(to: folder)

        let parts = try TBDMeetingSplitter.prepare(source, cutsMs: [1000], database: db, meetingsRoot: root)
        XCTAssertEqual(parts.map(\.item.title), ["Weekly — Part 1", "Weekly — Part 2"])
        XCTAssertEqual(parts.map(\.item.durationMs), [1000, 1000])
        XCTAssertEqual(parts.map(\.item.status), [.processing, .processing])
        // Part 1 has both tracks; the system track ends at 0.8 s, so part 2 has the microphone only.
        XCTAssertEqual(parts[0].item.audioPaths.count, 2)
        XCTAssertEqual(parts[1].item.audioPaths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["microphone.wav"])
        XCTAssertEqual(TBDAudioDecoder.durationMs(of: URL(fileURLWithPath: parts[0].item.audioPaths[0])), 1000)
        XCTAssertEqual(TBDAudioDecoder.durationMs(of: URL(fileURLWithPath: parts[0].item.audioPaths[1])), 800)
        XCTAssertEqual(TBDAudioDecoder.durationMs(of: URL(fileURLWithPath: parts[1].item.audioPaths[0])), 1000)
        for part in parts {
            let manifest = try XCTUnwrap(TBDMeetingManifest.read(from: part.folder))
            XCTAssertEqual(manifest.transcriptionID, part.item.id)
            XCTAssertEqual(manifest.state, .stopped, "ready for the normal meeting transcription")
            XCTAssertNil(part.item.userNotes, "notes stay with the source")
            XCTAssertNotNil(try db.transcription(id: part.item.id))
        }
        let after = try XCTUnwrap(db.transcription(id: source.id))
        XCTAssertEqual(after.rawText, "original")
        XCTAssertEqual(after.userNotes, "keep me")
        XCTAssertEqual(after.audioPaths, source.audioPaths)
    }

    func testSplitRefusesMeetingsWithoutAudio() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let item = TBDTranscription(title: "Gone", sourceKind: .meeting, status: .completed)
        XCTAssertThrowsError(try TBDMeetingSplitter.prepare(item, cutsMs: [10], database: db, meetingsRoot: root))
        XCTAssertNotNil(TBDMeetingSplitter.ineligibility(TBDTranscription(title: "f", sourceKind: .file, status: .completed)))
    }

    func testImportCreatesMeetingFolderAndRecord() async throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let source = root.appendingPathComponent("Interview.wav")
        try wav(source, seconds: 1.5)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (item, folder) = try await TBDMeetingImporter.prepare(file: source, startedAt: date, database: db, meetingsRoot: root)
        XCTAssertEqual(item.title, "Interview")
        XCTAssertEqual(item.sourceKind, .meeting)
        XCTAssertEqual(item.createdAt, date)
        XCTAssertNotNil(item.audioRetentionStartedAt)
        XCTAssertEqual(item.durationMs, 1500)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.wav").path))
        XCTAssertEqual(TBDMeetingManifest.read(from: folder)?.transcriptionID, item.id)
        XCTAssertEqual(try db.transcription(id: item.id)?.status, .processing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the source file is never changed")

        let text = root.appendingPathComponent("notes.txt")
        try "x".write(to: text, atomically: true, encoding: .utf8)
        do {
            _ = try await TBDMeetingImporter.prepare(file: text, database: db, meetingsRoot: root)
            XCTFail("text files are refused")
        } catch {
            XCTAssertEqual(error as? TBDMeetingEditError, .unsupportedFormat("notes.txt"))
        }
    }

    // MARK: Transcript edits

    private func transcript(_ db: TBDListeningDatabase) throws -> TBDTranscription {
        var item = TBDTranscription(title: "Call", sourceKind: .meeting, status: .completed)
        let texts = ["Hello", "there.", "We", "ship", "Friday.", "Sounds", "good", "to", "me."]
        item.words = texts.enumerated().map { index, text in
            TBDWord(text: text, start: index * 400, end: index * 400 + 300, speaker: index < 5 ? "S1" : "S2")
        }
        item.rawText = texts.joined(separator: " ")
        item.speakers = [TBDSpeaker(id: "S1", label: "Speaker 1"), TBDSpeaker(id: "S2", label: "Speaker 2")]
        item.segments = TBDTranscriptAssembler.segments(words: item.words)
        try db.save(item)
        return item
    }

    func testEditsReplayRenameAssignAndText() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let item = try transcript(db)
        let print = TBDTranscriptEditor.fingerprint(item)
        let base = try XCTUnwrap(db.projectedTranscription(id: item.id))
        XCTAssertEqual(base.segments.map(\.range), [TBDWordRange(0, 5), TBDWordRange(5, 9)])
        XCTAssertEqual(base.editCount, 0)

        try db.applyEdit(.renameSpeaker(id: "S1", label: "Ana"), to: item.id, fingerprint: print)
        try db.applyEdit(.addSpeaker(id: "user:bo", label: "Bo"), to: item.id, fingerprint: print)
        try db.applyEdit(.assignSpeaker(range: TBDWordRange(5, 9), speaker: "user:bo"), to: item.id, fingerprint: print)
        let edited = try db.applyEdit(.editText(range: TBDWordRange(2, 5), text: "We ship on Friday."), to: item.id, fingerprint: print)

        XCTAssertEqual(edited.item.speakers.map(\.label), ["Ana", "Bo"])
        XCTAssertEqual(edited.segments.map(\.segment.text), ["Hello there. We ship on Friday.", "Sounds good to me."])
        XCTAssertEqual(edited.segments.map(\.edited), [true, false])
        XCTAssertEqual(edited.item.segments[1].speaker, "user:bo")
        XCTAssertTrue(TBDExport.render(edited.item, as: .txt).contains("Bo: Sounds good to me."))
        // The stored words are untouched; search text carries the edit.
        let stored = try XCTUnwrap(db.transcription(id: item.id))
        XCTAssertEqual(stored.words, item.words)
        XCTAssertEqual(stored.cleanText, "Hello there. We ship on Friday. Sounds good to me.")
        XCTAssertEqual(try db.transcriptions(matching: "on Friday").map(\.id), [item.id])

        // A later edit of a containing passage replaces earlier text edits inside it.
        let whole = try db.applyEdit(.editText(range: TBDWordRange(0, 5), text: "Hi. Friday it is."), to: item.id, fingerprint: print)
        XCTAssertEqual(whole.segments[0].segment.text, "Hi. Friday it is.")

        // Undo is one step at a time.
        let undone = try XCTUnwrap(db.undoLastEdit(of: item.id))
        XCTAssertEqual(undone.segments[0].segment.text, "Hello there. We ship on Friday.")
        XCTAssertEqual(undone.editCount, 4)
    }

    func testEditsAreRefusedWhenStaleOrInvalidAndDroppedOnRetranscription() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        var item = try transcript(db)
        let print = TBDTranscriptEditor.fingerprint(item)
        XCTAssertThrowsError(try db.applyEdit(.renameSpeaker(id: "S1", label: "x"), to: item.id, fingerprint: "old")) {
            XCTAssertEqual($0 as? TBDTranscriptEditor.EditError, .stale)
        }
        XCTAssertThrowsError(try db.applyEdit(.editText(range: TBDWordRange(0, 2), text: "  "), to: item.id, fingerprint: print))
        XCTAssertThrowsError(try db.applyEdit(.assignSpeaker(range: TBDWordRange(0, 2), speaker: "nobody"), to: item.id, fingerprint: print))
        XCTAssertThrowsError(try db.applyEdit(.editText(range: TBDWordRange(7, 20), text: "x"), to: item.id, fingerprint: print))
        try db.applyEdit(.renameSpeaker(id: "S2", label: "Cy"), to: item.id, fingerprint: print)

        // Retranscription changes the words: old edits stop applying.
        item.words[0].text = "Hey"
        try db.save(item)
        XCTAssertEqual(try db.projectedTranscription(id: item.id)?.editCount, 0)
        XCTAssertEqual(try db.projectedTranscription(id: item.id)?.item.speakers.map(\.label), ["Speaker 1", "Speaker 2"])
        try db.deleteEdits(of: item.id)
        XCTAssertTrue(try db.corrections(for: item.id).isEmpty)
    }

    func testRenameTouchesOnlyTheTitle() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let item = try transcript(db)
        try db.rename(transcriptionId: item.id, title: "  Customer call ")
        let renamed = try XCTUnwrap(db.transcription(id: item.id))
        XCTAssertEqual(renamed.title, "Customer call")
        XCTAssertEqual(renamed.words, item.words)
        try db.rename(transcriptionId: item.id, title: "   ")
        XCTAssertEqual(try db.transcription(id: item.id)?.title, "Customer call")
    }
}
