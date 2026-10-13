import XCTest
@testable import TBDSpeech

final class VocabularyTests: XCTestCase {
    private func memory() throws -> TBDListeningDatabase { try TBDListeningDatabase(inMemory: ()) }
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Processing mode in the pipeline

    private let words = [TBDCustomWord(word: "chat gpt", replacement: "ChatGPT")]
    private let snippets = [TBDSnippet(trigger: "my address", expansion: "1 Main Street")]
    private let spoken = "um ask chat gpt about my address question mark"

    func testRawModeReturnsTheInputUnchanged() {
        let result = TBDTextPipeline().process(spoken, customWords: words, snippets: snippets, mode: .raw)
        XCTAssertEqual(result.text, spoken)
        XCTAssertEqual(result.expandedSnippetIDs, [])
        XCTAssertEqual(TBDTextPipeline().process("  keep   spacing  ", mode: .raw).text, "  keep   spacing  ")
    }

    func testCleanModeAppliesFillersWordsAndSnippetsAsBefore() {
        let result = TBDTextPipeline().process(spoken, customWords: words, snippets: snippets, mode: .clean)
        XCTAssertEqual(result.text, "Ask ChatGPT about 1 Main Street?")
        XCTAssertEqual(result.expandedSnippetIDs, [snippets[0].id])
        // The default mode is Clean, so existing callers see no change.
        XCTAssertEqual(TBDTextPipeline().process(spoken, customWords: words, snippets: snippets).text, result.text)
    }

    func testSpokenPunctuationOnAndOff() {
        let on = TBDTextPipeline().process("is it ready question mark new line yes", mode: .clean, spokenPunctuation: true)
        XCTAssertEqual(on.text, "Is it ready?\nyes")
        let off = TBDTextPipeline().process("is it ready question mark new line yes", mode: .clean, spokenPunctuation: false)
        XCTAssertEqual(off.text, "Is it ready question mark new line yes")
    }

    func testActionSnippetsNeverExpandToText() {
        let action = TBDSnippet(trigger: "send it", expansion: "Return", action: .returnKey)
        let result = TBDTextPipeline().process("please send it now", snippets: [action])
        XCTAssertEqual(result.text, "Please send it now")
        XCTAssertEqual(result.expandedSnippetIDs, [])
    }

    func testLegacyModeNamesMeanClean() {
        XCTAssertEqual(TBDProcessingMode(rawValue: "raw"), .raw)
        for legacy in ["clean", "formal", "email", "code"] { XCTAssertEqual(TBDProcessingMode(rawValue: legacy), .clean) }
        XCTAssertNil(TBDProcessingMode(rawValue: "loud"))
    }

    func testPreferencesDefaultToRawWithSpokenPunctuationOn() throws {
        let suite = "tbd.tests.vocab.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = TBDListeningPreferences(defaults: defaults)
        XCTAssertEqual(prefs.processingMode, .raw)
        XCTAssertTrue(prefs.spokenPunctuation)
        prefs.processingMode = .clean
        prefs.spokenPunctuation = false
        XCTAssertEqual(prefs.processingSettings, TBDProcessingSettings(mode: .clean, spokenPunctuation: false, removeFillers: true))
        defaults.set("formal", forKey: "tbd.listening.processingMode")
        XCTAssertEqual(prefs.processingMode, .clean)
        defaults.set("garbage", forKey: "tbd.listening.processingMode")
        XCTAssertEqual(prefs.processingMode, .raw)
    }

    // MARK: Files and meetings

    private func transcript(_ text: String) -> TBDTranscript {
        TBDTranscript(text: text, words: [], language: "en", engine: "test", durationMs: 1000)
    }

    func testFileRawKeepsTextAndSkipsVocabulary() throws {
        let db = try memory()
        try db.save(TBDCustomWord(word: "chat gpt", replacement: "ChatGPT"))
        let transcriber = TBDTranscriber(database: db, processing: { TBDProcessingSettings(mode: .raw) })
        var item = TBDTranscription(title: "t", sourceKind: .file)
        try transcriber.apply(transcript("um ask chat gpt question mark"), words: [], to: &item)
        XCTAssertEqual(item.rawText, "um ask chat gpt question mark")
        XCTAssertNil(item.cleanText)
    }

