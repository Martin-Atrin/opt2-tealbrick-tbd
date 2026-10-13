import CryptoKit
import Foundation

/// Why the managed yt-dlp could not be installed. A binary that fails any check is never run.
public enum TBDBinaryBootstrapError: Error, LocalizedError, Equatable {
    case downloadFailed(String)
    case checksumUnavailable(String)
    case checksumMismatch(expected: String, actual: String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return "yt-dlp could not be downloaded: \(message)"
        case .checksumUnavailable(let message):
            return "yt-dlp could not be verified: \(message). It was not installed."
        case .checksumMismatch(let expected, let actual):
            return "yt-dlp failed its checksum check (expected \(expected), got \(actual)). It was not installed."
        case .installFailed(let message):
            return "yt-dlp could not be installed: \(message)"
        }
    }
}

extension TBDListeningPaths {
    /// Managed helper binaries (yt-dlp), as in v1 (`AppPaths.binDir`).
    public static var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
}

/// Installs and updates the yt-dlp that link transcription uses, so links work without the person
/// installing anything (port of v1 `BinaryBootstrap`). The binary comes from the official GitHub
/// "latest" release and is installed only when its SHA-256 matches the release's `SHA2-256SUMS`.
/// It lives in Listening/bin/yt-dlp and is refreshed at most once a week.
public actor TBDBinaryBootstrap {
    /// yt-dlp publishes one universal macOS binary.
    public static let ytDlpAsset = "yt-dlp_macos"
    public static let checksumsFile = "SHA2-256SUMS"
    public static let defaultBaseURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download")!
    public static let updateInterval: TimeInterval = 7 * 24 * 60 * 60

    private let session: URLSession
    private let baseURL: URL
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let binDirectory: URL
    private let temporaryDirectory: URL
    private let bundledSeed: @Sendable () -> String?
    private var installTask: Task<Void, Error>?

    public init(session: URLSession = .shared,
                baseURL: URL = TBDBinaryBootstrap.defaultBaseURL,
                defaults: UserDefaults = .standard,
                now: @escaping @Sendable () -> Date = { Date() },
                binDirectory: URL = TBDListeningPaths.bin,
                temporaryDirectory: URL = TBDListeningPaths.temporary,
                bundledSeed: @escaping @Sendable () -> String? = { TBDBinaryBootstrap.bundledYtDlpPath() }) {
        self.session = session
        self.baseURL = baseURL
        self.defaults = defaults
        self.now = now
        self.binDirectory = binDirectory
        self.temporaryDirectory = temporaryDirectory
        self.bundledSeed = bundledSeed
    }

    /// Where the managed yt-dlp lives.
    public nonisolated var ytDlpPath: String { binDirectory.appendingPathComponent("yt-dlp").path }

    /// The yt-dlp that is ready without a download: the managed copy, else a copy bundled with the app.
    public nonisolated func installedYtDlpPath() -> String? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: ytDlpPath) { return ytDlpPath }
        if let seed = bundledSeed(), fm.isExecutableFile(atPath: seed) { return seed }
        return nil
    }

    /// A ready yt-dlp path. Downloads and verifies it on first use; `allowNetworkUpdate` (the
    /// "Update yt-dlp" action and the retry after a failed download) always fetches the latest.
    public func ensureYtDlpAvailable(allowNetworkUpdate: Bool = false) async throws -> String {
        try TBDListeningPaths.ensure(binDirectory)
        let target = ytDlpPath
        if allowNetworkUpdate {
            try await installLatest()
            recordCheck()
            return target
        }
        if FileManager.default.isExecutableFile(atPath: target) { return target }
        if let seed = bundledSeed(), FileManager.default.isExecutableFile(atPath: seed) {
            try installExecutable(from: URL(fileURLWithPath: seed), to: target)
            recordCheck()
            return target
        }
        try await installLatest()
        recordCheck()
        return target
    }

    /// Replaces a yt-dlp that fails to start (PyInstaller library validation) with the bundled seed
    /// or a fresh download.
    public func reinstallYtDlpFromBundledSeedOrDownload() async throws -> String {
        try TBDListeningPaths.ensure(binDirectory)
        let target = ytDlpPath
        if let seed = bundledSeed(), FileManager.default.isExecutableFile(atPath: seed) {
            try installExecutable(from: URL(fileURLWithPath: seed), to: target)
        } else {
            try await installLatest()
        }
        recordCheck()
        return target
    }

    /// Weekly background refresh of an installed yt-dlp (sites change and old versions break).
    /// Failures are ignored and retried on the next launch, because only success is recorded.
    public func autoUpdateYtDlpIfNeeded() async {
        guard shouldRunUpdateCheck(), FileManager.default.isExecutableFile(atPath: ytDlpPath) else { return }
        do {
            try await installLatest()
            recordCheck()
        } catch {}
    }

    /// When yt-dlp was last installed or refreshed.
    public var lastUpdateCheck: Date? { defaults.object(forKey: TBDListeningPreferences.LinkKey.ytDlpLastUpdateCheck) as? Date }

    // MARK: - Install

    private func shouldRunUpdateCheck() -> Bool {
        guard let last = lastUpdateCheck else { return true }
        return now().timeIntervalSince(last) >= Self.updateInterval
    }

    private func recordCheck() { defaults.set(now(), forKey: TBDListeningPreferences.LinkKey.ytDlpLastUpdateCheck) }

    /// One download at a time; concurrent callers share it.
    private func installLatest() async throws {
        if let installTask { return try await installTask.value }
        let task = Task { try await self.downloadVerifyInstall() }
        installTask = task
        defer { installTask = nil }
        try await task.value
    }

    private func downloadVerifyInstall() async throws {
        let binaryURL = baseURL.appendingPathComponent(Self.ytDlpAsset)
        let checksumsURL = baseURL.appendingPathComponent(Self.checksumsFile)
        try TBDListeningPaths.ensure(temporaryDirectory)
        let downloaded = temporaryDirectory.appendingPathComponent("yt-dlp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: downloaded) }

        try await download(binaryURL, to: downloaded)
        let checksums = try await fetchText(checksumsURL)
        let expected = try Self.extractChecksum(for: Self.ytDlpAsset, from: checksums)
        let actual = try Self.sha256Hex(ofFileAt: downloaded)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw TBDBinaryBootstrapError.checksumMismatch(expected: expected, actual: actual)
        }
        try installExecutable(from: downloaded, to: ytDlpPath)
    }

    private func download(_ url: URL, to destination: URL) async throws {
        let (temporary, response) = try await fetch { try await self.session.download(from: url) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw TBDBinaryBootstrapError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) from \(url.absoluteString)")
        }
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.moveItem(at: temporary, to: destination) } catch {
            throw TBDBinaryBootstrapError.installFailed(error.localizedDescription)
        }
    }

    private func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await fetch { try await self.session.data(from: url) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TBDBinaryBootstrapError.checksumUnavailable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) from \(url.absoluteString)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TBDBinaryBootstrapError.checksumUnavailable("\(Self.checksumsFile) is not valid text")
        }
        return text
    }

    /// Network errors in plain words (offline, blocked host) instead of URLError codes.
    private func fetch<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw TBDBinaryBootstrapError.downloadFailed(error.localizedDescription)
        }
    }

    /// Stages the new binary next to the target with 0755 set, then swaps it in, so a failure
    /// leaves the previous yt-dlp in place.
    private func installExecutable(from source: URL, to targetPath: String) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: targetPath)
        let directory = target.deletingLastPathComponent()
        let staged = directory.appendingPathComponent(".\(target.lastPathComponent).staged")
        defer { try? fm.removeItem(at: staged) }
        do {
            try TBDListeningPaths.ensure(directory)
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            try fm.copyItem(at: source, to: staged)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            if fm.fileExists(atPath: targetPath) {
                _ = try fm.replaceItemAt(target, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        } catch {
            throw TBDBinaryBootstrapError.installFailed(error.localizedDescription)
        }
    }

    static func extractChecksum(for asset: String, from checksums: String) throws -> String {
        for line in checksums.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            // `sha256sum` marks binary mode with a leading "*".
            let name = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : String(parts[1])
            if name == asset { return String(parts[0]) }
        }
        throw TBDBinaryBootstrapError.checksumUnavailable("no checksum for \(asset) in \(checksumsFile)")
    }

    static func sha256Hex(ofFileAt url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Locations

    /// A yt-dlp seed shipped inside the app's Resources (none today; kept for parity with v1).
    public static func bundledYtDlpPath() -> String? {
        guard let resources = Bundle.main.resourcePath else { return nil }
        let path = (resources as NSString).appendingPathComponent("yt-dlp")
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// PATH plus the places GUI apps miss (managed bin, Homebrew), as v1 `extendedPATH`.
    public static func extendedPATH(_ base: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        let current = base ?? "/usr/bin:/bin"
        let existing = Set(current.split(separator: ":").map(String.init))
        let extras = [TBDListeningPaths.bin.path, "/opt/homebrew/bin", "/usr/local/bin"].filter { !existing.contains($0) }
        return ([current] + extras).joined(separator: ":")
    }

    static func findExecutable(_ name: String, inPATH path: String) -> String? {
        for component in path.split(separator: ":") where !component.isEmpty {
            let candidate = (String(component) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// FFmpeg for yt-dlp, as v1 `resolveRuntimeFFmpegPath`: bundled, then `TBD_FFMPEG_PATH`, then
    /// PATH. TBD does not ship FFmpeg, so this is normally the person's own (for example Homebrew).
    public static func resolveFFmpegPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        if let resources = Bundle.main.resourcePath {
            let bundled = (resources as NSString).appendingPathComponent("ffmpeg")
            if fm.isExecutableFile(atPath: bundled) { return bundled }
        }
        if let override = environment["TBD_FFMPEG_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty, fm.isExecutableFile(atPath: override) {
            return override
        }
        return findExecutable("ffmpeg", inPATH: extendedPATH(environment["PATH"]))
    }
}
