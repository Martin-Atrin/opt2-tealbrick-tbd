import ArgumentParser
import Foundation
import TBDSpeech

/// The managed yt-dlp used for video links (v1 `health --repair-binaries`).
struct YtDlp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "yt-dlp", abstract: "The yt-dlp that TBD manages for video links.",
                                                    subcommands: [Status.self, Update.self], defaultSubcommand: Status.self)

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show where yt-dlp and FFmpeg are.")
        func run() {
            let bootstrap = TBDBinaryBootstrap(defaults: appPreferences.defaults)
            output("yt-dlp: " + (bootstrap.installedYtDlpPath() ?? "not installed (downloads on the first video link, or run `tbd-listen yt-dlp update`)"))
            output("FFmpeg: " + (TBDBinaryBootstrap.resolveFFmpegPath() ?? "not found (links download as M4A)"))
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download the latest yt-dlp from GitHub and verify its checksum.")
        func run() async throws {
            let path = try await TBDBinaryBootstrap(defaults: appPreferences.defaults).ensureYtDlpAvailable(allowNetworkUpdate: true)
            output("yt-dlp installed at \(path)")
        }
    }
}
