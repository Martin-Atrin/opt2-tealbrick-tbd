import CoreGraphics
import XCTest
@testable import TBDSpeech

final class DocumentExportTests: XCTestCase {
    private func meeting(passages: Int = 3) -> TBDTranscription {
        var item = TBDTranscription(title: "Budget & <planning>", sourceKind: .meeting, status: .completed)
        item.durationMs = passages * 4000
        item.words = (0..<passages).flatMap { index -> [TBDWord] in
            let speaker = index % 2 == 0 ? "S1" : "S2"
            return ["We", "agreed", "on", "item", "\(index)."].enumerated().map { offset, text in
                TBDWord(text: text, start: index * 4000 + offset * 300, end: index * 4000 + offset * 300 + 250, speaker: speaker)
            }
        }
        item.rawText = item.words.map(\.text).joined(separator: " ")
        item.speakers = [TBDSpeaker(id: "S1", label: "Ana"), TBDSpeaker(id: "S2", label: "Bo")]
        item.segments = TBDTranscriptAssembler.segments(words: item.words)
        item.userNotes = "**Action:** send the deck"
        return item
    }

    func testZipWriterRoundTripAndCRC() {
        var zip = TBDZipWriter()
        zip.add("a.txt", "hello")
        zip.add("dir/b.xml", "<x/>")
        let archive = zip.finish()
        XCTAssertEqual(archive.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
        let entries = TBDZipWriter.entries(in: archive)
        XCTAssertEqual(entries["a.txt"], Data("hello".utf8))
        XCTAssertEqual(entries["dir/b.xml"], Data("<x/>".utf8))
        XCTAssertEqual(TBDZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926, "standard CRC-32 check value")
        // End of central directory record with two entries.
        let tail = [UInt8](archive.suffix(22))
        XCTAssertEqual(Array(tail.prefix(4)), [0x50, 0x4B, 0x05, 0x06])
        XCTAssertEqual(Int(tail[10]) | Int(tail[11]) << 8, 2)
    }

    func testDocxIsAValidPackageWithDocumentXML() throws {
        let data = TBDExport.data(meeting(), as: .docx, summaries: [TBDSummary(transcriptionId: "x", kind: .summary, prompt: "p", content: "## Key points\n- Ship it")])
        let entries = TBDZipWriter.entries(in: data)
        for part in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/_rels/document.xml.rels"] {
            XCTAssertNotNil(entries[part], part)
        }
        let document = try XCTUnwrap(entries["word/document.xml"])
        XCTAssertNoThrow(try XMLDocument(data: document), "document.xml is well-formed")
        XCTAssertNoThrow(try XMLDocument(data: try XCTUnwrap(entries["[Content_Types].xml"])))
        let xml = String(decoding: document, as: UTF8.self)
        XCTAssertTrue(xml.contains("Budget &amp; &lt;planning&gt;"))
        XCTAssertTrue(xml.contains("<w:pStyle w:val=\"Speaker\"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">Ana</w:t>"))
        XCTAssertTrue(xml.contains("[0:04] "))
        XCTAssertTrue(xml.contains("• Ship it"))
        XCTAssertTrue(xml.contains("Action: send the deck"))

        // Valid for the system unzip too.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).docx")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-tq", file.path]
        unzip.standardOutput = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
    }

    func testPDFHasPagesAndText() throws {
        let short = TBDExport.data(meeting(), as: .pdf)
        XCTAssertGreaterThan(short.count, 500)
        XCTAssertEqual(short.prefix(5), Data("%PDF-".utf8))
        let one = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: short as CFData)!))
        XCTAssertEqual(one.numberOfPages, 1)
        XCTAssertEqual(one.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 612, height: 792))

        let long = TBDExport.data(meeting(passages: 300), as: .pdf)
        let many = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: long as CFData)!))
        XCTAssertGreaterThan(many.numberOfPages, 3)
    }

    func testDAPTIsWellFormedTTML() throws {
        let xml = TBDExport.render(meeting(), as: .dapt)
        let document = try XMLDocument(xmlString: xml)
        let root = try XCTUnwrap(document.rootElement())
        XCTAssertEqual(root.name, "tt")
        XCTAssertEqual(root.attribute(forName: "daptm:scriptType")?.stringValue, "originalTranscript")
        XCTAssertTrue(xml.contains("<ttm:agent type=\"character\" xml:id=\"character_1\"><ttm:name type=\"alias\">Ana</ttm:name>"))
        XCTAssertTrue(xml.contains("begin=\"00:00:04.000\""))
        XCTAssertTrue(xml.contains("ttm:agent=\"character_2\""))
        XCTAssertEqual(TBDExportFormat.dapt.fileExtension, "dapt.xml")
        // Untimed transcripts still produce one event.
        var plain = TBDTranscription(title: "Note", sourceKind: .voiceNote, status: .completed)
        plain.rawText = "Just text"
        XCTAssertTrue(TBDExport.render(plain, as: .dapt).contains("<div xml:id=\"event_1\" daptm:represents=\"audio.dialogue\"><p>Just text</p></div>"))
    }
}
