import ArgumentParser
import XCTest
@testable import TBDListenCLI
@testable import TBDSpeech

/// `tbd-listen` argument parsing and the JSON contract of the engine/model/library commands.
final class ListenCLITests: XCTestCase {
    private func parse<T: ParsableCommand>(_ arguments: [String], as type: T.Type, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let command = try TBDListen.parseAsRoot(arguments)
        return try XCTUnwrap(command as? T, "parsed \(Swift.type(of: command))", file: file, line: line)
    }

    private func keys(_ json: String) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        if let array = object as? [[String: Any]] { return Set(array.first?.keys.map { $0 } ?? []) }
        return Set((object as? [String: Any])?.keys.map { $0 } ?? [])
    }

    private func scratchPreferences() -> TBDListeningPreferences {
        let name = "tbd.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return TBDListeningPreferences(defaults: defaults)
    }

    // MARK: Parsing

    func testTranscribeOptions() throws {
        let command = try parse(["transcribe", "talk.m4a", "--engine", "cohere", "--format", "vtt", "--language", "fr", "--no-save"], as: Transcribe.self)
        XCTAssertEqual(command.input, "talk.m4a")
        XCTAssertEqual(command.engine, "cohere")
        XCTAssertEqual(command.format, "vtt")
        XCTAssertEqual(command.language, "fr")
        XCTAssertTrue(command.noSave)
        XCTAssertFalse(command.podcast)
        let podcast = try parse(["transcribe", "--podcast", "hard fork 120", "--json"], as: Transcribe.self)
        XCTAssertTrue(podcast.podcast && podcast.json)
        XCTAssertThrowsError(try TBDListen.parseAsRoot(["transcribe", "a.wav", "--format", "docx"]))
        XCTAssertThrowsError(try TBDListen.parseAsRoot(["transcribe", "a.wav", "--engine", "mlx"]))
    }

    func testTranscribeInputClassification() throws {
        let exists: (String) -> Bool = { $0.hasSuffix("talk.m4a") }
        XCTAssertEqual(try TranscribeInput.parse("/tmp/talk.m4a", podcast: false, fileExists: exists), .file(URL(fileURLWithPath: "/tmp/talk.m4a")))
        XCTAssertEqual(try TranscribeInput.parse("https://podcasts.apple.com/us/podcast/x/id1", podcast: false, fileExists: exists),
                       .link(URL(string: "https://podcasts.apple.com/us/podcast/x/id1")!))
        XCTAssertEqual(try TranscribeInput.parse("hard fork 120", podcast: true, fileExists: exists), .podcastSearch("hard fork 120"))
        XCTAssertEqual(try TranscribeInput.parse("https://cdn.example.com/a.mp3", podcast: true, fileExists: exists),
                       .link(URL(string: "https://cdn.example.com/a.mp3")!), "a link stays a link with --podcast")
        XCTAssertThrowsError(try TranscribeInput.parse("missing.wav", podcast: false, fileExists: exists))
        XCTAssertThrowsError(try TranscribeInput.parse("  ", podcast: true, fileExists: exists))
    }

    func testSubcommandsParse() throws {
        XCTAssertTrue(try parse(["engines", "list", "--json"], as: Engines.List.self).json)
        XCTAssertNotNil(try TBDListen.parseAsRoot(["engines"]) as? Engines.List, "list is the default")
        XCTAssertEqual(try parse(["models", "download", "nemotron-english"], as: Models.Download.self).id, "nemotron-english")
        XCTAssertTrue(try parse(["models", "status", "--json"], as: Models.Status.self).json)
        XCTAssertNotNil(try TBDListen.parseAsRoot(["models"]) as? Models.List)
        XCTAssertThrowsError(try TBDListen.parseAsRoot(["models", "delete", "cohere-transcribe"]), "--yes is required")
        XCTAssertTrue(try parse(["models", "delete", "cohere-transcribe", "--yes"], as: Models.DeleteModel.self).yes)
        XCTAssertThrowsError(try TBDListen.parseAsRoot(["delete", "abc"]), "--yes is required")
        let delete = try parse(["delete", "abc", "--yes", "--dictation"], as: Delete.self)
        XCTAssertTrue(delete.dictation)
        let export = try parse(["export", "abc", "--format", "srt", "-o", "/tmp"], as: Export.self)
        XCTAssertEqual(export.format, "srt")
        XCTAssertEqual(export.output, "/tmp")
        XCTAssertEqual(try parse(["vocabulary", "add", "Teal Brick", "--replacement", "TealBrick"], as: Vocabulary.Add.self).replacement, "TealBrick")
        XCTAssertEqual(try parse(["vocabulary", "remove", "Teal Brick"], as: Vocabulary.Remove.self).word, "Teal Brick")
        XCTAssertNotNil(try TBDListen.parseAsRoot(["vocabulary"]) as? Vocabulary.List)
        let snippet = try parse(["snippets", "add", "my address", "1 Main St"], as: Snippets.Add.self)
        XCTAssertEqual(snippet.trigger, "my address")
        XCTAssertEqual(snippet.expansion, "1 Main St")
        XCTAssertNotNil(try TBDListen.parseAsRoot(["snippets", "remove", "my address"]) as? Snippets.Remove)
        XCTAssertEqual(try parse(["config", "set", "finalEngine", "cohere"], as: Config.Set.self).value, "cohere")
        XCTAssertEqual(try parse(["config", "get", "liveEngine"], as: Config.Get.self).key, "liveEngine")
        XCTAssertNotNil(try TBDListen.parseAsRoot(["config"]) as? Config.ShowAll)
        XCTAssertTrue(try parse(["stats", "--json"], as: Stats.self).json)
        XCTAssertEqual(try parse(["history", "--limit", "5", "--query", "hello"], as: History.self).query, "hello")
        XCTAssertEqual(try parse(["search", "budget", "--kind", "meeting"], as: Search.self).kind, "meeting")
        XCTAssertEqual(try parse(["podcasts", "search", "hard", "fork"], as: Podcasts.SearchShows.self).query, ["hard", "fork"])
        XCTAssertNotNil(try TBDListen.parseAsRoot(["podcasts", "resolve", "hard fork 120"]) as? Podcasts.Resolve)
        XCTAssertNotNil(try TBDListen.parseAsRoot(["show", "abc", "--format", "md"]) as? Show)
        XCTAssertNotNil(try TBDListen.parseAsRoot(["meetings", "--json"]) as? Meetings)
    }

    // MARK: JSON shapes

    func testEngineJSONShape() throws {
        let prefs = scratchPreferences()
        prefs.finalEngineOverride = .cohere
        let infos = engineInfos(prefs)
        XCTAssertEqual(infos.count, TBDSpeechEngineKind.allCases.count)
        let json = TBDListenJSON.encode(infos)
        XCTAssertEqual(try keys(json), ["id", "cliID", "name", "model", "summary", "languageMode", "defaultLanguage", "languages",
                                        "wordTimestamps", "streaming", "livePreview", "diarization", "meetingLivePreview",
                                        "approximateBytes", "minimumMemoryBytes", "memoryOK", "downloaded", "live", "final"])
        XCTAssertTrue(json.contains("\"minimumMemoryBytes\" : null"), "nil fields are present as null")
        XCTAssertEqual(infos.first { $0.live }?.id, "parakeetV3")
        XCTAssertEqual(infos.first { $0.final }?.id, "cohere")
        let cohere = try XCTUnwrap(infos.first { $0.id == "cohere" })
        XCTAssertFalse(cohere.wordTimestamps)
        XCTAssertFalse(cohere.diarization)
    }

    func testModelJSONShapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-models-\(UUID().uuidString)")
        let manager = TBDModelManager(modelsRoot: root)
        let models = TBDModelManager.Model.allCases.map { Models.info($0, manager: manager) }
        XCTAssertEqual(try keys(TBDListenJSON.encode(models)), ["id", "model", "title", "engine", "downloaded", "bytes", "approximateBytes", "path"])
        XCTAssertTrue(TBDListenJSON.encode(models.last!).contains("\"engine\" : null"), "support models have no engine")
        let status = TBDListenJSON.ModelsStatus(liveEngine: .parakeetV3, finalEngine: .whisper, liveReady: false, finalReady: false,
                                                vadReady: false, speakerDetectionReady: false, totalBytes: 0, modelsPath: root.path, models: models)
        XCTAssertEqual(try keys(TBDListenJSON.encode(status)), ["schemaVersion", "liveEngine", "finalEngine", "liveReady", "finalReady", "vadReady",
                                                                "speakerDetectionReady", "totalBytes", "modelsPath", "models"])
    }

    func testLibraryJSONShapes() throws {
        let word = TBDListenJSON.encode([TBDListenJSON.CustomWord(TBDCustomWord(word: "tbd"))])
        XCTAssertEqual(try keys(word), ["id", "word", "replacement", "enabled"])
        XCTAssertTrue(word.contains("\"replacement\" : null"))
        let snippet = TBDListenJSON.encode([TBDListenJSON.Snippet(TBDSnippet(trigger: "sig", expansion: "Best"))])
        XCTAssertEqual(try keys(snippet), ["id", "trigger", "expansion", "enabled", "useCount"])
        let deleted = TBDListenJSON.encode(TBDListenJSON.Deleted(id: "a", kind: "transcription", deleted: true, removedFiles: []))
        XCTAssertEqual(try keys(deleted), ["id", "kind", "deleted", "removedFiles"])
        var meeting = TBDTranscription(title: "Call", sourceKind: .meeting, status: .completed)
        meeting.durationMs = 60_000
        let stats = TBDListenJSON.Stats(dictation: .init(count: 2, words: 20, durationMs: 10_000, today: 1), transcriptions: [meeting],
                                        modelsBytes: 5, storageBytes: 9)
        let statsJSON = TBDListenJSON.encode(stats)
        XCTAssertEqual(try keys(statsJSON), ["schemaVersion", "dictations", "dictationWords", "dictationDurationMs", "dictationsToday",
                                             "wordsPerMinute", "transcriptions", "transcriptionsByKind", "transcriptionDurationMs",
                                             "modelsBytes", "storageBytes"])
        XCTAssertEqual(stats.transcriptionsByKind, ["file": 0, "url": 0, "meeting": 1, "voiceNote": 0])
        XCTAssertEqual(stats.wordsPerMinute, 120)
        let episode = TBDListenJSON.encode(TBDPodcastEpisode(audioURL: "https://a/b.mp3", title: "Ep"))
        XCTAssertTrue(try keys(episode).isSuperset(of: ["audioURL", "title"]))
    }

    // MARK: Config

    func testConfigGetSet() throws {
        let prefs = scratchPreferences()
        XCTAssertEqual(try prefs.configValue("liveEngine"), .string("parakeetV3"))
        XCTAssertEqual(try prefs.configValue("finalEngine"), .null, "follows live")
        try prefs.setConfig("finalEngine", to: "nemotron-english")
        XCTAssertEqual(prefs.finalEngine, .nemotronEnglish)
        try prefs.setConfig("finalEngine", to: "live")
        XCTAssertNil(prefs.finalEngineOverride)
        try prefs.setConfig("liveEngine", to: "parakeet-unified")
        XCTAssertEqual(prefs.liveEngine, .parakeetUnified)
        try prefs.setConfig("dictationLivePreview", to: "off")
        XCTAssertEqual(try prefs.configValue("dictationLivePreview"), .bool(false))
        try prefs.setConfig("cohereLanguage", to: "ja")
        XCTAssertEqual(prefs.cohereLanguage, "ja")
        XCTAssertThrowsError(try prefs.setConfig("cohereLanguage", to: "sv"), "Cohere does not support Swedish")
        try prefs.setConfig("whisperLanguage", to: "ko-KR")
        XCTAssertEqual(prefs.whisperLanguage, "ko")
        try prefs.setConfig("whisperLanguage", to: "auto")
        XCTAssertNil(prefs.whisperLanguage)
        XCTAssertThrowsError(try prefs.setConfig("keepAudio", to: "maybe"))
        XCTAssertThrowsError(try prefs.setConfig("liveEngine", to: "mlx"))
        XCTAssertThrowsError(try prefs.configValue("apiKey")) { error in
            XCTAssertEqual(error as? TBDConfigError, .unknownKey("apiKey"))
        }
        let snapshot = prefs.configSnapshot()
        XCTAssertEqual(snapshot.map(\.key), TBDListeningPreferences.configKeys)
        let json = TBDListenJSON.encode(Dictionary(uniqueKeysWithValues: snapshot.map { ($0.key, $0.value) }))
        XCTAssertEqual(try keys(json), Set(TBDListeningPreferences.configKeys))
        XCTAssertEqual(try keys(TBDListenJSON.encode(TBDListenJSON.ConfigEntry(key: "keepAudio", value: .bool(true)))), ["key", "value"])
    }

    func testLanguageOverrideIsNotWritten() {
        let prefs = scratchPreferences()
        prefs.overridingLanguage("de", for: .nemotronMultilingual)
        XCTAssertEqual(prefs.nemotronLanguage, "de")
        XCTAssertNil(prefs.defaults.persistentDomain(forName: UserDefaults.argumentDomain)?["tbd.listening.nemotronLanguage"])
        prefs.defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        XCTAssertNil(prefs.nemotronLanguage)
    }
}
