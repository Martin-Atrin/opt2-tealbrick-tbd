import Foundation

/// Fetches the audio of a web link with the user's own `yt-dlp`. Listening never downloads or
/// bundles the tool; when it is not on the PATH the link feature reports that.
public struct TBDLinkDownloader: Sendable {
    public struct Result: Sendable {
        public let file: URL
        public let title: String
    }

    public init() {}

    /// Location of `yt-dlp` on the user's PATH (login shell PATH included, since GUI apps get a short one).
    public static func toolPath() -> String? {
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

    /// Downloads the best audio-only stream into `directory`. Cancelling the task stops yt-dlp.
    public func download(_ url: URL, into directory: URL) async throws -> Result {
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
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
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
        return Result(file: URL(fileURLWithPath: path), title: title)
    }
}
