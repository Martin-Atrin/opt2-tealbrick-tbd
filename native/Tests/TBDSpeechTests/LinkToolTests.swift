import CryptoKit
import XCTest
@testable import TBDSpeech

/// Serves a fake yt-dlp release (binary + SHA2-256SUMS) from memory. No network.
final class FakeReleaseProtocol: URLProtocol {
    struct Release { var binary: Data; var sums: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var releases: [String: Release] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func serve(_ release: Release, host: String) { lock.withLock { releases[host] = release } }
    static func requests(host: String) -> Int { lock.withLock { counts[host] ?? 0 } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let host = url.host!
        let release = Self.lock.withLock { () -> Release? in
            Self.counts[host, default: 0] += 1
            return Self.releases[host]
        }
        var body: Data?
        switch url.lastPathComponent {
        case TBDBinaryBootstrap.ytDlpAsset: body = release?.binary
        case TBDBinaryBootstrap.checksumsFile: body = release.map { Data($0.sums.utf8) }
        default: body = nil
        }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Managed yt-dlp install (checksum good and bad, weekly refresh) and link download end to end
/// with a fake yt-dlp that writes the speech fixture.
final class LinkToolTests: XCTestCase {
    private var temp: URL!
    private var host = ""
    private var defaults: UserDefaults!
    private let clock = NSLockedValue(Date(timeIntervalSince1970: 1_800_000_000))

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-linktool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        host = "release-\(UUID().uuidString.lowercased()).test"
        let suite = "tbd.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { [temp] in
            UserDefaults().removePersistentDomain(forName: suite)
            if let temp { try? FileManager.default.removeItem(at: temp) }
        }
    }

    private var binDirectory: URL { temp.appendingPathComponent("bin", isDirectory: true) }
    private var downloadTemp: URL { temp.appendingPathComponent("tmp", isDirectory: true) }

    private func bootstrap() -> TBDBinaryBootstrap {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeReleaseProtocol.self]
        let clock = clock
        return TBDBinaryBootstrap(session: URLSession(configuration: configuration),
                                  baseURL: URL(string: "https://\(host)/yt-dlp/releases/latest/download")!,
                                  defaults: defaults, now: { clock.withLock { $0 } },
                                  binDirectory: binDirectory, temporaryDirectory: downloadTemp, bundledSeed: { nil })
    }

    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func serve(_ script: String, sum: String? = nil, asset: String = TBDBinaryBootstrap.ytDlpAsset) {
        let binary = Data(script.utf8)
        FakeReleaseProtocol.serve(.init(binary: binary, sums: "\(sum ?? sha256(binary))  \(asset)\nabc123  yt-dlp.exe\n"), host: host)
    }