    func testFileCleanRunsTheFullPipelineAndCountsSnippetUse() throws {
        let db = try memory()
        try db.save(TBDCustomWord(word: "chat gpt", replacement: "ChatGPT"))
        let snippet = TBDSnippet(trigger: "my address", expansion: "1 Main Street")
        try db.save(snippet)
        let transcriber = TBDTranscriber(database: db, processing: { TBDProcessingSettings(mode: .clean) })
        var item = TBDTranscription(title: "t", sourceKind: .url)
        try transcriber.apply(transcript("um ask chat gpt about my address question mark"), words: [], to: &item)
        XCTAssertEqual(item.rawText, "um ask chat gpt about my address question mark")
        XCTAssertEqual(item.cleanText, "Ask ChatGPT about 1 Main Street?")
        XCTAssertEqual(try db.snippets().first?.useCount, 1)

        var plain = TBDTranscription(title: "t", sourceKind: .file)
        try TBDTranscriber(database: db, processing: { TBDProcessingSettings(mode: .clean, spokenPunctuation: false) })
            .apply(transcript("is it ready question mark"), words: [], to: &plain)
        XCTAssertEqual(plain.cleanText, "Is it ready question mark")
    }

    func testMeetingsGetCustomWordsOnlyInEveryMode() throws {
        let db = try memory()
        try db.save(TBDCustomWord(word: "chat gpt", replacement: "ChatGPT"))
        for mode in TBDProcessingMode.allCases {
            let transcriber = TBDTranscriber(database: db, processing: { TBDProcessingSettings(mode: mode) })
            var item = TBDTranscription(title: "m", sourceKind: .meeting)
            try transcriber.apply(transcript("um ask chat gpt question mark"), words: [], to: &item)
            XCTAssertEqual(item.cleanText, "um ask ChatGPT question mark", "mode \(mode)")
        }
    }

    // MARK: Backup

    private func seeded() throws -> TBDListeningDatabase {
        let db = try memory()
        var word = TBDCustomWord(word: "chat gpt", replacement: "ChatGPT"); word.createdAt = fixedDate
        var off = TBDCustomWord(word: "kubernetes", isEnabled: false); off.createdAt = fixedDate
        var address = TBDSnippet(trigger: "my address", expansion: "1 Main Street\nTown"); address.createdAt = fixedDate
        var send = TBDSnippet(trigger: "send it", expansion: "Return", isEnabled: false, action: .returnKey); send.createdAt = fixedDate
        try db.save(word); try db.save(off); try db.save(address); try db.save(send)
        return db
    }

    func testExportThenImportGivesIdenticalWordsAndSnippets() throws {
        let source = try seeded()
        let export = try TBDVocabularyBackup(database: source, clock: { self.fixedDate }).exportData()
        let target = try memory()
        let backup = TBDVocabularyBackup(database: target, clock: { self.fixedDate })
        let result = try backup.apply(try backup.preview(from: export.data), policy: .skip)
        var expected = TBDVocabularyBackup.Result()
        expected.wordsAdded = 2; expected.snippetsAdded = 2
        XCTAssertEqual(result, expected)
        func rows(_ db: TBDListeningDatabase) throws -> [String] {
            try db.customWords().map { "\($0.word)|\($0.replacement ?? "-")|\($0.isEnabled)|\($0.createdAt.timeIntervalSince1970)" }
                + db.snippets().map { "\($0.trigger)|\($0.expansion)|\($0.isEnabled)|\($0.action?.rawValue ?? "-")|\($0.createdAt.timeIntervalSince1970)" }
        }
        XCTAssertEqual(try rows(target), try rows(source))
        XCTAssertEqual(try rows(source), [
            "chat gpt|ChatGPT|true|1700000000.0", "kubernetes|-|false|1700000000.0",
            "my address|1 Main Street\nTown|true|-|1700000000.0", "send it|Return|false|return|1700000000.0",
        ])
    }

