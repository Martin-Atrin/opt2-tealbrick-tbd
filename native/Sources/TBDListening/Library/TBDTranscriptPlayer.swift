import AppKit
import AVFoundation
import SwiftUI
import TBDDesign
import TBDSpeech

/// Playback time, kept apart from the player so only the bar redraws ten times a second.
@MainActor
final class TBDPlayerClock: ObservableObject {
    @Published var currentTimeMs = 0
}

/// Plays the kept audio of one transcript (v1 `MediaPlayerViewModel`, audio mode). A meeting keeps a microphone
/// and a system track; both play together. No kept audio means no player and no error.
@MainActor
final class TBDTranscriptPlayer: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isPlaying = false
    @Published private(set) var durationMs = 0
    @Published private(set) var rate: Float
    /// The segment being played; follows `segmentStarts`.
    @Published private(set) var activeIndex: Int?
    /// Counts seeks and jumps in playback time, so the transcript re-syncs at once.
    @Published private(set) var jumpCount = 0
    let clock = TBDPlayerClock()

    /// Start time of each segment shown, in order. Set by the view.
    var segmentStarts: [Int] = [] {
        didSet { if segmentStarts != oldValue { refreshActive() } }
    }

    private let preferences: TBDListeningPreferences
    private var urls: [URL] = []
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var loading: Task<Void, Never>?
    private var lastTickMs = 0

    init(preferences: TBDListeningPreferences = TBDListeningPreferences()) {
        self.preferences = preferences
        rate = preferences.playbackRate
    }

    /// Points the player at the kept audio. Does nothing when the same files are already loaded, so a reload of
    /// the transcript never interrupts playback.
    func prepare(paths: [String], fallbackDurationMs: Int) {
        let found = TBDTranscriptReader.playableAudio(paths) { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        if found == urls {
            if durationMs == 0, fallbackDurationMs > 0 { durationMs = fallbackDurationMs }
            return
        }
        cleanup()
        urls = found
        guard !found.isEmpty else { return }
        durationMs = max(0, fallbackDurationMs)
        loading = Task { [weak self] in
            guard let item = await Self.makeItem(found), !Task.isCancelled, let self else { return }
            self.attach(item)
        }
    }

    func cleanup() {
        loading?.cancel(); loading = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObserver?.invalidate(); statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        urls = []
        isAvailable = false; isPlaying = false; durationMs = 0; activeIndex = nil; lastTickMs = 0
        clock.currentTimeMs = 0
    }

    func seek(toMs ms: Int) {
        guard let player else { return }
        let target = min(max(0, ms), durationMs > 0 ? durationMs : Int.max)
        player.seek(to: CMTime(value: CMTimeValue(target), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        clock.currentTimeMs = target
        lastTickMs = target
        jumpCount &+= 1
        refreshActive()
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            // A finished recording starts again from the beginning.
            if durationMs > 0, clock.currentTimeMs >= durationMs - 50 { seek(toMs: 0) }
            player.defaultRate = rate
            player.play()
        }
    }

    /// Timestamp click: jump there and play (v1 `onTimestampTap`).
    func play(fromMs ms: Int) {
        guard isAvailable else { return }
        seek(toMs: ms)
        if !isPlaying { togglePlayPause() }
    }

    func setRate(_ value: Float) {
        let normalized = TBDPlaybackRate.normalized(value)
        rate = normalized
        preferences.playbackRate = normalized
        guard let player else { return }
        player.defaultRate = normalized
        if player.timeControlStatus != .paused { player.rate = normalized }
    }

    var rateLabel: String { TBDPlaybackRate.label(for: rate) }

    // MARK: Files

    func revealInFinder() {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Writes the kept audio, both tracks mixed, to one m4a file (v1 "Save Audio As…").
    func export(to destination: URL) async throws {
        guard let asset = await Self.exportAsset(urls) else { throw TBDPlayerError.unavailable }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw TBDPlayerError.unavailable }
        session.outputURL = temp
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            throw session.error ?? TBDPlayerError.unavailable
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
    }

    // MARK: Loading

    private func attach(_ item: AVPlayerItem) {
        item.audioTimePitchAlgorithm = .timeDomain
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.defaultRate = rate
        player = avPlayer
        isAvailable = true

        // 10 Hz, as in v1, for a smooth scrubber and transcript sync.
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 1000), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(Int(time.seconds * 1000)) }
        }
        statusObserver = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in self?.isPlaying = player.timeControlStatus == .playing }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isPlaying = false }
        }
        Task { [weak self] in
            if let duration = try? await item.asset.load(.duration), duration.isNumeric, let self, self.player === avPlayer {
                self.durationMs = Int(duration.seconds * 1000)
            }
        }
    }

    private func tick(_ ms: Int) {
        if TBDTranscriptReader.isSeekJump(from: lastTickMs, to: ms) { jumpCount &+= 1 }
        lastTickMs = ms
        clock.currentTimeMs = ms
        refreshActive()
    }

    private func refreshActive() {
        let index = TBDTranscriptReader.highlightIndex(starts: segmentStarts, atMs: clock.currentTimeMs, hasAudio: isAvailable)
        if index != activeIndex { activeIndex = index }
    }

    /// One item for a single file; a composition that plays several tracks together for a meeting.
    private static func makeItem(_ urls: [URL]) async -> AVPlayerItem? {
        if urls.count == 1 {
            let asset = AVURLAsset(url: urls[0])
            guard (try? await asset.load(.isPlayable)) == true else { return nil }
            return AVPlayerItem(asset: asset)
        }
        guard let mix = await mix(urls) else { return nil }
        return AVPlayerItem(asset: mix)
    }

    private static func exportAsset(_ urls: [URL]) async -> AVAsset? {
        urls.count == 1 ? AVURLAsset(url: urls[0]) : await mix(urls)
    }

    private static func mix(_ urls: [URL]) async -> AVMutableComposition? {
        let composition = AVMutableComposition()
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        }
        return composition.tracks.isEmpty ? nil : composition
    }
}