    private func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: binDirectory.path)) ?? [])
            + ((try? FileManager.default.contentsOfDirectory(atPath: downloadTemp.path)) ?? [])
    }

    // MARK: - Bootstrap

    func testGoodChecksumInstallsExecutable() async throws {
        let script = "#!/bin/sh\necho fake-yt-dlp\n"
        serve(script)
        let path = try await bootstrap().ensureYtDlpAvailable()
        XCTAssertEqual(path, binDirectory.appendingPathComponent("yt-dlp").path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), script)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
        XCTAssertEqual(defaults.object(forKey: TBDListeningPreferences.LinkKey.ytDlpLastUpdateCheck) as? Date, clock.withLock { $0 })
        XCTAssertEqual(FakeReleaseProtocol.requests(host: host), 2, "binary + SHA2-256SUMS")
        XCTAssertEqual(leftovers(), ["yt-dlp"], "no staged or temporary files remain")
        // Installed: the next call uses it without the network.
        _ = try await bootstrap().ensureYtDlpAvailable()
        XCTAssertEqual(FakeReleaseProtocol.requests(host: host), 2)
    }

    func testWrongChecksumRefusesAndLeavesNoFile() async throws {
        let script = "#!/bin/sh\necho evil\n"
        let wrong = String(repeating: "0", count: 64)
        serve(script, sum: wrong)
        do {
            _ = try await bootstrap().ensureYtDlpAvailable()
            XCTFail("an unverified binary must not install")
        } catch {
            XCTAssertEqual(error as? TBDBinaryBootstrapError, .checksumMismatch(expected: wrong, actual: sha256(Data(script.utf8))))
            XCTAssertEqual(error.localizedDescription,
                           "yt-dlp failed its checksum check (expected \(wrong), got \(sha256(Data(script.utf8)))). It was not installed.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: binDirectory.appendingPathComponent("yt-dlp").path))
        XCTAssertEqual(leftovers(), [])
        XCTAssertNil(defaults.object(forKey: TBDListeningPreferences.LinkKey.ytDlpLastUpdateCheck))
    }

    func testWrongChecksumOnUpdateKeepsPreviousBinary() async throws {
        let good = "#!/bin/sh\necho good\n"
        serve(good)
        let path = try await bootstrap().ensureYtDlpAvailable()
        serve("#!/bin/sh\necho evil\n", sum: sha256(Data(good.utf8)))
        do {
            _ = try await bootstrap().ensureYtDlpAvailable(allowNetworkUpdate: true)
            XCTFail("mismatch must refuse")
        } catch {
            guard case .checksumMismatch = error as? TBDBinaryBootstrapError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), good)
        XCTAssertEqual(leftovers(), ["yt-dlp"])
    }

    func testMissingChecksumEntryRefuses() async throws {
        serve("#!/bin/sh\n", asset: "yt-dlp_linux")
        do {
            _ = try await bootstrap().ensureYtDlpAvailable()
            XCTFail("no checksum, no install")
        } catch {
            XCTAssertEqual(error as? TBDBinaryBootstrapError, .checksumUnavailable("no checksum for yt-dlp_macos in SHA2-256SUMS"))
            XCTAssertEqual(error.localizedDescription,
                           "yt-dlp could not be verified: no checksum for yt-dlp_macos in SHA2-256SUMS. It was not installed.")
        }
        XCTAssertEqual(leftovers(), [])
    }

    func testMissingReleaseReportsHTTPStatus() async throws {
        do {
            _ = try await bootstrap().ensureYtDlpAvailable()
            XCTFail("nothing served")
        } catch {
            XCTAssertEqual(error as? TBDBinaryBootstrapError,
                           .downloadFailed("HTTP 404 from https://\(host)/yt-dlp/releases/latest/download/yt-dlp_macos"))
        }
        XCTAssertEqual(leftovers(), [])
    }

    func testWeeklyUpdateCheck() async throws {
        serve("#!/bin/sh\necho v1\n")
        let start = clock.withLock { $0 }
        _ = try await bootstrap().ensureYtDlpAvailable()
        XCTAssertEqual(FakeReleaseProtocol.requests(host: host), 2)

        clock.withLock { $0 = start.addingTimeInterval(TBDBinaryBootstrap.updateInterval - 60) }
        await bootstrap().autoUpdateYtDlpIfNeeded()
        XCTAssertEqual(FakeReleaseProtocol.requests(host: host), 2, "no network call within 7 days")

        serve("#!/bin/sh\necho v2\n")
        let due = start.addingTimeInterval(TBDBinaryBootstrap.updateInterval)
        clock.withLock { $0 = due }
        await bootstrap().autoUpdateYtDlpIfNeeded()
        XCTAssertEqual(FakeReleaseProtocol.requests(host: host), 4, "one refresh (binary + sums) after 7 days")
        XCTAssertEqual(try String(contentsOfFile: binDirectory.appendingPathComponent("yt-dlp").path, encoding: .utf8), "#!/bin/sh\necho v2\n")
        XCTAssertEqual(defaults.object(forKey: TBDListeningPreferences.LinkKey.ytDlpLastUpdateCheck) as? Date, due)

        await bootstrap().autoUpdateYtDlpIfNeeded()
        XCTAssertEqual(FakeReleaseProtocol.requests(host: host), 4, "the refresh restarts the week")
    }

    func testWeeklyCheckSkipsWhenNotInstalled() async {
        serve("#!/bin/sh\n")
        await bootstrap().autoUpdateYtDlpIfNeeded()
        XCTAssertEqual(FakeReleaseProtocol.requests(host: host), 0, "first install happens on first link use, not at launch")
    }

    func testChecksumParsing() throws {
        XCTAssertEqual(try TBDBinaryBootstrap.extractChecksum(for: "yt-dlp_macos", from: "aa  yt-dlp\nbb *yt-dlp_macos\n"), "bb")
        XCTAssertThrowsError(try TBDBinaryBootstrap.extractChecksum(for: "yt-dlp_macos", from: "aa  yt-dlp_macos.zip\n"))
    }

    // MARK: - Link download end to end

    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/fixtures/tbd-speech.aiff")
    }

    /// A fake yt-dlp: records its arguments, writes `audio` to the `-o` template with the
    /// template's extension filled in, and prints what the real one prints with our --print options.
    private func fakeYtDlp(audio: URL, argsFile: URL, failFirst: String? = nil) -> String {
        """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsFile.path)'
        \(failFirst.map { "echo '\($0)' >&2; exit 1" } ?? "")
        out=""; prev=""
        for a in "$@"; do if [ "$prev" = "-o" ]; then out="$a"; fi; prev="$a"; done
        file=$(printf '%s' "$out" | sed 's/%(ext)s/\(audio.pathExtension)/')
        cp '\(audio.path)' "$file"
        echo 'TBD-TITLE Fixture Speech'
        echo '[download]  50.0% of 1.00MiB at 1.00MiB/s ETA 00:01' >&2
        echo '[download] 100% of 1.00MiB in 00:00:01' >&2
        echo "TBD-FILE $file"
        """
    }

    private func m4aFixture() throws -> URL {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "fixture missing")
        let m4a = temp.appendingPathComponent("speech.m4a")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", fixture.path, m4a.path]
        try convert.run()
        convert.waitUntilExit()
        XCTAssertEqual(convert.terminationStatus, 0)
        return m4a
    }

    func testLinkDownloadPassesQualityArgumentsAndReturnsAudio() async throws {
        let m4a = try m4aFixture()
        let argsFile = temp.appendingPathComponent("args.txt")
        serve(fakeYtDlp(audio: m4a, argsFile: argsFile))
        let downloads = temp.appendingPathComponent("Downloads", isDirectory: true)
        let link = URL(string: "https://www.youtube.com/watch?v=abc123")!
        let cases: [(TBDYtDlpAudioQuality, String?, [String])] = [
            (.m4a, nil, ["-f", "bestaudio[ext=m4a]/bestaudio[ext=mp4]/bestaudio[ext=mp3]/best[ext=mp4]/bestaudio/best",
                         "--no-playlist", "--retries", "3", "--concurrent-fragments", "4"]),
            (.bestAvailable, nil, ["-f", "bestaudio[ext=m4a]/bestaudio[ext=mp4]/bestaudio[ext=mp3]/best[ext=mp4]/bestaudio/best",
                                   "--no-playlist", "--retries", "3", "--concurrent-fragments", "4"]),
            (.m4a, "/opt/fake/bin/ffmpeg", ["--ffmpeg-location", "/opt/fake/bin", "-f", "bestaudio[ext=m4a]/bestaudio/best",
                                            "--extract-audio", "--audio-format", "m4a", "--audio-quality", "0",
                                            "--no-playlist", "--retries", "3", "--concurrent-fragments", "4", "--embed-metadata"]),
            (.bestAvailable, "/opt/fake/bin/ffmpeg", ["--ffmpeg-location", "/opt/fake/bin", "-f", "bestaudio/best",
                                                      "--extract-audio", "--audio-format", "m4a", "--audio-quality", "0",
                                                      "--no-playlist", "--retries", "3", "--concurrent-fragments", "4", "--embed-metadata"]),
        ]
        for (index, (quality, ffmpeg, head)) in cases.enumerated() {
            let stages = NSLockedValue([String]())
            let downloader = TBDLinkDownloader(bootstrap: bootstrap(), audioQuality: { quality }, ffmpegPath: { ffmpeg },
                                               javaScriptRuntime: { [] }, userTool: { nil })
            let result = try await downloader.download(link, into: downloads) { stage, fraction in
                stages.withLock { $0.append("\(stage) \(fraction)") }
            }
            let args = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
            let template = try XCTUnwrap(args.firstIndex(of: "-o").map { args[$0 + 1] })
            XCTAssertTrue(template.hasPrefix(downloads.path + "/") && template.hasSuffix(".%(ext)s"), template)
            XCTAssertEqual(args, head + ["--newline", "--progress", "--print", "before_dl:TBD-TITLE %(title)s",
                                         "--print", "after_move:TBD-FILE %(filepath)s", "-o", template, "--", link.absoluteString],
                           "\(quality) ffmpeg=\(ffmpeg ?? "none")")
            XCTAssertEqual(result.title, "Fixture Speech")
            XCTAssertEqual(result.sourceURL, link.absoluteString)
            XCTAssertEqual(result.file.path, template.replacingOccurrences(of: "%(ext)s", with: "m4a"))
            XCTAssertEqual(try Data(contentsOf: result.file), try Data(contentsOf: m4a))
            XCTAssertEqual(stages.withLock { $0 }, (index == 0 ? ["Getting yt-dlp 0.0"] : []) + ["Downloading 0.0", "Downloading 0.5", "Downloading 1.0"])
            // The file handed to the transcriber decodes with AVFoundation (no FFmpeg in TBD).
            let wav = temp.appendingPathComponent("decoded-\(index).wav")
            let ms = try await TBDAudioDecoder.decodeToWAV(result.file, destination: wav)
            XCTAssertGreaterThan(ms, 1000)
            try FileManager.default.removeItem(at: result.file)
        }
        XCTAssertEqual(FakeReleaseProtocol.requests(host: host), 2, "yt-dlp downloaded once, then reused")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [], "no partials or logs left")
    }

    func testFailedDownloadRetriesOnceWithFreshYtDlp() async throws {
        let m4a = try m4aFixture()
        let argsFile = temp.appendingPathComponent("args.txt")
        serve(fakeYtDlp(audio: m4a, argsFile: argsFile, failFirst: "ERROR: [youtube] abc123: Sign in to confirm you are not a bot. Use --cookies-from-browser"))
        let downloads = temp.appendingPathComponent("Downloads", isDirectory: true)
        let fixed = bootstrap()
        _ = try await fixed.ensureYtDlpAvailable()
        serve(fakeYtDlp(audio: m4a, argsFile: argsFile))
        let downloader = TBDLinkDownloader(bootstrap: fixed, audioQuality: { .m4a }, ffmpegPath: { nil }, javaScriptRuntime: { [] }, userTool: { nil })
        let result = try await downloader.download(URL(string: "https://www.youtube.com/watch?v=abc123")!, into: downloads)
        XCTAssertEqual(result.title, "Fixture Speech")
        XCTAssertEqual(FakeReleaseProtocol.requests(host: host), 4, "first install + one forced update")
        try FileManager.default.removeItem(at: result.file)

        // A failure the update does not fix is reported in plain words, after exactly one retry.
        serve(fakeYtDlp(audio: m4a, argsFile: argsFile, failFirst: "ERROR: [youtube] abc123: Private video. Sign in if you have access"))
        _ = try await fixed.ensureYtDlpAvailable(allowNetworkUpdate: true)
        do {
            _ = try await downloader.download(URL(string: "https://www.youtube.com/watch?v=abc123")!, into: downloads)
            XCTFail("private video must fail")
        } catch {
            XCTAssertEqual(error as? TBDLinkDownloadError, .videoNotFound)
            XCTAssertEqual(error.localizedDescription, "Video not found, private, or unavailable")
        }
        XCTAssertEqual(FakeReleaseProtocol.requests(host: host), 6, "videoNotFound is not retried")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [])
    }

    func testUnverifiedReleaseFallsBackToUserYtDlpOnly() async throws {
        serve("#!/bin/sh\n", sum: String(repeating: "f", count: 64))
        let downloads = temp.appendingPathComponent("Downloads", isDirectory: true)
        let refusing = TBDLinkDownloader(bootstrap: bootstrap(), ffmpegPath: { nil }, javaScriptRuntime: { [] }, userTool: { nil })
        do {
            _ = try await refusing.download(URL(string: "https://www.youtube.com/watch?v=abc123")!, into: downloads)
            XCTFail("no verified yt-dlp and none installed by the person")
        } catch {
            guard case .checksumMismatch = error as? TBDBinaryBootstrapError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: binDirectory.appendingPathComponent("yt-dlp").path))

        let m4a = try m4aFixture()
        let own = temp.appendingPathComponent("own-yt-dlp")
        try fakeYtDlp(audio: m4a, argsFile: temp.appendingPathComponent("args.txt")).write(to: own, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: own.path)
        let fallback = TBDLinkDownloader(bootstrap: bootstrap(), ffmpegPath: { nil }, javaScriptRuntime: { [] }, userTool: { own.path })
        let result = try await fallback.download(URL(string: "https://www.youtube.com/watch?v=abc123")!, into: downloads)
        XCTAssertEqual(result.title, "Fixture Speech")
        XCTAssertFalse(FileManager.default.fileExists(atPath: binDirectory.appendingPathComponent("yt-dlp").path), "the unverified binary never lands")
    }

    // MARK: - Messages and preferences

    func testErrorClassification() {
        XCTAssertEqual(TBDYtDlp.classify("ERROR: [youtube] x: Video unavailable"), .videoNotFound)
        XCTAssertEqual(TBDYtDlp.classify("ERROR: [youtube] x: Sign in to confirm you\u{2019}re not a bot"), .blockedByYouTube)
        XCTAssertEqual(TBDYtDlp.classify("WARNING: slow\nERROR: Unsupported URL: https://example.com"), .downloadFailed("ERROR: Unsupported URL: https://example.com"))
        XCTAssertEqual(TBDYtDlp.classify("ERROR: [youtube] x: Requested format is not available"),
                       .downloadFailed("This link has no audio format TBD can read. Install FFmpeg (for example with Homebrew) and try again."))
        XCTAssertEqual(TBDYtDlp.classify("ERROR: No supported JavaScript runtime could be found"),
                       .downloadFailed("No supported JavaScript runtime found for media extraction. Install Node.js (recommended) or Deno and retry."))
        XCTAssertEqual(TBDYtDlp.progressPercent("[download]  42.6% of 3.00MiB"), 43)
        XCTAssertNil(TBDYtDlp.progressPercent("[info] 50%"))
        XCTAssertTrue(TBDYtDlp.isLibraryValidationError(TBDLinkDownloadError.downloadFailed("[PYI-123:ERROR] Failed to load Python shared library")))
        XCTAssertFalse(TBDYtDlp.shouldRetryWithFreshYtDlp(TBDLinkDownloadError.videoNotFound))
    }

    func testAudioQualityPreferenceAndConfig() throws {
        let prefs = TBDListeningPreferences(defaults: defaults)
        XCTAssertEqual(prefs.youtubeAudioQuality, .m4a, "v1 default")
        XCTAssertEqual(try prefs.configValue("youtubeAudioQuality"), .string("m4a"))
        try prefs.setConfig("youtubeAudioQuality", to: "best_available")
        XCTAssertEqual(prefs.youtubeAudioQuality, .bestAvailable)
        XCTAssertEqual(defaults.string(forKey: "tbd.listening.youtubeAudioQuality"), "best_available")
        XCTAssertEqual(try prefs.configValue("youtubeAudioQuality"), .string("best-available"))
        XCTAssertThrowsError(try prefs.setConfig("youtubeAudioQuality", to: "flac")) { error in
            XCTAssertEqual(error as? TBDConfigError, .invalidValue(key: "youtubeAudioQuality", value: "flac", expected: "m4a or best-available"))
        }
        try prefs.setConfig("youtubeAudioQuality", to: "default")
        XCTAssertEqual(prefs.youtubeAudioQuality, .m4a)
        XCTAssertTrue(TBDListeningPreferences.configKeys.contains("youtubeAudioQuality"))
    }
}
