import ArgumentParser
import Foundation
import TBDSpeech

func engineInfos(_ preferences: TBDListeningPreferences) -> [TBDListenJSON.Engine] {
    let manager = TBDModelManager(preferences: preferences)
    return TBDEngineCapabilities.all.map {
        TBDListenJSON.Engine($0, downloaded: manager.isDownloaded(engine: $0.kind), live: preferences.liveEngine == $0.kind,
                             final: preferences.finalEngine == $0.kind)
    }
}

struct Engines: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Speech engines and what they can do.", subcommands: [List.self], defaultSubcommand: List.self)

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List engines with capabilities, download state and routes.")
        @Flag(help: "Print JSON.") var json = false

        func run() throws {
            let infos = engineInfos(appPreferences)
            if json { outputJSON(infos); return }
            for info in infos {
                var flags: [String] = []
                if info.live { flags.append("LIVE") }
                if info.final { flags.append("FINAL") }
                flags.append(info.downloaded ? "downloaded" : "not downloaded")
                let languages = info.languageMode == "fixed" ? (info.defaultLanguage ?? "-")
                    : info.languages.map { "\($0.count) languages" } ?? "many languages"
                var features = [info.wordTimestamps ? "timestamps" : "plain text"]
                if info.streaming { features.append("streaming") } else if info.livePreview { features.append("live preview") }
                if info.diarization { features.append("speaker labels") }
                if !info.memoryOK { features.append("needs more memory") }
                output("\(info.cliID.padding(toLength: 24, withPad: " ", startingAt: 0)) \(info.name) [\(flags.joined(separator: ", "))]\n"
                       + "    \(languages); \(features.joined(separator: ", ")); \(Int64(info.approximateBytes).tbdByteString)")
            }
        }
    }
}

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List, download and delete local models (downloads only when you ask).",
                                                    subcommands: [List.self, Status.self, Download.self, DeleteModel.self], defaultSubcommand: List.self)

    static func manager() -> TBDModelManager { TBDModelManager(preferences: appPreferences) }

    static func parse(_ id: String) throws -> TBDModelManager.Model {
        guard let model = TBDModelManager.Model(identifier: id) else {
            throw ValidationError("Unknown model \(id). Use one of: \(TBDModelManager.Model.allCases.map(\.cliID).joined(separator: ", ")).")
        }
        return model
    }

    static func info(_ model: TBDModelManager.Model, manager: TBDModelManager) -> TBDListenJSON.Model {
        TBDListenJSON.Model(manager.status(model), path: manager.folder(model))
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List models with size and download state.")
        @Flag(help: "Print JSON.") var json = false

        func run() throws {
            let manager = Models.manager()
            let infos = TBDModelManager.Model.allCases.map { Models.info($0, manager: manager) }
            if json { outputJSON(infos); return }
            for info in infos {
                let size = info.downloaded ? info.bytes.tbdByteString : "not downloaded (~\(info.approximateBytes.tbdByteString))"
                output("\(info.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(info.title): \(size)")
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Routes, readiness and disk use. Never downloads.")
        @Flag(help: "Print JSON.") var json = false

        func run() throws {
            let manager = Models.manager()
            let prefs = appPreferences
            let status = TBDListenJSON.ModelsStatus(
                liveEngine: prefs.liveEngine, finalEngine: prefs.finalEngine,
                liveReady: manager.isDownloaded(engine: prefs.liveEngine), finalReady: manager.isDownloaded(engine: prefs.finalEngine),
                vadReady: manager.isDownloaded(.vad), speakerDetectionReady: manager.isDownloaded(.diarizer),
                totalBytes: manager.totalBytes, modelsPath: manager.modelsRoot.path,
                models: TBDModelManager.Model.allCases.map { Models.info($0, manager: manager) })
            if json { outputJSON(status); return }
            output("""
            Live engine:  \(prefs.liveEngine.displayName) (\(status.liveReady ? "ready" : "not downloaded"))
            Final engine: \(prefs.finalEngine.displayName) (\(status.finalReady ? "ready" : "not downloaded"))\(prefs.finalEngineOverride == nil ? " — follows live" : "")
            Voice activity: \(status.vadReady ? "ready" : "not downloaded (energy chunking)")
            Speaker detection: \(status.speakerDetectionReady ? "ready" : "not downloaded")
            Models: \(status.totalBytes.tbdByteString) in \(status.modelsPath)
            """)
        }
    }

    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download a model now.")
        @Argument(help: "Model id from `tbd-listen models list`.") var id: String
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let model = try Models.parse(id)
            let manager = Models.manager()
            if let engine = model.engine, !engine.capabilities.satisfiesMemory() {
                status("Warning: \(engine.displayName) needs more memory than this Mac has.")
            }
            if !json { status("Downloading \(model.title)…") }
            try await manager.download(model) { fraction in if !json { reportProgress("Downloading", fraction) } }
            if !json { FileHandle.standardError.write(Data("\n".utf8)) }
            let info = Models.info(model, manager: manager)
            if json { outputJSON(info) } else { output("\(info.title): \(info.bytes.tbdByteString) in \(info.path)") }
        }
    }

    struct DeleteModel: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a downloaded model.")
        @Argument(help: "Model id from `tbd-listen models list`.") var id: String
        @Flag(help: "Confirm the deletion (required).") var yes = false
        @Flag(help: "Print JSON.") var json = false

        func validate() throws {
            guard yes else { throw ValidationError("Add --yes to delete the model files. You can download them again later.") }
        }

        func run() throws {
            let model = try Models.parse(id)
            let manager = Models.manager()
            if let engine = model.engine, engine == appPreferences.liveEngine || engine == appPreferences.finalEngine {
                status("Note: \(engine.displayName) is a selected engine; Listening cannot use it until it is downloaded again.")
            }
            try manager.delete(model)
            let info = Models.info(model, manager: manager)
            if json { outputJSON(info) } else { output("Deleted \(info.title).") }
        }
    }
}

struct Podcasts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Find podcasts in the Apple Podcasts directory.", subcommands: [SearchShows.self, Resolve.self])

    struct SearchShows: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "search", abstract: "Search shows by name.")
        @Argument(help: "Search words.") var query: [String]
        @Option(help: "Maximum number of shows.") var limit = 10
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let shows = try await TBDPodcastResolver().searchShows(query.joined(separator: " "), limit: limit)
            if json { outputJSON(shows.map(TBDListenJSON.PodcastShow.init)); return }
            if shows.isEmpty { output("No shows."); return }
            for show in shows { output("\(show.name ?? "Untitled")  \(show.feedURL ?? "(no feed)")") }
        }
    }

    struct Resolve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show which episode a link or search resolves to, without downloading it.")
        @Argument(help: "Apple Podcasts link, or show name and episode words.") var query: [String]
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let text = query.joined(separator: " ")
            let resolver = TBDPodcastResolver()
            let episode = TBDPodcastURL.isApplePodcasts(text) ? try await resolver.resolve(url: text) : try await resolver.resolve(query: text)
            if json { outputJSON(episode); return }
            output("\(episode.displayTitle)\n  \(episode.releaseDate ?? "-")  \(episode.durationSeconds.map { TBDExport.clock($0 * 1000) } ?? "-")\n  \(episode.audioURL)")
        }
    }
}
