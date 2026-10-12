import CoreGraphics
import CoreText
import Foundation

/// A transcript laid out as paragraphs for the binary document formats (DOCX and PDF): title,
/// metadata, a rule, summaries and notes, then the transcript with a speaker line at each change
/// and an `[m:ss]` stamp per passage.
struct TBDDocumentModel {
    enum Style { case title, meta, rule, heading, speaker, body }
    struct Run { var text: String; var bold = false; var muted = false; var monospaced = false }
    struct Paragraph { var style: Style; var runs: [Run] }

    var paragraphs: [Paragraph] = []

    init(_ item: TBDTranscription, summaries: [TBDSummary]) {
        func add(_ style: Style, _ runs: Run...) { paragraphs.append(Paragraph(style: style, runs: runs)) }
        add(.title, Run(text: item.title))
        if item.durationMs > 0 { add(.meta, Run(text: "Duration: " + TBDExport.clock(item.durationMs), muted: true)) }
        add(.meta, Run(text: "Source: " + item.sourceKind.label + (item.sourceURL.map { " (\($0))" } ?? ""), muted: true))
        add(.meta, Run(text: "Transcribed: " + item.createdAt.formatted(date: .abbreviated, time: .shortened), muted: true))
        if !item.speakers.isEmpty { add(.meta, Run(text: "Speakers: " + item.speakers.map(\.label).joined(separator: ", "), muted: true)) }
        add(.rule, Run(text: String(repeating: "-", count: 58), muted: true))

        for summary in summaries {
            add(.heading, Run(text: summary.kind == .summary ? "Summary" : "Q: " + summary.prompt))
            for line in summary.content.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                add(.body, Run(text: Self.plain(line)))
            }
        }
        let notes = item.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !notes.isEmpty {
            add(.heading, Run(text: "Notes"))
            for line in notes.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                add(.body, Run(text: Self.plain(line)))
            }
        }
        if !summaries.isEmpty || !notes.isEmpty { add(.heading, Run(text: "Transcript")) }

        let segments = TBDExport.displaySegments(item)
        guard !segments.isEmpty else {
            if !item.text.isEmpty { add(.body, Run(text: item.text)) }
            return
        }
        var lastSpeaker: String?
        for segment in segments {
            if let speaker = segment.speaker, speaker != lastSpeaker {
                add(.speaker, Run(text: item.speakerLabel(speaker) ?? speaker, bold: true))
            }
            lastSpeaker = segment.speaker
            add(.body, Run(text: "[\(TBDExport.clock(segment.start))] ", muted: true, monospaced: true), Run(text: segment.text))
        }
    }

    /// Strips light Markdown (headings, bullets, emphasis) from model output.
    static func plain(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("- ") || text.hasPrefix("* ") { text = "• " + text.dropFirst(2) }
        return text.replacingOccurrences(of: "**", with: "")
    }
}

/// Word document (Office Open XML) written by hand: four package parts in a stored ZIP.
enum TBDDocxExport {
    static func render(_ model: TBDDocumentModel) -> Data {
        var zip = TBDZipWriter()
        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        </Types>
        """)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        </Relationships>
        """)
        zip.add("word/_rels/document.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        </Relationships>
        """)
        zip.add("word/styles.xml", styles)
        zip.add("word/document.xml", document(model))
        return zip.finish()
    }

    static func document(_ model: TBDDocumentModel) -> String {
        var body = ""
        for paragraph in model.paragraphs {
            let style: String
            switch paragraph.style {
            case .title: style = "Title"
            case .heading: style = "Heading1"
            case .speaker: style = "Speaker"
            case .meta, .rule: style = "Subtitle"
            case .body: style = "Normal"
            }
            body += "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>"
            for run in paragraph.runs {
                var properties = ""
                if run.bold { properties += "<w:b/>" }
                if run.monospaced { properties += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/><w:sz w:val=\"18\"/>" }
                if run.muted { properties += "<w:color w:val=\"6B7B76\"/>" }
                body += "<w:r>" + (properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>")
                    + "<w:t xml:space=\"preserve\">\(escape(run.text))</w:t></w:r>"
            }
            body += "</w:p>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)\
        <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>\
        </w:body></w:document>
        """
    }

