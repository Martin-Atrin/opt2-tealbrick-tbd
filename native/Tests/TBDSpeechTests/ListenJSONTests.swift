import XCTest
@testable import TBDSpeech

/// `tbd-listen --json` output is a contract for agents: keys must stay stable, nulls included.
final class ListenJSONTests: XCTestCase {
    private func keys(_ json: String) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        if let array = object as? [[String: Any]] { return Set(array.first?.keys.map { $0 } ?? []) }
        return Set((object as? [String: Any])?.keys.map { $0 } ?? [])
    }

    private func sample() -> TBDTranscription {
        var item = TBDTranscription(title: "Call", sourceKind: .meeting, status: .completed)
        item.rawText = "Hello there."
        item.words = [TBDWord(text: "Hello", start: 0, end: 300), TBDWord(text: "there.", start: 300, end: 700)]
        item.segments = TBDTranscriptAssembler.segments(words: item.words)
        item.durationMs = 700
        return item
    }

    func testItemShape() throws {
        let json = TBDListenJSON.encode([TBDListenJSON.Item(sample())])
        XCTAssertEqual(try keys(json), ["id", "title", "kind", "status", "createdAt", "durationMs", "language", "engine", "preview"])
        XCTAssertTrue(json.contains("\"language\" : null"), "nil fields are present as null")
        XCTAssertTrue(json.contains("\"kind\" : \"meeting\""))
    }

    func testDetailShape() throws {
        let json = TBDListenJSON.encode(TBDListenJSON.Detail(sample()))
        XCTAssertEqual(try keys(json), ["schemaVersion", "id", "title", "kind", "status", "createdAt", "durationMs", "language", "engine",
                                        "sourcePath", "sourceURL", "text", "rawText", "cleanText", "speakers", "segments", "words",
                                        "audioPaths", "summaries", "error"])
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let segment = (object?["segments"] as? [[String: Any]])?.first
        XCTAssertEqual(Set(segment?.keys.map { $0 } ?? []), ["start", "end", "speaker", "text"])
        let word = (object?["words"] as? [[String: Any]])?.first
        XCTAssertEqual(Set(word?.keys.map { $0 } ?? []), ["start", "end", "speaker", "text", "confidence"])
    }

    func testDictationAndTranscribeShapes() throws {
        let dictation = TBDListenJSON.encode([TBDListenJSON.Dictation(TBDDictation(durationMs: 1000, rawText: "hi", targetApp: nil))])
        XCTAssertEqual(try keys(dictation), ["id", "createdAt", "durationMs", "text", "rawText", "targetApp", "wordCount"])
        let result = TBDListenJSON.encode(TBDListenJSON.TranscribeResult(file: "/tmp/a.wav", transcription: sample(), saved: false))
        XCTAssertEqual(try keys(result), ["schemaVersion", "id", "file", "text", "durationMs", "language", "engine", "speakers", "segments", "words"])
        XCTAssertTrue(result.contains("\"id\" : null"))
    }

    func testDatesAreISO8601() throws {
        let json = TBDListenJSON.encode(TBDListenJSON.Item(sample()))
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let date = try XCTUnwrap(object?["createdAt"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: date))
    }
}
