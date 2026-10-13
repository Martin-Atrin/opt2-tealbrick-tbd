import Foundation

/// Fetches the audio of a web link. Apple Podcasts links, podcast searches and direct audio
/// file links are resolved and downloaded directly (iTunes API + RSS, no extra tool); other
/// pages (YouTube and the sites yt-dlp supports) use a managed yt-dlp that `TBDBinaryBootstrap`
/// downloads from the official GitHub release on first use and verifies by SHA-256, as v1 did.
/// A yt-dlp on the person's PATH is used only when the managed copy cannot be installed.
public struct TBDLinkDownloader: Sendable {
    public struct Result: Sendable {
        public let file: URL
        public let title: String
        /// The URL the audio came from (the episode audio for podcasts), for the library record.
        public let sourceURL: String?
        public init(file: URL, title: String, sourceURL: String? = nil) { self.file = file; self.title = title; self.sourceURL = sourceURL }
    }

    /// Scheme of the pseudo link that carries a free-text podcast search through link queues.
    public static let podcastSearchScheme = "tbd-podcast-search"

    /// Stage text and fraction, as `TBDTranscriber.Progress`.
    public typealias Progress = @Sendable (_ stage: String, _ fraction: Double) -> Void

    private let podcasts: TBDPodcastResolver
    private let bootstrap: TBDBinaryBootstrap
    private let audioQuality: @Sendable () -> TBDYtDlpAudioQuality
    private let ffmpegPath: @Sendable () -> String?
    private let javaScriptRuntime: @Sendable () -> [String]
    private let userTool: @Sendable () -> String?

    public init(podcasts: TBDPodcastResolver = TBDPodcastResolver(),
                bootstrap: TBDBinaryBootstrap = TBDBinaryBootstrap(),
                audioQuality: @escaping @Sendable () -> TBDYtDlpAudioQuality = { .m4a },
                ffmpegPath: @escaping @Sendable () -> String? = { TBDBinaryBootstrap.resolveFFmpegPath() },
                javaScriptRuntime: @escaping @Sendable () -> [String] = { TBDYtDlp.javaScriptRuntimeArguments() },
                userTool: @escaping @Sendable () -> String? = { TBDLinkDownloader.toolPath() }) {
        self.podcasts = podcasts
        self.bootstrap = bootstrap
        self.audioQuality = audioQuality
        self.ffmpegPath = ffmpegPath
        self.javaScriptRuntime = javaScriptRuntime
        self.userTool = userTool
    }

    /// The app and CLI setup: yt-dlp state in `preferences`' defaults, quality from `preferences`
    /// unless `quality` overrides it for this download.
    public init(preferences: TBDListeningPreferences, quality: TBDYtDlpAudioQuality? = nil) {
        self.init(bootstrap: TBDBinaryBootstrap(defaults: preferences.defaults),
                  audioQuality: { quality ?? preferences.youtubeAudioQuality })
    }

    /// A link that runs a podcast search for `query` when downloaded.
    public static func podcastSearchLink(_ query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = podcastSearchScheme
        components.path = "search"
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }

    static func podcastQuery(_ url: URL) -> String? {
        guard url.scheme == podcastSearchScheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
    }

    /// A link, or (for text that is not a link) a podcast search. Nil for empty text.
    public static func linkOrPodcastSearch(_ text: String) -> URL? {
        validate(text) ?? (text.contains("://") ? nil : podcastSearchLink(text))
    }

    /// Links whose audio is fetched directly instead of through yt-dlp.
    public static func isDirectAudio(_ url: URL) -> Bool {
        ["mp3", "m4a", "aac", "ogg", "oga", "opus", "wav", "flac", "wma", "aiff", "aif"].contains(url.pathExtension.lowercased())
    }

    /// Location of a user-installed `yt-dlp` on the PATH (login shell PATH included, since GUI apps
    /// get a short one). Only a fallback when the managed copy cannot be installed.
    public static func toolPath() -> String? {
        if let cached = cache.withLock({ $0 }), FileManager.default.isExecutableFile(atPath: cached) { return cached }
        let found = searchToolPath()
        cache.withLock { $0 = found }
        return found
    }

    private static let cache = NSLockedValue<String?>(nil)

