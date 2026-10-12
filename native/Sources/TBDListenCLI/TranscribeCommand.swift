import ArgumentParser
import Foundation
import TBDSpeech

/// What `transcribe` was given.
enum TranscribeInput: Equatable {
    case file(URL)
    case link(URL)
    case podcastSearch(String)

    /// A file path that exists, an http(s) link, or (with `podcast`) free-text podcast search.
    static func parse(_ text: String, podcast: Bool, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> TranscribeInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if podcast {
            if let url = TBDLinkDownloader.validate(trimmed) { return .link(url) }
            guard !trimmed.isEmpty else { throw ValidationError("Give a podcast name and episode, for example \"hard fork 120\".") }
            return .podcastSearch(trimmed)
        }
        let path = (trimmed as NSString).expandingTildeInPath
        if fileExists(path) { return .file(URL(fileURLWithPath: path)) }
        if let url = TBDLinkDownloader.validate(trimmed) { return .link(url) }
        throw ValidationError("File not found: \(text). For a podcast search add --podcast.")
    }
}

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe a file, link or podcast episode and save it to the library.",
        discussion: """
        INPUT is an audio or video file, an http(s) link (Apple Podcasts links and direct audio files are \
        downloaded directly; other pages need yt-dlp on PATH) or, with --podcast, a podcast name and episode \
        such as "hard fork 120" (looked up in the Apple Podcasts directory and the show's RSS feed).
        """)

    @Argument(help: "File, link, or podcast search words with --podcast.") var input: String
    @Flag(help: "Treat INPUT as a podcast search (show name and episode words or number).") var podcast = false
    @Option(help: "Engine id (see `tbd-listen engines list`). Default: the app's final engine.") var engine: String?
    @Option(help: "Language for engines that take one (Whisper, Nemotron Multilingual, Cohere), e.g. en, de, ko.") var language: String?
    @Option(help: "Output format: txt, md, srt, vtt or json (full transcript).") var format = "txt"
    @Flag(help: "Print the stable transcribe result JSON (see README).") var json = false
    @Flag(name: .customLong("no-save"), help: "Do not save the result to the library.") var noSave = false
    @Flag(help: "Keep the downloaded audio of links and podcasts.") var keepAudio = false

    func validate() throws {
        _ = try parseFormat(format)
        if let engine, TBDSpeechEngineKind(identifier: engine) == nil {
            throw ValidationError("Unknown engine \(engine). Use one of: \(TBDSpeechEngineKind.allCases.map(\.cliID).joined(separator: ", ")).")
        }
    }

    func run() async throws {
        let format = try parseFormat(format)
        let source = try TranscribeInput.parse(input, podcast: podcast)
        let preferences = appPreferences
        if let engine, let kind = TBDSpeechEngineKind(identifier: engine) { preferences.overridingEngine(kind) }
        let kind = preferences.finalEngine
        if let language { preferences.overridingLanguage(language, for: kind) }
        guard TBDModelManager(preferences: preferences).isDownloaded(engine: kind) else {
            throw ValidationError("\(kind.displayName) is not downloaded. Run `tbd-listen models download \(kind.cliID)` first.")
        }
        if !kind.capabilities.wordTimestamps, format == .srt || format == .vtt {
            status("Note: \(kind.displayName) has no word timestamps; subtitles get one cue per segment.")
        }
        let database = noSave ? try TBDListeningDatabase(inMemory: ()) : try TBDListeningDatabase()
        let speech = TBDSpeechService(preferences: preferences)
        let transcriber = TBDTranscriber(speech: speech, database: database)
        let progress: TBDTranscriber.Progress? = json ? nil : reportProgress
        let item: TBDTranscription
        var reported = ""
        switch source {
        case .file(let url):
            reported = url.path
            item = try await transcriber.transcribe(file: url, progress: progress)
        case .link, .podcastSearch:
            let link: URL
            if case .link(let url) = source { link = url } else { link = TBDLinkDownloader.podcastSearchLink(input)! }
            if !json { status(TBDPodcastURL.isApplePodcasts(link.absoluteString) || link.scheme == TBDLinkDownloader.podcastSearchScheme
                              ? "Looking up the podcast…" : "Downloading…") }
            let download = try await TBDLinkDownloader().download(link, into: TBDListeningPaths.downloads)
            defer { try? FileManager.default.removeItem(at: download.file) }
            if !json { status(download.title) }
            reported = download.sourceURL ?? link.absoluteString
            item = try await transcriber.transcribe(file: download.file, kind: .url, title: download.title, sourceURL: download.sourceURL ?? link.absoluteString,
                                                    keepAudio: keepAudio && !noSave, progress: progress)
        }
        if !json { FileHandle.standardError.write(Data("\n".utf8)) }
        await speech.shutdown()
        if json {
            output(TBDListenJSON.encode(TBDListenJSON.TranscribeResult(file: reported, transcription: item, saved: !noSave)))
        } else {
            output(TBDExport.render(item, as: format))
        }
    }
}
