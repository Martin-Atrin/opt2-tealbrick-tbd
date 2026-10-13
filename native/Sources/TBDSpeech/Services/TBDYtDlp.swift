import Foundation

/// Audio format yt-dlp downloads for video and web links (v1 `YouTubeAudioQuality`, PARITY 3.2).
public enum TBDYtDlpAudioQuality: String, CaseIterable, Hashable, Sendable {
    case m4a
    case bestAvailable = "best_available"

    public var displayTitle: String {
        switch self {
        case .m4a: "M4A"
        case .bestAvailable: "Best available"
        }
    }

    public var detail: String {
        switch self {
        case .m4a:
            "Download an Apple-friendly M4A file. Smaller and slightly faster; transcripts are close to Best available for most videos."
        case .bestAvailable:
            "The site's highest-quality audio stream, recommended when accuracy matters most. Needs FFmpeg (for example from Homebrew) to convert WebM/Opus to M4A; without FFmpeg, M4A is used."
        }
    }

    /// v1 format selectors, used when FFmpeg is present (it converts whatever is chosen to M4A).
    public var ytDlpFormatSelector: String {
        switch self {
        case .m4a: "bestaudio[ext=m4a]/bestaudio/best"
        case .bestAvailable: "bestaudio/best"
        }
    }

    /// Without FFmpeg nothing can convert the download, so every quality prefers formats
    /// AVFoundation decodes (AAC in M4A/MP4, MP3) before any other audio.
    public static let avFoundationFormatSelector = "bestaudio[ext=m4a]/bestaudio[ext=mp4]/bestaudio[ext=mp3]/best[ext=mp4]/bestaudio/best"

    /// `tbd-listen config` spelling (v1 CLI: m4a, best-available).
    public var configValue: String {
        switch self {
        case .m4a: "m4a"
        case .bestAvailable: "best-available"
        }
    }

    public init?(configValue: String) {
        switch configValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-") {
        case "m4a": self = .m4a
        case "best-available", "bestavailable": self = .bestAvailable
        default: return nil
        }
    }
}

/// yt-dlp failures in plain words (v1 `YouTubeDownloadError`).
public enum TBDLinkDownloadError: Error, LocalizedError, Equatable {
    case videoNotFound
    case blockedByYouTube
    case downloadFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .videoNotFound: "Video not found, private, or unavailable"
        case .blockedByYouTube: "YouTube blocked this download. Try again later, or drop a local audio or video file instead."
        case .downloadFailed(let reason): "Download failed: \(reason)"
        case .timedOut: "Download timed out — the connection may have stalled"
        }
    }
}

/// yt-dlp arguments, output parsing and error mapping, ported from v1 `YouTubeDownloader`.
public enum TBDYtDlp {
    /// Downloads may be long (v1: one hour).
    public static let downloadTimeout: TimeInterval = 60 * 60
    static let titleMarker = "TBD-TITLE "
    static let fileMarker = "TBD-FILE "

    /// Arguments for one audio download. With FFmpeg: v1 selectors, conversion to M4A (a copy when
    /// the stream is already AAC) and embedded metadata. Without FFmpeg: AVFoundation formats only.
    public static func downloadArguments(outputTemplate: String, url: String, quality: TBDYtDlpAudioQuality,
                                         ffmpegDirectory: String?, javaScriptRuntime: [String] = []) -> [String] {
        var args: [String] = []
        if !javaScriptRuntime.isEmpty { args += ["--no-js-runtimes"] + javaScriptRuntime }
        if let ffmpegDirectory {
            args += ["--ffmpeg-location", ffmpegDirectory, "-f", quality.ytDlpFormatSelector,
                     "--extract-audio", "--audio-format", "m4a", "--audio-quality", "0"]
        } else {
            args += ["-f", TBDYtDlpAudioQuality.avFoundationFormatSelector]
        }
        args += ["--no-playlist", "--retries", "3", "--concurrent-fragments", "4"]
        if ffmpegDirectory != nil { args += ["--embed-metadata"] }
        args += [
            // --print makes yt-dlp quiet; --progress keeps the "[download] 42.0%" lines (on stderr).
            "--newline", "--progress",
            "--print", "before_dl:\(titleMarker)%(title)s",
            "--print", "after_move:\(fileMarker)%(filepath)s",
            "-o", outputTemplate,
            // Options end before the link so a link can never be read as a flag (v1 AUDIT-074).
            "--", url,
        ]
        return args
    }