    func testExportUsesV1FieldNamesAndFilename() throws {
        let backup = TBDVocabularyBackup(database: try seeded(), appVersion: "9.9", clock: { self.fixedDate })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try backup.exportData().data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "version", "exportedAt", "appVersion", "customWords", "textSnippets"])
        XCTAssertEqual(object["schema"] as? String, "macparakeet.vocabulary")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["exportedAt"] as? String, "2023-11-14T22:13:20Z")
        let word = try XCTUnwrap((object["customWords"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(word.keys), ["word", "replacement", "isEnabled", "createdAt"])
        let snippets = try XCTUnwrap(object["textSnippets"] as? [[String: Any]])
        XCTAssertEqual(Set(snippets[1].keys), ["trigger", "expansion", "isEnabled", "action", "createdAt"])
        XCTAssertEqual(snippets[1]["action"] as? String, "return")
        XCTAssertEqual(backup.suggestedFilename(), "TBD-Vocabulary-2023-11-14.json")
    }

    /// Built from the field names of v1's `VocabularyBundle` encoder (ISO 8601 dates, nil fields left out).
    private let v1File = """
    {
      "appVersion" : "0.1.6",
      "customWords" : [
        { "createdAt" : "2026-01-02T03:04:05Z", "isEnabled" : true, "replacement" : "Teal Brick", "word" : "  tealbrick " },
        { "isEnabled" : false, "word" : "Kubernetes" }
      ],
      "exportedAt" : "2026-02-03T04:05:06Z",
      "schema" : "macparakeet.vocabulary",
      "textSnippets" : [
        { "action" : "return", "createdAt" : "2026-01-02T03:04:05Z", "expansion" : "Return", "isEnabled" : true, "trigger" : "send it" },
        { "expansion" : "Line one\\\\nLine two", "isEnabled" : true, "trigger" : "sig" }
      ],
      "version" : 1
    }
    """

    func testImportsAV1FormatFileAsExactRows() throws {
        let db = try memory()
        let backup = TBDVocabularyBackup(database: db, clock: { self.fixedDate })
        let preview = try backup.preview(from: Data(v1File.utf8))
        XCTAssertEqual(preview.wordsTotal, 2)
        XCTAssertEqual(preview.snippetsTotal, 2)
        XCTAssertFalse(preview.hasConflicts)
        _ = try backup.apply(preview, policy: .skip)
        let words = try db.customWords()
        XCTAssertEqual(words.map(\.word), ["Kubernetes", "tealbrick"])
        XCTAssertEqual(words.map(\.replacement), [nil, "Teal Brick"])
        XCTAssertEqual(words.map(\.isEnabled), [false, true])
        XCTAssertEqual(words[1].createdAt, ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        XCTAssertEqual(words[0].createdAt, fixedDate)
        let snippets = try db.snippets()
        XCTAssertEqual(snippets.map(\.trigger), ["send it", "sig"])
        XCTAssertEqual(snippets.map(\.expansion), ["Return", "Line one\nLine two"])
        XCTAssertEqual(snippets.map(\.action), [.returnKey, nil])
    }

    func testImportDedupesWithinTheFileAndAgainstWhatExists() throws {
        let db = try memory()
        try db.save(TBDCustomWord(word: "Alpha", replacement: "A"))
        let file = """
        {"schema":"macparakeet.vocabulary","version":1,"exportedAt":"2026-01-01T00:00:00Z",
         "customWords":[{"word":"alpha","replacement":"X","isEnabled":true},{"word":"Beta","isEnabled":true},{"word":"BETA","replacement":"Y","isEnabled":true}],
         "textSnippets":[{"trigger":"Sig","expansion":"one","isEnabled":true},{"trigger":"sig","expansion":"two","isEnabled":true}]}
        """
        let backup = TBDVocabularyBackup(database: db)
        let preview = try backup.preview(from: Data(file.utf8))
        XCTAssertEqual(preview.wordConflicts, ["alpha"])
        XCTAssertEqual(preview.duplicateWords, ["BETA"])
        XCTAssertEqual(preview.duplicateSnippets, ["sig"])
        let result = try backup.apply(preview, policy: .skip)
        var expected = TBDVocabularyBackup.Result()
        expected.wordsAdded = 1; expected.wordsSkipped = 2; expected.snippetsAdded = 1; expected.snippetsSkipped = 1
        XCTAssertEqual(result, expected)
        XCTAssertEqual(try db.customWords().map { "\($0.word)=\($0.replacement ?? "-")" }, ["Alpha=A", "Beta=-"])
        XCTAssertEqual(try db.snippets().map { "\($0.trigger)=\($0.expansion)" }, ["Sig=one"])
        // Importing the same file again adds nothing.
        let again = try backup.apply(try backup.preview(from: Data(file.utf8)), policy: .skip)
        XCTAssertEqual(again.wordsAdded + again.snippetsAdded, 0)
    }

    func testReplaceTakesTheFilesEntries() throws {
        let db = try memory()
        try db.save(TBDCustomWord(word: "Alpha", replacement: "A"))
        let file = #"{"schema":"macparakeet.vocabulary","version":1,"exportedAt":"2026-01-01T00:00:00Z","customWords":[{"word":"alpha","replacement":"X","isEnabled":true}],"textSnippets":[]}"#
        let backup = TBDVocabularyBackup(database: db)
        let result = try backup.apply(try backup.preview(from: Data(file.utf8)), policy: .replace)
        XCTAssertEqual(result.wordsReplaced, 1)
        XCTAssertEqual(try db.customWords().map { "\($0.word)=\($0.replacement ?? "-")" }, ["alpha=X"])
    }

    func testReplaceAllDeletesWhatTheFileLacksAndRefusesAStalePreview() throws {
        let db = try seeded()
        let file = #"{"schema":"macparakeet.vocabulary","version":1,"exportedAt":"2026-01-01T00:00:00Z","customWords":[{"word":"chat gpt","replacement":"GPT","isEnabled":true}],"textSnippets":[]}"#
        let backup = TBDVocabularyBackup(database: db)
        let preview = try backup.preview(from: Data(file.utf8))
        XCTAssertEqual(preview.wordsRemoved, ["kubernetes"])
        XCTAssertEqual(preview.snippetsRemoved, ["my address", "send it"])
        try db.save(TBDCustomWord(word: "late"))
        XCTAssertThrowsError(try backup.apply(preview, policy: .replaceAll)) { XCTAssertEqual($0 as? TBDVocabularyBackup.ImportError, .stalePreview) }
        let fresh = try backup.preview(from: Data(file.utf8))
        let result = try backup.apply(fresh, policy: .replaceAll)
        XCTAssertEqual(result.wordsRemoved, 2)
        XCTAssertEqual(result.snippetsRemoved, 2)
        XCTAssertEqual(try db.customWords().map { "\($0.word)=\($0.replacement ?? "-")" }, ["chat gpt=GPT"])
        XCTAssertEqual(try db.snippets().count, 0)
    }

    func testBadFilesAreRefusedWithExactErrors() throws {
        let backup = TBDVocabularyBackup(database: try memory())
        func failure(_ json: String) -> TBDVocabularyBackup.ImportError? {
            do { _ = try backup.preview(from: Data(json.utf8)); return nil } catch { return error as? TBDVocabularyBackup.ImportError }
        }
        XCTAssertEqual(failure(#"{"schema":"other","version":1,"exportedAt":"2026-01-01T00:00:00Z","customWords":[],"textSnippets":[]}"#), .invalidSchema)
        XCTAssertEqual(failure(#"{"schema":"macparakeet.vocabulary","version":2,"exportedAt":"2026-01-01T00:00:00Z","customWords":[],"textSnippets":[]}"#),
                       .unsupportedVersion(found: 2, supported: 1))
        XCTAssertEqual(failure(#"{"schema":"macparakeet.vocabulary","version":1,"exportedAt":"2026-01-01T00:00:00Z","customWords":[{"word":"  ","isEnabled":true}],"textSnippets":[]}"#),
                       .invalidEntry("customWords[0].word must not be empty."))
        XCTAssertEqual(failure(#"{"schema":"macparakeet.vocabulary","version":1,"exportedAt":"2026-01-01T00:00:00Z","customWords":[],"textSnippets":[{"trigger":"a","expansion":" ","isEnabled":true}]}"#),
                       .invalidEntry("textSnippets[0].expansion must not be empty."))
        if case .decodingFailed? = failure("not json") {} else { XCTFail("expected decodingFailed") }
        let empty = #"{"schema":"macparakeet.vocabulary","version":1,"exportedAt":"2026-01-01T00:00:00Z","customWords":[],"textSnippets":[]}"#
        let preview = try backup.preview(from: Data(empty.utf8))
        XCTAssertThrowsError(try backup.apply(preview, policy: .replaceAll)) { XCTAssertEqual($0 as? TBDVocabularyBackup.ImportError, .emptyReplaceAll) }
    }
}
