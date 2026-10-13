import XCTest
import TBDSpeech
@testable import TBDListening

@MainActor
final class TranscribeVocabularyTests: XCTestCase {
    func testPagesAreInV1RailOrderAndTranscribeIsFirst() {
        XCTAssertEqual(TBDListeningTab.allCases.map(\.rawValue), ["transcribe", "library", "dictations", "meetings", "prompts", "transforms", "vocabulary"])
        XCTAssertEqual(TBDListeningTab.allCases.map(\.title), ["Transcribe", "Library", "Dictations", "Meetings", "Prompts", "Transforms", "Vocabulary"])
        XCTAssertEqual(TBDListeningTab.allCases.first, .transcribe)
    }

    // MARK: Drop

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func testDropCollectsTheExactFileAndFolderURLsInOrder() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("one.wav")
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let providers = [NSItemProvider(object: file as NSURL), NSItemProvider(object: folder as NSURL), NSItemProvider(object: "text" as NSString)]
        let urls = await TBDDropCollector.urls(from: providers)
        XCTAssertEqual(urls.map(\.path), [file.path, folder.path])
    }

    func testDecodeAcceptsFileURLsOnly() {
        let file = URL(fileURLWithPath: "/tmp/a.wav")
        XCTAssertEqual(TBDDropCollector.decode(file.dataRepresentation), file)
        XCTAssertEqual(TBDDropCollector.decode(file), file)
        XCTAssertNil(TBDDropCollector.decode(URL(string: "https://example.com/a.wav")))
        XCTAssertNil(TBDDropCollector.decode("text"))
        XCTAssertNil(TBDDropCollector.decode(nil))
    }

    func testPlanQueuesTheDroppedFileAndTheFilesInTheDroppedFolder() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let single = root.appendingPathComponent("single.wav")
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let part2 = folder.appendingPathComponent("part2.mp3"), part10 = folder.appendingPathComponent("part10.mp3")
        for url in [single, part2, part10, folder.appendingPathComponent("notes.txt")] { try Data("x".utf8).write(to: url) }
        let plan = TBDFileQueue.plan(files: [single, folder])
        XCTAssertEqual(plan.files.map(\.lastPathComponent), ["part2.mp3", "part10.mp3", "single.wav"])
        XCTAssertNil(plan.message)  // unsupported files inside a folder are ignored quietly
        let loose = root.appendingPathComponent("loose.txt")
        try Data("x".utf8).write(to: loose)
        XCTAssertEqual(TBDFileQueue.plan(files: [single, loose]).message, "Some files were skipped: not audio or video.")
        XCTAssertEqual(TBDFileQueue.plan(files: [single]), TBDFileQueue.Plan(files: [single.standardizedFileURL], message: nil))
    }

    func testPlanWithNothingUsableSaysSo() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: text)
        let plan = TBDFileQueue.plan(files: [text])
        XCTAssertEqual(plan.files, [])
        XCTAssertTrue(plan.message?.hasPrefix("Unsupported file type. Supported formats: ") == true)
    }

    // MARK: Link field

    func testLinkFieldValidation() {
        XCTAssertEqual(TBDLinkInput.classify("   "), .empty)
        XCTAssertEqual(TBDLinkInput.classify(" https://www.youtube.com/watch?v=abc "), .link(url: "https://www.youtube.com/watch?v=abc", platform: .youtube))
        XCTAssertEqual(TBDLinkInput.classify("https://example.com/talk.mp3"), .link(url: "https://example.com/talk.mp3", platform: nil))
        XCTAssertEqual(TBDLinkInput.classify("vimeo.com/123"), .link(url: "https://vimeo.com/123", platform: .vimeo))
        XCTAssertEqual(TBDLinkInput.classify("https://podcasts.apple.com/us/podcast/x/id1"), .link(url: "https://podcasts.apple.com/us/podcast/x/id1", platform: .applePodcasts))
        XCTAssertEqual(TBDLinkInput.classify("hard fork 120"), .podcastSearch(query: "hard fork 120"))
        XCTAssertEqual(TBDLinkInput.classify("ftp://vimeo.com/1"), .invalid)
        XCTAssertEqual(TBDLinkInput.classify("https://user:pw@example.com/a"), .invalid)
        XCTAssertEqual(TBDLinkInput.classify("https:///nohost"), .invalid)
        XCTAssertFalse(TBDLinkInput.classify("ftp://vimeo.com/1").canSubmit)
        XCTAssertFalse(TBDLinkInput.classify("").canSubmit)
        XCTAssertTrue(TBDLinkInput.classify("hard fork 120").canSubmit)
        XCTAssertEqual(TBDLinkInput.classify("vimeo.com/123").queueText, "https://vimeo.com/123")
        XCTAssertEqual(TBDLinkInput.classify("https://youtu.be/abc").title, "Transcribe YouTube")
        XCTAssertEqual(TBDLinkInput.classify("").title, "Transcribe YouTube & more")
    }

    func testPlatformRecognitionUsesHostSuffixes() {
        XCTAssertEqual(TBDMediaPlatform.recognize("https://m.youtube.com/watch?v=1%"), .youtube)
        XCTAssertEqual(TBDMediaPlatform.recognize("https://notyoutube.com/x"), nil)
        XCTAssertEqual(TBDMediaPlatform.recognize("https://twitter.com/a/status/1"), .x)
        XCTAssertTrue(TBDMediaPlatform.soundcloud.isAudioFirst)
        XCTAssertFalse(TBDMediaPlatform.tiktok.isAudioFirst)
    }

    // MARK: Vocabulary page model

    func testModelRefusesDuplicatesAndKeepsExactRows() throws {
        let model = TBDVocabularyModel(database: try TBDListeningDatabase(inMemory: ()))
        XCTAssertTrue(model.addWord("  chat gpt ", replacement: " ChatGPT "))
        XCTAssertFalse(model.addWord("CHAT GPT", replacement: "x"))
        XCTAssertEqual(model.wordError, "'CHAT GPT' already exists")
        XCTAssertEqual(model.words.map { "\($0.word)=\($0.replacement ?? "-")" }, ["chat gpt=ChatGPT"])
        XCTAssertTrue(model.addWord("kubernetes", replacement: "  "))
        XCTAssertNil(model.words.last?.replacement)
        model.toggle(model.words[0])
        XCTAssertEqual(model.words.map(\.isEnabled), [false, true])
        model.wordQuery = "kube"
        XCTAssertEqual(model.filteredWords.map(\.word), ["kubernetes"])
        model.delete(model.words[0])
        XCTAssertEqual(model.words.map(\.word), ["kubernetes"])

        XCTAssertTrue(model.addSnippet(trigger: "sig", expansion: "Best\\nMe"))
        XCTAssertEqual(model.snippets.map(\.expansion), ["Best\nMe"])
        XCTAssertFalse(model.addSnippet(trigger: "SIG", expansion: "x"))
        XCTAssertEqual(model.snippetError, "'SIG' already exists")
        XCTAssertTrue(model.addSnippet(trigger: "addr", expansion: "1 Main"))
        let id = try XCTUnwrap(model.snippets.first { $0.trigger == "addr" }?.id)
        XCTAssertFalse(model.updateSnippet(id: id, trigger: "sig", expansion: "y"))
        XCTAssertTrue(model.updateSnippet(id: id, trigger: "address", expansion: "2 Main"))
        XCTAssertEqual(model.snippets.map { "\($0.trigger)=\($0.expansion)" }, ["address=2 Main", "sig=Best\nMe"])
        XCTAssertEqual(TBDVocabularyModel.editable("a\nb"), "a\\nb")
    }

    func testModelImportFlowReportsTheResult() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("v.json")
        try Data(#"{"schema":"macparakeet.vocabulary","version":1,"exportedAt":"2026-01-01T00:00:00Z","customWords":[{"word":"a","isEnabled":true},{"word":"b","isEnabled":true}],"textSnippets":[]}"#.utf8).write(to: file)
        let model = TBDVocabularyModel(database: try TBDListeningDatabase(inMemory: ()))
        var changes = 0
        model.onChange = { changes += 1 }
        model.loadPreview(from: file)
        XCTAssertEqual(model.pendingImport?.wordsTotal, 2)
        XCTAssertTrue(model.applyImport())
        XCTAssertEqual(model.words.map(\.word), ["a", "b"])
        XCTAssertEqual(changes, 1)
        guard case .imported(let result) = model.backupStatus else { return XCTFail("expected imported") }
        XCTAssertEqual(TBDVocabularyModel.summary(of: result), "Added 2 words and 0 snippets.")
        model.loadPreview(from: root.appendingPathComponent("missing.json"))
        guard case .failed(let message) = model.backupStatus else { return XCTFail("expected failure") }
        XCTAssertTrue(message.hasPrefix("Could not read the file: "))
        XCTAssertEqual(TBDVocabularyModel.summary(of: TBDVocabularyBackup.Result()), "Nothing to import. The file matched your vocabulary.")
    }
}
