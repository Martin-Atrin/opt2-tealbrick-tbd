import XCTest
@testable import TBDSpeech

final class ExportTests: XCTestCase {
    func sample() -> TBDTranscription {
        var item = TBDTranscription(title: "Standup", sourceKind: .meeting, status: .completed)
        item.words = [
            TBDWord(text: "Hello", start: 0, end: 400, speaker: "S1"), TBDWord(text: "team.", start: 450, end: 900, speaker: "S1"),
            TBDWord(text: "Hi", start: 61_500, end: 61_800, speaker: "S2"), TBDWord(text: "there.", start: 61_850, end: 3_725_250, speaker: "S2"),
        ]
        item.rawText = "Hello team. Hi there."
        item.speakers = TBDTranscriptAssembler.speakers(in: item.words)
        item.segments = TBDTranscriptAssembler.segments(words: item.words)
        item.durationMs = 3_725_250
        return item
    }

    func testTimestamps() {
        XCTAssertEqual(TBDExport.timestamp(3_725_250, vtt: false), "01:02:05,250")
        XCTAssertEqual(TBDExport.timestamp(3_725_250, vtt: true), "01:02:05.250")
        XCTAssertEqual(TBDExport.timestamp(-5, vtt: true), "00:00:00.000")
        XCTAssertEqual(TBDExport.clock(65_000), "1:05")
        XCTAssertEqual(TBDExport.clock(3_725_000), "1:02:05")
    }

    func testSegmentsSplitBySpeaker() {
        let item = sample()
        XCTAssertEqual(item.segments.map(\.text), ["Hello team.", "Hi there."])
        XCTAssertEqual(item.segments.map(\.speaker), ["S1", "S2"])
        XCTAssertEqual(item.speakers.map(\.label), ["Speaker 1", "Speaker 2"])
    }

    func testSRT() {
        let srt = TBDExport.render(sample(), as: .srt)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> 00:00:00,900\nSpeaker 1: Hello team.\n\n2\n00:01:01,500 --> "), srt)
    }

    func testVTT() {
        let vtt = TBDExport.render(sample(), as: .vtt)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:00.900\n<v Speaker 1>Hello team.\n\n"), vtt)
        // Long segments are split into cues of at most 7 s.
        for line in vtt.split(separator: "\n") where line.contains("-->") {
            let parts = line.components(separatedBy: " --> ")
            XCTAssertLessThan(parts[0], parts[1])
        }
    }

    func testTextMarkdownJSON() throws {
        let item = sample()
        XCTAssertEqual(TBDExport.render(item, as: .txt), "Speaker 1: Hello team.\n\nSpeaker 2: Hi there.\n")
        let md = TBDExport.render(item, as: .md, summaries: [TBDSummary(transcriptionId: item.id, kind: .summary, prompt: "", content: "Short.")])
        XCTAssertTrue(md.contains("# Standup"))
        XCTAssertTrue(md.contains("## Summary\n\nShort."))
        XCTAssertTrue(md.contains("**Speaker 2** `1:01` Hi there."))
        let json = try JSONSerialization.jsonObject(with: Data(TBDExport.render(item, as: .json).utf8)) as? [String: Any]
        XCTAssertEqual(json?["title"] as? String, "Standup")
        XCTAssertEqual((json?["segments"] as? [[String: Any]])?.count, 2)
    }

    func testPlainTextWithoutWords() {
        var item = TBDTranscription(title: "Note", sourceKind: .voiceNote)
        item.rawText = "Just text"
        item.durationMs = 2000
        XCTAssertEqual(TBDExport.render(item, as: .txt), "Just text\n")
        XCTAssertEqual(TBDExport.render(item, as: .srt), "1\n00:00:00,000 --> 00:00:02,000\nJust text\n\n")
    }

    func testWordTimingJoinsSentencePieces() {
        let words = TBDWordTiming.words(tokens: [("▁Hel", 0.0, 0.1, 1), ("lo", 0.1, 0.2, 0.5), ("▁world", 0.3, 0.6, 1), (".", 0.6, 0.7, 1)])
        XCTAssertEqual(words.map(\.text), ["Hello", "world."])
        XCTAssertEqual(words.first?.end, 200)
        XCTAssertEqual(words.first?.confidence ?? 0, 0.75, accuracy: 0.001)
    }

    func testSpeakerAttributionByOverlap() {
        let words = [TBDWord(text: "a", start: 0, end: 500), TBDWord(text: "b", start: 1000, end: 1500), TBDWord(text: "c", start: 5000, end: 5100)]
        let turns = [TBDSpeakerTurn(speaker: "S1", start: 0, end: 900), TBDSpeakerTurn(speaker: "S2", start: 900, end: 2000)]
        XCTAssertEqual(TBDTranscriptAssembler.attribute(words, turns: turns).map(\.speaker), ["S1", "S2", "S2"])
    }
}