enum TBDPlayerError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The audio is no longer available." }
}

/// Play/pause, scrubber with elapsed and total time, speed menu (v1 `AudioScrubberBar`, `PlaybackSpeedMenu`),
/// and for meetings the Audio menu (v1 "Show Audio in Finder", "Save Audio As…").
struct TBDPlayerBar: View {
    @ObservedObject var player: TBDTranscriptPlayer
    @ObservedObject var clock: TBDPlayerClock
    let title: String
    let showsAudioMenu: Bool
    let onError: (String) -> Void
    @State private var dragging = false
    @State private var dragProgress = 0.0

    init(player: TBDTranscriptPlayer, title: String, showsAudioMenu: Bool, onError: @escaping (String) -> Void) {
        self.player = player; clock = player.clock; self.title = title; self.showsAudioMenu = showsAudioMenu; self.onError = onError
    }

    var body: some View {
        HStack(spacing: TBDTokens.Space.md) {
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold)).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(TBDTokens.ink)
            .help(player.isPlaying ? "Pause" : "Play").accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Text(TBDExport.clock(clock.currentTimeMs)).font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(TBDTokens.muted).frame(width: 48, alignment: .trailing)
            scrubber
            Text(TBDExport.clock(player.durationMs)).font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(TBDTokens.muted).frame(width: 48, alignment: .leading)
            speedMenu
            if showsAudioMenu { audioMenu }
        }
        .padding(.horizontal, TBDTokens.Space.lg)
        .frame(height: 44)
        .background(TBDTokens.paper)
        .overlay(Rectangle().fill(TBDTokens.border).frame(height: TBDTokens.Stroke.hairline), alignment: .top)
    }

    private var progress: Double {
        player.durationMs > 0 ? min(1, Double(clock.currentTimeMs) / Double(player.durationMs)) : 0
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let shown = dragging ? dragProgress : progress
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(TBDTokens.border).frame(height: 6)
                RoundedRectangle(cornerRadius: 3).fill(TBDTokens.accent).frame(width: max(0, geo.size.width * shown), height: 6)
                Circle().fill(TBDTokens.accent).frame(width: 12, height: 12).offset(x: max(0, geo.size.width * shown - 6))
            }
            .frame(height: 12).frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        dragProgress = max(0, min(1, value.location.x / max(1, geo.size.width)))
                    }
                    .onEnded { value in
                        let fraction = max(0, min(1, value.location.x / max(1, geo.size.width)))
                        player.seek(toMs: Int(fraction * Double(player.durationMs)))
                        dragging = false
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(TBDExport.clock(clock.currentTimeMs)) of \(TBDExport.clock(player.durationMs))")
    }

    private var speedMenu: some View {
        Menu {
            ForEach(TBDPlaybackRate.options, id: \.self) { value in
                Button {
                    player.setRate(value)
                } label: {
                    if abs(player.rate - value) < 0.001 {
                        Label(TBDPlaybackRate.label(for: value), systemImage: "checkmark")
                    } else {
                        Text(TBDPlaybackRate.label(for: value))
                    }
                }
            }
        } label: {
            Label(player.rateLabel, systemImage: "speedometer").font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Playback speed").accessibilityLabel("Playback speed").accessibilityValue(player.rateLabel)
    }

    private var audioMenu: some View {
        Menu {
            Button { player.revealInFinder() } label: { Label("Show Audio in Finder", systemImage: "waveform") }
            Button { save() } label: { Label("Save Audio As…", systemImage: "square.and.arrow.down") }
        } label: {
            Label("Audio", systemImage: "waveform")
        }
        .menuStyle(.borderlessButton).fixedSize().help("Reveal or save the meeting audio file")
    }

    private func save() {
        let panel = NSSavePanel()
        panel.title = "Save Meeting Audio"
        panel.prompt = "Save"
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".m4a"
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await player.export(to: url) } catch { onError(error.localizedDescription) }
        }
    }
}
