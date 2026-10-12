import GRDB
import XCTest
@testable import TBDSpeech

final class NotesAskTests: XCTestCase {
    func testNotesPersistAndBlankClears() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let item = TBDTranscription(title: "Standup", sourceKind: .meeting, status: .completed)
        try db.save(item)
        try db.updateUserNotes(id: item.id, notes: "[0:42] **Action:** send deck")
        XCTAssertEqual(try db.transcription(id: item.id)?.userNotes, "[0:42] **Action:** send deck")
        try db.updateUserNotes(id: item.id, notes: "  \n ")
        XCTAssertNil(try db.transcription(id: item.id)?.userNotes)
    }

    func testAskConversationsPersistPerTranscriptAndCascade() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let item = TBDTranscription(title: "Planning", sourceKind: .meeting, status: .completed)
        let other = TBDTranscription(title: "Other", sourceKind: .file, status: .completed)
        try db.save(item); try db.save(other)
        var chat = TBDAskConversation(transcriptionId: item.id, title: "Decisions made")
        chat.messages = [TBDAskMessage(.user, "Decisions made", prompt: "List the decisions"), TBDAskMessage(.assistant, "Ship Friday.")]
        try db.save(chat)
        try db.save(TBDAskConversation(transcriptionId: item.id, title: "empty"))   // dropped on read
        try db.save(TBDAskConversation(transcriptionId: other.id, title: "x", messages: [TBDAskMessage(.user, "q")]))
        let loaded = try db.askConversations(for: item.id)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].messages, chat.messages)
        XCTAssertEqual(loaded[0].messages[0].modelContent, "List the decisions")
        try db.deleteTranscription(id: item.id)
        XCTAssertTrue(try db.askConversations(for: item.id).isEmpty, "conversations cascade with the transcript")
        XCTAssertEqual(try db.askConversations(for: other.id).count, 1)
    }

    func testManifestCarriesNotesIntoTranscript() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var manifest = TBDMeetingManifest(id: "m", title: "Sync", startedAt: Date(), state: .recording, durationMs: 0, transcriptionID: "t1")
        manifest.notes = "remember budget"
        try manifest.write(to: folder)
        XCTAssertEqual(TBDMeetingManifest.read(from: folder)?.notes, "remember budget")
        // Older manifests without notes still decode.
        try #"{"id":"m","title":"Old","startedAt":"2026-01-01T00:00:00Z","state":"done","durationMs":5}"#
            .write(to: folder.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(TBDMeetingManifest.read(from: folder)?.notes)
        XCTAssertEqual(TBDMeetingManifest.read(from: folder)?.title, "Old")
    }

    func testSlashCommands() {
        XCTAssertEqual(TBDNotesCommands.pendingQuery(in: "hello /"), "")
        XCTAssertEqual(TBDNotesCommands.pendingQuery(in: "/dec"), "dec")
        XCTAssertNil(TBDNotesCommands.pendingQuery(in: "and/or"), "slash must start a word")
        XCTAssertNil(TBDNotesCommands.pendingQuery(in: "see /docs now"))
        XCTAssertEqual(TBDNotesCommands.suggestions(for: "x /a"), [.action])
        XCTAssertEqual(TBDNotesCommands.suggestions(for: "x /"), TBDNotesCommands.Command.allCases)
        XCTAssertEqual(TBDNotesCommands.apply(.now, to: "Budget /n", elapsedMs: 125_000), "Budget [2:05] ")
        XCTAssertEqual(TBDNotesCommands.apply(.action, to: "/ac", elapsedMs: 0), "**Action:** ")
        XCTAssertEqual(TBDNotesCommands.apply(.decision, to: "no command", elapsedMs: 0), "no command")
    }

    func testAskMessagesIncludeNotesTranscriptAndTrimHistory() {
        let history = (0..<10).flatMap { index in
            [TBDAskMessage(.user, "q\(index)"), TBDAskMessage(.assistant, String(repeating: "a", count: 300))]
        }
        let messages = TBDMeetingAsk.messages(question: "What next?", transcript: "[0:01] Me: ship it", notes: "budget matters",
                                              history: history, budget: 2_000)
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertTrue(messages[0].content.hasPrefix(TBDMeetingAsk.systemPrompt))
        XCTAssertTrue(messages[0].content.contains("User's notes from the meeting"))
        XCTAssertTrue(messages[0].content.contains("budget matters"))
        XCTAssertTrue(messages[0].content.contains("Transcript:\n[0:01] Me: ship it"))
        XCTAssertEqual(messages.last, .init(.user, "What next?"))
        XCTAssertLessThan(messages.count, 22, "oldest turns are dropped to fit the budget")
        XCTAssertEqual(messages[1].role, .user, "history is trimmed by whole turns")

        let noNotes = TBDMeetingAsk.messages(question: "q", transcript: "t", notes: "  ", history: [])
        XCTAssertFalse(noNotes[0].content.contains("User's notes"))
    }

    func testTruncateMiddleKeepsHeadAndTail() {
        let text = (1...500).map { "w\($0)" }.joined(separator: " ")
        let cut = TBDMeetingAsk.truncateMiddle(text, limit: 200)
        XCTAssertLessThanOrEqual(cut.count, 200)
        XCTAssertTrue(cut.hasPrefix("w1 w2"))
        XCTAssertTrue(cut.hasSuffix("w500"))
        XCTAssertTrue(cut.contains("content truncated"))
        XCTAssertEqual(TBDMeetingAsk.truncateMiddle("short", limit: 200), "short")
    }

    func testMarkdownExportIncludesNotes() {
        var item = TBDTranscription(title: "Sync", sourceKind: .meeting, status: .completed)
        item.rawText = "hello"
        item.userNotes = "**Decision:** go"
        XCTAssertTrue(TBDExport.render(item, as: .md).contains("## Notes\n\n**Decision:** go"))
    }
}
