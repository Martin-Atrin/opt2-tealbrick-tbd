import Foundation

/// Fetches the audio of a web link. Apple Podcasts links, podcast searches and direct audio
/// file links are resolved and downloaded directly (iTunes API + RSS, no extra tool); other
/// pages use the user's own `yt-dlp`. Listening never downloads or bundles yt-dlp; when it is
/// not on the PATH the link feature reports that.
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

    private let podcasts: TBDPodcastResolver

    public init(podcasts: TBDPodcastResolver = TBDPodcastResolver()) { self.podcasts = podcasts }

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

    /// Location of `yt-dlp` on the user's PATH (login shell PATH included, since GUI apps get a short one).
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
    public func download(_ url: URL, into directory: URL) async throws -> Result {
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
        return try await downloadWithTool(url, into: directory)
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

    /// Downloads the best audio-only stream with yt-dlp. Cancelling the task stops yt-dlp.
    func downloadWithTool(_ url: URL, into directory: URL) async throws -> Result {
        guard let tool = Self.toolPath() else { throw TBDSpeechError.toolMissing("yt-dlp") }
        try TBDListeningPaths.ensure(directory)
        let stem = tbdNewID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [
            "--no-playlist", "--no-progress", "--no-warnings", "--restrict-filenames",
            "-f", "bestaudio[ext=m4a]/bestaudio[ext=mp4]/best[ext=mp4]/bestaudio/best",
            "-o", directory.appendingPathComponent(stem + ".%(ext)s").path,
            "--print", "before_dl:%(title)s", "--print", "after_move:filepath",
            "--", url.absoluteString,
        ]
        let output = Pipe()
        // stderr goes to a file so a chatty failure can never fill a pipe and stall the process.
        let errorLog = directory.appendingPathComponent(stem + ".log")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorLog) }
        let errors = try FileHandle(forWritingTo: errorLog)
        defer { try? errors.close() }
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                if Task.isCancelled { process.terminate() }
            }
        } onCancel: {
            // Terminating a process that never launched raises an exception.
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        guard process.terminationStatus == 0, let path = lines.last, FileManager.default.fileExists(atPath: path) else {
            let message = ((try? String(contentsOf: errorLog, encoding: .utf8)) ?? "")
                .split(separator: "\n").last.map(String.init) ?? "yt-dlp exited with status \(process.terminationStatus)"
            throw TBDSpeechError.audioUnreadable(message)
        }
        let title = lines.count > 1 ? lines[lines.count - 2] : url.host ?? "Link"
        return Result(file: URL(fileURLWithPath: path), title: title, sourceURL: url.absoluteString)
    }
}
