import Foundation

/// Which player was paused, so only that one is resumed.
struct TBDMediaPauseToken: Sendable, Equatable {
    let processIdentifier: Int32?
    let bundleIdentifier: String?
}

/// What the system reports as playing right now.
struct TBDNowPlaying: Sendable, Equatable {
    let isPlaying: Bool
    let processIdentifier: Int32?
    let bundleIdentifier: String?

    var hasIdentity: Bool { processIdentifier != nil || bundleIdentifier?.isEmpty == false }

    /// The same player as `token`: every identity field the token holds must match.
    func matches(_ token: TBDMediaPauseToken) -> Bool {
        var compared = false
        if let pid = token.processIdentifier { compared = true; guard processIdentifier == pid else { return false } }
        if let bundle = token.bundleIdentifier, !bundle.isEmpty { compared = true; guard bundleIdentifier == bundle else { return false } }
        return compared
    }

    /// Decodes the helper script's JSON (`available`, `playing`, `playbackRate`, `processIdentifier`, `bundleIdentifier`).
    static func decode(_ data: Data) -> TBDNowPlaying? {
        struct Payload: Decodable { let available: Bool?; let playing: Bool?; let playbackRate: Double?; let processIdentifier: Int32?; let bundleIdentifier: String? }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.available != false else { return nil }
        return TBDNowPlaying(isPlaying: payload.playing ?? ((payload.playbackRate ?? 0) > 0.01),
                             processIdentifier: payload.processIdentifier.flatMap { $0 > 0 ? $0 : nil },
                             bundleIdentifier: payload.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// Pauses playing media while dictation records and resumes it after, only if it was playing and is still the same
/// paused player (v1 `SystemMediaController` and `DictationMediaPauseCoordinator`).
@MainActor
final class TBDDictationMedia {
    private let snapshot: @Sendable () async -> TBDNowPlaying?
    private let send: @Sendable (_ pause: Bool) -> Bool
    private var token: TBDMediaPauseToken?
    private var generation = 0
    private var pauseTask: Task<Void, Never>?

    init(snapshot: @escaping @Sendable () async -> TBDNowPlaying? = { await TBDMediaRemote.nowPlaying() },
         send: @escaping @Sendable (Bool) -> Bool = { TBDMediaRemote.send(pause: $0) }) {
        self.snapshot = snapshot; self.send = send
    }

    /// Starts the pause without blocking capture. `onPaused` fires when media was playing and the pause went out
    /// (the pre-roll then holds media sound and is dropped).
    func requestPause(enabled: Bool, meetingActive: Bool, onPaused: (@MainActor () -> Void)? = nil) {
        generation += 1
        let mine = generation
        pauseTask?.cancel()
        pauseTask = nil
        guard token == nil, enabled, !meetingActive else { return }
        let snapshot = snapshot, send = send
        pauseTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let now = await snapshot(), now.isPlaying, now.hasIdentity, send(true) else { return }
            let token = TBDMediaPauseToken(processIdentifier: now.processIdentifier, bundleIdentifier: now.bundleIdentifier)
            guard let self, !Task.isCancelled, self.generation == mine else {
                // Capture ended while the pause was in flight: give the media back.
                if let current = await snapshot(), !current.isPlaying, current.matches(token) { _ = send(false) }
                return
            }
            self.token = token
            onPaused?()
        }
    }

    /// Resumes what this class paused. Nothing happens if something else is playing now or the player changed.
    func resume() async {
        generation += 1
        pauseTask?.cancel()
        guard let token else { return }
        self.token = nil
        guard let now = await snapshot(), !now.isPlaying, now.matches(token) else { return }
        _ = send(false)
    }

    var isPaused: Bool { token != nil }
}

/// The system now-playing query (a JXA helper over the private MediaRemote framework) and the play/pause command,
/// as v1 did. Both fail closed: unavailable means "do nothing".
enum TBDMediaRemote {
    private static let script = """
    function run() {
      ObjC.import('Foundation');
      const mediaRemote = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
      if (!mediaRemote) return JSON.stringify({ "available": false });
      mediaRemote.load;
      const request = $.NSClassFromString('MRNowPlayingRequest');
      if (!request) return JSON.stringify({ "available": false });
      const item = request.localNowPlayingItem;
      const playerPath = request.localNowPlayingPlayerPath;
      const info = item ? item.nowPlayingInfo : null;
      const client = playerPath ? playerPath.client : null;
      function unwrap(value) {
        if (value === null || value === undefined) return null;
        try { const result = ObjC.unwrap(value); return result === undefined ? null : result; } catch (e) { return null; }
      }
      function infoValue(key) { if (!info) return null; try { return unwrap(info.valueForKey(key)); } catch (e) { return null; } }
      function clientValue(key) { if (!client) return null; try { return unwrap(client.valueForKey(key)); } catch (e) { return null; } }
      const rateValue = infoValue('kMRMediaRemoteNowPlayingInfoPlaybackRate');
      const rate = rateValue === null ? 0 : Number(rateValue);
      const pidValue = clientValue('processIdentifier');
      const pid = pidValue === null ? null : Number(pidValue);
      const bundle = clientValue('bundleIdentifier');
      return JSON.stringify({ "available": true, "playing": rate > 0.01, "playbackRate": rate,
        "processIdentifier": pid && pid > 0 ? pid : null, "bundleIdentifier": bundle || null });
    }
    """

    static func nowPlaying(timeout: TimeInterval = 1.25) async -> TBDNowPlaying? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-l", "JavaScript", "-e", script]
                process.standardError = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                guard (try? process.run()) != nil else { continuation.resume(returning: nil); return }
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { process.terminate(); continuation.resume(returning: nil); return }
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: process.terminationStatus == 0 ? TBDNowPlaying.decode(data) : nil)
            }
        }
    }

    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> UInt8
    private static let sender: SendCommand? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    /// Command 1 pauses, 0 plays. Returns whether the system accepted it.
    static func send(pause: Bool) -> Bool {
        guard let sender else { return false }
        return sender(pause ? 1 : 0, nil) != 0
    }
}
