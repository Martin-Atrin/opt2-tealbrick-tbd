import XCTest
@testable import TBDSpeech

final class TextPipelineTests: XCTestCase {
    let pipeline = TBDTextPipeline()

    func testRemovesFillers() {
        XCTAssertEqual(pipeline.process("um so I think, uh, we should go").text, "So I think, we should go")
        XCTAssertEqual(pipeline.process("Hello. Um, how are you?").text, "Hello. how are you?")
        XCTAssertEqual(pipeline.process("um so", removeFillers: false).text, "Um so")
    }

    func testFillerWordsInsideOtherWordsSurvive() {
        XCTAssertEqual(pipeline.process("the umbrella is huge").text, "The umbrella is huge")
    }

    func testCustomWords() {
        let words = [TBDCustomWord(word: "chat gpt", replacement: "ChatGPT"), TBDCustomWord(word: "tealbrick", replacement: "Teal Brick"),
                     TBDCustomWord(word: "kubernetes"), TBDCustomWord(word: "ignored", replacement: "X", isEnabled: false)]
        XCTAssertEqual(pipeline.process("ask chat gpt about tealbrick on Kubernetes, ignored", customWords: words).text,
                       "Ask ChatGPT about Teal Brick on kubernetes, ignored")
    }

    func testSnippetsLongestTriggerFirst() {
        let snippets = [TBDSnippet(trigger: "address", expansion: "ADDR"), TBDSnippet(trigger: "my address", expansion: "1 Main Street")]
        let result = pipeline.process("send it to my address please", snippets: snippets)
        XCTAssertEqual(result.text, "Send it to 1 Main Street please")
        XCTAssertEqual(result.expandedSnippetIDs, [snippets[1].id])
    }

    func testSpokenPunctuationAndWhitespace() {
        XCTAssertEqual(pipeline.process("is it ready question mark new line yes  it is").text, "Is it ready?\nyes it is")
        XCTAssertEqual(pipeline.process("  hello   world , again ").text, "Hello world, again")
    }

    func testEmptyInput() { XCTAssertEqual(pipeline.process("").text, "") }

    func testCleanupKeepsRawOnFailure() async throws {
        struct Boom: Error {}
        let failed = try await TBDCleanup.apply(raw: "raw text", enabled: true) { _ in throw Boom() }
        XCTAssertEqual(failed.text, "raw text")
        XCTAssertFalse(failed.warning.isEmpty)
        let disabled = try await TBDCleanup.apply(raw: "raw text", enabled: false) { _ in XCTFail("must not call"); return "" }
        XCTAssertEqual(disabled.text, "raw text")
        let cleaned = try await TBDCleanup.apply(raw: "raw text", enabled: true) { _ in "Raw text." }
        XCTAssertEqual(cleaned.text, "Raw text.")
        XCTAssertEqual(cleaned.raw, "raw text")
        let empty = try await TBDCleanup.apply(raw: "raw text", enabled: true) { _ in "  " }
        XCTAssertEqual(empty.text, "raw text")
    }
}