    private static func searchToolPath() -> String? {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let shellPath = loginShellPath() { directories += shellPath.split(separator: ":").map(String.init) }
        for directory in directories where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent("yt-dlp")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func loginShellPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    /// Accepts only http(s) links without credentials.
    public static func validate(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Downloads the audio of `url` into `directory`. Cancelling the task stops the download.
    public func download(_ url: URL, into directory: URL, progress: Progress? = nil) async throws -> Result {
        if let query = Self.podcastQuery(url) {
            return try await download(try await podcasts.resolve(query: query), into: directory)
        }
        if TBDPodcastURL.isApplePodcasts(url.absoluteString) {
            return try await download(try await podcasts.resolve(url: url.absoluteString), into: directory)
        }
        if Self.isDirectAudio(url) {
            let file = try await Self.fetchAudio(url, into: directory)
            return Result(file: file, title: url.deletingPathExtension().lastPathComponent, sourceURL: url.absoluteString)
        }
        return try await downloadWithTool(url, into: directory, progress: progress)
    }

    /// Downloads a resolved podcast episode.
    public func download(_ episode: TBDPodcastEpisode, into directory: URL) async throws -> Result {
        guard let audio = Self.validate(episode.audioURL) else { throw TBDPodcastError.noPlayableAudio }
        let file = try await Self.fetchAudio(audio, into: directory)
        return Result(file: file, title: episode.displayTitle, sourceURL: episode.audioURL)
    }

    /// Streams an audio file to disk. The extension comes from the URL or the response type.
    static func fetchAudio(_ url: URL, into directory: URL) async throws -> URL {
        try TBDListeningPaths.ensure(directory)
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("TBD-Listening/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("audio/*, application/octet-stream;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw TBDSpeechError.audioUnreadable("download failed (HTTP \(http.statusCode))")
        }
        let destination = directory.appendingPathComponent(tbdNewID() + "." + audioExtension(for: url, mimeType: response.mimeType))
        do { try FileManager.default.moveItem(at: temporary, to: destination) } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return destination
    }

    static func audioExtension(for url: URL, mimeType: String?) -> String {
        let known: Set<String> = ["mp3", "m4a", "mp4", "aac", "ogg", "oga", "opus", "wav", "flac", "wma", "webm", "aiff"]
        let pathExtension = url.pathExtension.lowercased()
        if known.contains(pathExtension) { return pathExtension }
        let mime = mimeType?.lowercased() ?? ""
        if mime.contains("mpeg") || mime.contains("mp3") { return "mp3" }
        if mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") { return "m4a" }
        if mime.contains("ogg") || mime.contains("opus") { return "ogg" }
        if mime.contains("wav") { return "wav" }
        return "mp3"
    }

    /// Downloads the link's audio with yt-dlp (v1 `YouTubeDownloader.download`): a failure that a
    /// newer yt-dlp may fix is retried once after a forced update; a binary that cannot start is
    /// reinstalled. Cancelling the task stops yt-dlp.
    func downloadWithTool(_ url: URL, into directory: URL, progress: Progress? = nil) async throws -> Result {
        let tool = try await resolveTool(progress: progress)
        do {
            return try await runTool(tool, url: url, into: directory, progress: progress)
        } catch {
            if error is CancellationError { throw error }
            if TBDYtDlp.isLibraryValidationError(error) {
                progress?("Getting yt-dlp", 0)
                let repaired = try await bootstrap.reinstallYtDlpFromBundledSeedOrDownload()
                return try await runTool(repaired, url: url, into: directory, progress: progress)
            }
            guard TBDYtDlp.shouldRetryWithFreshYtDlp(error) else { throw error }
            progress?("Updating yt-dlp", 0)
            let fresh: String
            do { fresh = try await bootstrap.ensureYtDlpAvailable(allowNetworkUpdate: true) } catch { throw error }
            return try await runTool(fresh, url: url, into: directory, progress: progress)
        }
    }

    /// The managed yt-dlp (installed on first use), else a user-installed one when the install fails.
    private func resolveTool(progress: Progress?) async throws -> String {
        if bootstrap.installedYtDlpPath() == nil { progress?("Getting yt-dlp", 0) }
        do {
            return try await bootstrap.ensureYtDlpAvailable()
        } catch {
            if error is CancellationError { throw error }
            if let fallback = userTool() { return fallback }
            throw error
        }
    }

    private func runTool(_ tool: String, url: URL, into directory: URL, progress: Progress?) async throws -> Result {
        try TBDListeningPaths.ensure(directory)
        let stem = tbdNewID()
        var succeeded = false
        defer { if !succeeded { TBDYtDlp.removeArtifacts(in: directory, stem: stem) } }
        let arguments = TBDYtDlp.downloadArguments(
            outputTemplate: directory.appendingPathComponent(stem + ".%(ext)s").path, url: url.absoluteString,
            quality: audioQuality(), ffmpegDirectory: ffmpegPath().map { ($0 as NSString).deletingLastPathComponent },
            javaScriptRuntime: javaScriptRuntime())
        progress?("Downloading", 0)
        let result = try await TBDYtDlp.run(tool, arguments: arguments) { percent in progress?("Downloading", Double(percent) / 100) }
        guard result.status == 0 else { throw TBDYtDlp.classify(result.stderr.isEmpty ? "Unknown error" : result.stderr) }
        let reported = result.stdout.last { $0.hasPrefix(TBDYtDlp.fileMarker) }.map { String($0.dropFirst(TBDYtDlp.fileMarker.count)) }
        let file: URL
        if let reported, FileManager.default.fileExists(atPath: reported) {
            file = URL(fileURLWithPath: reported)
        } else if let name = TBDYtDlp.downloadedFile(in: (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [], stem: stem) {
            file = directory.appendingPathComponent(name)
        } else {
            throw TBDLinkDownloadError.downloadFailed("Downloaded file not found")
        }
        TBDYtDlp.removeArtifacts(in: directory, stem: stem, keep: file)
        succeeded = true
        let title = result.stdout.last { $0.hasPrefix(TBDYtDlp.titleMarker) }.map { String($0.dropFirst(TBDYtDlp.titleMarker.count)) }
        return Result(file: file, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? "Link", sourceURL: url.absoluteString)
    }
}
