import ArgumentParser
import Foundation
import TBDSpeech

/// `tbd-listen`: local access to the TBD Listening library for scripts and TBD's default agent.
@main
struct TBDListen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tbd-listen",
        abstract: "Transcribe audio and query the TBD Listening library.",
        version: TBDSpeechVersion.string,
        subcommands: [Transcribe.self, History.self, Search.self, Show.self, Meetings.self]
    )
}

/// Preferences shared with the TBD app (engine choice, Whisper language).
let appPreferences = TBDListeningPreferences(defaults: UserDefaults(suiteName: "com.tealbrick.tbd") ?? .standard)

func openLibrary() throws -> TBDListeningDatabase {
    do { return try TBDListeningDatabase(readOnly: true) } catch {
        throw ValidationError("No Listening library at \(TBDListeningPaths.database.path). Use TBD once or run `tbd-listen transcribe`.")
    }
}

func output(_ text: String) { FileHandle.standardOutput.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8)) }

func shortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe an audio or video file and save it to the library.")
    @Argument(help: "Audio or video file.") var file: String
    @Flag(help: "Print JSON.") var json = false
    @Flag(name: .customLong("no-save"), help: "Do not save the result to the library.") var noSave = false
    @Option(help: "Engine: parakeetV3, parakeetV2 or whisper (default: the app's choice).") var engine: String?

    func run() async throws {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ValidationError("File not found: \(file)") }
        let preferences = appPreferences
        if let engine {
            guard let choice = TBDEngineChoice(rawValue: engine) else { throw ValidationError("Unknown engine \(engine).") }
            preferences.overridingEngine(choice)
        }
        let database = noSave ? try TBDListeningDatabase(inMemory: ()) : try TBDListeningDatabase()
        let speech = TBDSpeechService(preferences: preferences)
        let progress: TBDTranscriber.Progress? = json ? nil : Self.report
        let item = try await TBDTranscriber(speech: speech, database: database).transcribe(file: url, progress: progress)
        if !json { FileHandle.standardError.write("\n".data(using: .utf8) ?? Data()) }
        await speech.shutdown()
        output(json ? TBDListenJSON.encode(TBDListenJSON.TranscribeResult(file: url.path, transcription: item, saved: !noSave)) : item.text)
    }
}

extension Transcribe {
    @Sendable static func report(_ stage: String, _ fraction: Double) {
        let line = "\r\(stage) \(Int(fraction * 100))%   "
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    }
}

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List recent dictations.")
    @Option(help: "Maximum number of dictations.") var limit = 20
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        let items = try openLibrary().dictations(limit: max(1, limit))
        if json { output(TBDListenJSON.encode(items.map(TBDListenJSON.Dictation.init))); return }
        if items.isEmpty { output("No dictations."); return }
        for item in items {
            output("\(shortDate(item.createdAt))  \(item.wordCount) words  \(item.targetApp ?? "-")\n  \(item.text)")
        }
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Full-text search of transcripts.")
    @Argument(help: "Search words (prefix match).") var query: [String]
    @Option(help: "Maximum number of results.") var limit = 20
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        let items = try openLibrary().transcriptions(limit: max(1, limit), matching: query.joined(separator: " "))
        printItems(items, json: json)
    }
}

struct Meetings: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List recorded meetings.")
    @Option(help: "Maximum number of meetings.") var limit = 20
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        printItems(try openLibrary().transcriptions(limit: max(1, limit), kind: .meeting), json: json)
    }
}

func printItems(_ items: [TBDTranscription], json: Bool) {
    if json { output(TBDListenJSON.encode(items.map(TBDListenJSON.Item.init))); return }
    if items.isEmpty { output("No results."); return }
    for item in items {
        output("\(item.id.prefix(8))  \(shortDate(item.createdAt))  \(item.sourceKind.rawValue)  \(TBDExport.clock(item.durationMs))  \(item.title)")
    }
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print one transcript (id or unique id prefix).")
    @Argument(help: "Transcript id or unique prefix.") var id: String
    @Option(help: "Format: txt, md, srt, vtt or json.") var format = "txt"

    func run() throws {
        guard let format = TBDExportFormat(rawValue: format.lowercased()), !format.isBinary else { throw ValidationError("Unknown format \(format).") }
        let library = try openLibrary()
        guard let item = try library.transcription(id: id) else { throw ValidationError("No transcript matches \(id).") }
        output(TBDExport.render(item, as: format, summaries: (try? library.summaries(for: item.id)) ?? []))
    }
}