    /// `--js-runtimes` for YouTube's player challenges: the first of node, deno or QuickJS found
    /// (TBD's own bundled Node included). Nil when none is installed.
    public static func javaScriptRuntimeArguments() -> [String] {
        let resources = Bundle.main.resourcePath
        // The CLI runs from Contents/Helpers; the bundled Node is in Contents/Resources/Chat.
        let helperResources = Bundle.main.executableURL.map {
            $0.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources").path
        }
        func bundled(_ name: String) -> [String] {
            [resources, helperResources].compactMap { $0 }.flatMap { ["\($0)/\(name)", "\($0)/\(name)-arm64", "\($0)/Chat/\(name)"] }
        }
        let candidates: [(name: String, binaries: [String], preferred: [String])] = [
            ("node", ["node"], bundled("node") + ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]),
            ("deno", ["deno"], bundled("deno") + ["/opt/homebrew/bin/deno", "/usr/local/bin/deno", "/usr/bin/deno"]),
            ("quickjs", ["qjs", "quickjs"], bundled("qjs") + bundled("quickjs") + ["/opt/homebrew/bin/qjs", "/usr/local/bin/qjs", "/usr/bin/qjs"]),
        ]
        let path = TBDBinaryBootstrap.extendedPATH()
        for candidate in candidates {
            if let found = candidate.preferred.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return ["--js-runtimes", "\(candidate.name):\(found)"]
            }
            for binary in candidate.binaries {
                if let found = TBDBinaryBootstrap.findExecutable(binary, inPATH: path) {
                    return ["--js-runtimes", "\(candidate.name):\(found)"]
                }
            }
        }
        return []
    }

    /// Percent from a "[download]  42.3% of ..." line.
    public static func progressPercent(_ line: String) -> Int? {
        guard line.localizedCaseInsensitiveContains("[download]"),
              let match = line.range(of: #"([0-9]+(?:\.[0-9]+)?)%"#, options: .regularExpression),
              let raw = Double(line[match].dropLast()) else { return nil }
        return max(0, min(Int(raw.rounded()), 100))
    }

    /// Maps yt-dlp stderr to a message. Private or removed videos stay distinct from YouTube's
    /// bot check, whose `--cookies-from-browser` advice the app cannot follow.
    public static func classify(_ raw: String) -> TBDLinkDownloadError {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.lowercased()
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201B}", with: "'")
        if folded.contains("video unavailable") || folded.contains("private video") { return .videoNotFound }
        if folded.contains("[youtube]"), folded.contains("not a bot") || folded.contains("cookies-from-browser") { return .blockedByYouTube }
        return .downloadFailed(normalize(trimmed))
    }

    static func normalize(_ trimmed: String) -> String {
        guard !trimmed.isEmpty else { return "Unknown error" }
        let lowered = trimmed.lowercased()
        if lowered.contains("no supported javascript runtime could be found") {
            return "No supported JavaScript runtime found for media extraction. Install Node.js (recommended) or Deno and retry."
        }
        if lowered.contains("requested format is not available") {
            return "This link has no audio format TBD can read. Install FFmpeg (for example with Homebrew) and try again."
        }
        if lowered.contains("ffmpeg"), lowered.contains("not found") { return "FFmpeg is missing or inaccessible for this runtime." }
        let lines = trimmed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = lines.first { $0.localizedCaseInsensitiveContains("error:") }
            ?? lines.first { !$0.localizedCaseInsensitiveContains("warning:") }
            ?? lines.first ?? trimmed
        return String(line.prefix(512))
    }

    /// Worth one retry with a freshly downloaded yt-dlp (sites change faster than releases).
    public static func shouldRetryWithFreshYtDlp(_ error: Error) -> Bool {
        switch error {
        case TBDLinkDownloadError.blockedByYouTube, TBDLinkDownloadError.downloadFailed, TBDLinkDownloadError.timedOut: true
        default: false
        }
    }

    /// The managed binary fails to start (PyInstaller library validation after a signing change).
    public static func isLibraryValidationError(_ error: Error) -> Bool {
        guard case TBDLinkDownloadError.downloadFailed(let reason) = error else { return false }
        let lowered = reason.lowercased()
        return lowered.contains("failed to load python shared library") || (lowered.contains("pyi-") && lowered.contains("different team ids"))
    }

    static func isTemporaryArtifact(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasSuffix(".part") || lowered.contains(".part-") || lowered.hasSuffix(".ytdl") || lowered.hasSuffix(".temp")
            || lowered.hasSuffix(".tmp") || lowered.hasSuffix(".frag") || lowered.hasSuffix(".info.json") || lowered.hasSuffix(".description")
            || lowered.hasSuffix(".log")
    }

    static let audioExtensions: Set<String> = ["aac", "aiff", "flac", "m4a", "mka", "mp3", "mp4", "oga", "ogg", "opus", "wav", "webm"]

    /// The finished audio file among the files starting with `stem`.
    static func downloadedFile(in fileNames: [String], stem: String) -> String? {
        fileNames.filter { $0.hasPrefix(stem) && !isTemporaryArtifact($0) }
            .first { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// Removes everything a download with `stem` left behind (partials, logs), except `keep`.
    static func removeArtifacts(in directory: URL, stem: String, keep: URL? = nil) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(stem) && file.standardizedFileURL != keep?.standardizedFileURL {
            try? fm.removeItem(at: file)
        }
    }

    struct RunResult: Sendable {
        let status: Int32
        let stdout: [String]
        let stderr: String
    }

    /// Runs yt-dlp, reporting download percent from stdout and stderr. Cancelling stops it.
    static func run(_ tool: String, arguments: [String], timeout: TimeInterval = downloadTimeout,
                    progress: (@Sendable (Int) -> Void)?) async throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = TBDBinaryBootstrap.extendedPATH()
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let state = NSLockedValue((outBuffer: Data(), errBuffer: Data(), outLines: [String](), errAll: Data(), last: -1))
        @Sendable func lines(from buffer: inout Data, appending chunk: Data, flush: Bool) -> [String] {
            buffer.append(chunk)
            var result: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                result.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if flush, !buffer.isEmpty { result.append(String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
            return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        @Sendable func handle(_ chunk: Data, stdout: Bool, flush: Bool) {
            let percents: [Int] = state.withLock { s in
                let new: [String]
                if stdout {
                    new = lines(from: &s.outBuffer, appending: chunk, flush: flush)
                    s.outLines += new
                } else {
                    s.errAll.append(chunk)
                    new = lines(from: &s.errBuffer, appending: chunk, flush: flush)
                }
                var emit: [Int] = []
                for line in new { if let p = progressPercent(line), p != s.last { s.last = p; emit.append(p) } }
                return emit
            }
            percents.forEach { progress?($0) }
        }
        out.fileHandleForReading.readabilityHandler = { handle($0.availableData, stdout: true, flush: false) }
        err.fileHandleForReading.readabilityHandler = { handle($0.availableData, stdout: false, flush: false) }

        let timedOut = NSLockedValue(false)
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                if Task.isCancelled { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { timedOut.withLock { $0 = true }; process.terminate() }
                }
            }
        } onCancel: {
            // Terminating a process that never launched raises an exception.
            if process.isRunning { process.terminate() }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        handle(out.fileHandleForReading.readDataToEndOfFile(), stdout: true, flush: true)
        handle(err.fileHandleForReading.readDataToEndOfFile(), stdout: false, flush: true)
        try Task.checkCancellation()
        if timedOut.withLock({ $0 }) { throw TBDLinkDownloadError.timedOut }
        return state.withLock { RunResult(status: process.terminationStatus, stdout: $0.outLines, stderr: String(decoding: $0.errAll, as: UTF8.self)) }
    }
}
