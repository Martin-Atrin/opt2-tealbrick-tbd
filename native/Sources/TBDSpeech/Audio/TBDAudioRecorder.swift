import AVFoundation
import Foundation

/// Records the shared microphone to a 16 kHz mono WAV with live level metering.
public final class TBDAudioRecorder: @unchecked Sendable {
    public struct Recording: Sendable {
        public let url: URL
        public let durationMs: Int
        public let peakLevel: Float
        /// Set when capture ended early (microphone lost, disk full); the audio up to that point is kept.
        public let warning: String?
    }

    private let microphone: TBDSharedMicrophone
    private let directory: URL
    private let lock = NSLock()
    private var token: TBDSharedMicrophone.Token?
    private var writer: TBDWAVWriter?
    private var resampler = TBDMonoResampler()
    private var level: Float = 0
    private var peak: Float = 0
    private var levelHistory: [Float] = []
    private var interruption: Error?
    /// Receives each converted 16 kHz chunk (for example a live preview). Called on the tap thread.
    public var sampleSink: (@Sendable ([Float]) -> Void)?

    public init(microphone: TBDSharedMicrophone = .shared, directory: URL = TBDListeningPaths.temporary) {
        self.microphone = microphone
        self.directory = directory
    }

    /// Smoothed 0...1 input level.
    public var audioLevel: Float { lock.lock(); defer { lock.unlock() }; return level }
    /// Recent levels, oldest first, for waveform drawing.
    public var recentLevels: [Float] { lock.lock(); defer { lock.unlock() }; return levelHistory }
    public var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return writer != nil }
    public var elapsedMs: Int { lock.lock(); defer { lock.unlock() }; return writer?.durationMs ?? 0 }
    /// Capture stopped on its own (microphone lost or disk write failed). Callers should finish.
    public var interrupted: Bool { lock.lock(); defer { lock.unlock() }; return interruption != nil || writer?.failure != nil }

    public func start() async throws {
        guard await TBDSharedMicrophone.requestPermission() else { throw TBDSpeechError.microphoneDenied }
        try TBDListeningPaths.ensure(directory)
        let writer = try TBDWAVWriter(url: directory.appendingPathComponent(UUID().uuidString + ".wav"))
        let accepted = lock.withLock { () -> Bool in
            guard self.writer == nil else { return false }
            self.writer = writer; resampler = TBDMonoResampler(); level = 0; peak = 0; levelHistory = []; interruption = nil
            return true
        }
        guard accepted else { try? writer.close(); try? FileManager.default.removeItem(at: writer.url); throw TBDSpeechError.busy("Recording") }
        do {
            let token = try await microphone.subscribe(onInterruption: { [weak self] error in
                guard let self else { return }
                self.lock.withLock { self.interruption = error }
            }) { [weak self] buffer in self?.consume(buffer) }
            // stop() may have run while subscribing; never leave the microphone subscribed.
            let current = lock.withLock { () -> Bool in
                guard self.writer === writer else { return false }
                self.token = token
                return true
            }
            if !current { await microphone.unsubscribe(token) }
        } catch {
            lock.withLock { self.writer = nil }
            try? writer.close()
            try? FileManager.default.removeItem(at: writer.url)
            throw error
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let writer else { lock.unlock(); return }
        let samples = resampler.convert(buffer)
        let normalized = TBDAudioLevel.normalized(samples)
        level = level * 0.3 + normalized * 0.7
        peak = max(peak, normalized)
        levelHistory.append(level)
        if levelHistory.count > 64 { levelHistory.removeFirst(levelHistory.count - 64) }
        let sink = sampleSink
        lock.unlock()
        writer.append(samples)
        if !samples.isEmpty { sink?(samples) }
    }

    /// Stops capture and returns the finished WAV. Throws if the microphone died mid-recording
    /// and nothing was captured.
    public func stop() async throws -> Recording {
        let (token, writer, peak, interruption) = lock.withLock {
            defer { self.token = nil; self.writer = nil }
            return (self.token, self.writer, self.peak, self.interruption)
        }
        if let token { await microphone.unsubscribe(token) }
        guard let writer else { throw TBDSpeechError.audioUnreadable("not recording") }
        try writer.close()
        if writer.samplesWritten == 0, let interruption {
            try? FileManager.default.removeItem(at: writer.url)
            throw TBDSpeechError.microphoneUnavailable(interruption.localizedDescription)
        }
        var warning: String?
        if let failure = writer.failure {
            let durationMs = (try? TBDWAVWriter.repairHeader(at: writer.url)) ?? 0
            warning = "Recording stopped early: \(failure.localizedDescription)"
            return Recording(url: writer.url, durationMs: durationMs, peakLevel: peak, warning: warning)
        }
        if let interruption { warning = "The microphone stopped early: \(interruption.localizedDescription)" }
        return Recording(url: writer.url, durationMs: writer.durationMs, peakLevel: peak, warning: warning)
    }

    /// Stops and deletes the recording.
    public func cancel() async {
        if let recording = try? await stop() { try? FileManager.default.removeItem(at: recording.url) }
    }
}