    static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:rPr><w:sz w:val="18"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Speaker"><w:name w:val="Speaker"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:keepNext/><w:spacing w:before="160" w:after="40"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>\
    </w:styles>
    """

    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            // XML 1.0 forbids most control characters.
            case _ where scalar.value < 0x20 && scalar != "\t": continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

/// PDF laid out with CoreText on US Letter pages with one-inch margins; pages break between lines.
enum TBDPDFExport {
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 72

    static func attributed(_ model: TBDDocumentModel) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let paragraphKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
        for paragraph in model.paragraphs {
            let (size, before, after): (CGFloat, CGFloat, CGFloat) = switch paragraph.style {
            case .title: (24, 0, 8)
            case .meta: (11, 0, 2)
            case .rule: (11, 4, 10)
            case .heading: (16, 14, 6)
            case .speaker: (14, 10, 2)
            case .body: (12, 0, 8)
            }
            let start = text.length
            for run in paragraph.runs {
                let font: CTFont
                if run.monospaced {
                    font = CTFontCreateWithName("Menlo" as CFString, 11, nil)
                } else {
                    let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
                    let bold = run.bold || [.title, .heading, .speaker].contains(paragraph.style)
                    font = bold ? (CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base) : base
                }
                // Fixed light-appearance colours so dark mode never bakes white text into the file.
                text.append(NSAttributedString(string: run.text, attributes: [
                    fontKey: font, colorKey: CGColor(gray: run.muted ? 0.42 : 0.08, alpha: 1),
                ]))
            }
            text.append(NSAttributedString(string: "\n"))
            var spacingBefore = before, spacingAfter = after
            let style = withUnsafeBytes(of: &spacingBefore) { beforeBytes in
                withUnsafeBytes(of: &spacingAfter) { afterBytes in
                    let settings = [
                        CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: MemoryLayout<CGFloat>.size, value: beforeBytes.baseAddress!),
                        CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: afterBytes.baseAddress!),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
            text.addAttribute(paragraphKey, value: style, range: NSRange(location: start, length: text.length - start))
        }
        return text
    }

    static func render(_ model: TBDDocumentModel) -> Data {
        let text = attributed(model)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(x: margin, y: margin, width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin),
                          transform: nil)
        var location = 0
        var page = 0
        repeat {
            context.beginPDFPage(nil)
            page += 1
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let footer = NSAttributedString(string: "\(page)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 9, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.5, alpha: 1),
            ])
            context.textPosition = CGPoint(x: pageSize.width / 2 - 3, y: margin / 2)
            CTLineDraw(CTLineCreateWithAttributedString(footer), context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            location += visible.length
        } while location < text.length
        context.closePDF()
        return data as Data
    }
}

/// W3C DAPT (Dubbing and Audio description Profile of TTML2) original transcript.
enum TBDDAPTExport {
    static func render(_ item: TBDTranscription) -> String {
        // Timing is never invented: untimed transcripts become one untimed event.
        let cues = item.words.isEmpty && item.segments.isEmpty ? [] : TBDExport.cues(item)
        var agents: [String: String] = [:]
        var agentOrder: [String] = []
        for speaker in cues.compactMap(\.speaker) where agents[speaker] == nil {
            agents[speaker] = "character_\(agentOrder.count + 1)"
            agentOrder.append(speaker)
        }
        let language = item.language.flatMap { $0.isEmpty ? nil : $0 } ?? "und"
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\" "
        out += "xmlns:ttp=\"http://www.w3.org/ns/ttml#parameter\" xmlns:daptm=\"http://www.w3.org/ns/ttml/profile/dapt#metadata\" "
        out += "ttp:contentProfiles=\"http://www.w3.org/ns/ttml/profile/dapt1.0/content\" xml:lang=\"\(TBDDocxExport.escape(language))\" "
        if language != "und" { out += "daptm:langSrc=\"\(TBDDocxExport.escape(language))\" " }
        out += "daptm:scriptRepresents=\"audio.dialogue\" daptm:scriptType=\"originalTranscript\">\n"
        out += "  <head>\n    <metadata>\n      <ttm:title>\(TBDDocxExport.escape(item.title))</ttm:title>\n"
        for speaker in agentOrder {
            out += "      <ttm:agent type=\"character\" xml:id=\"\(agents[speaker]!)\"><ttm:name type=\"alias\">"
            out += TBDDocxExport.escape(item.speakerLabel(speaker) ?? speaker) + "</ttm:name></ttm:agent>\n"
        }
        out += "    </metadata>\n  </head>\n  <body>\n"
        if cues.isEmpty {
            out += "    <div xml:id=\"event_1\" daptm:represents=\"audio.dialogue\"><p>\(TBDDocxExport.escape(item.text))</p></div>\n"
        }
        for (index, cue) in cues.enumerated() {
            out += "    <div xml:id=\"event_\(index + 1)\" begin=\"\(TBDExport.timestamp(cue.start, vtt: true))\" end=\"\(TBDExport.timestamp(cue.end, vtt: true))\""
            if let speaker = cue.speaker, let agent = agents[speaker] { out += " ttm:agent=\"\(agent)\"" }
            out += " daptm:represents=\"audio.dialogue\"><p>\(TBDDocxExport.escape(cue.text))</p></div>\n"
        }
        out += "  </body>\n</tt>\n"
        return out
    }
}
