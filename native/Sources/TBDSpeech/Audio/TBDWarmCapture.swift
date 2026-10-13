import AVFoundation
import Foundation

/// Instant dictation: keeps the microphone engine running and the last second of audio in a ring buffer, so a
/// dictation starts at once and the first words are not clipped (v1 warm capture). macOS shows the microphone
/// indicator while it runs. It stays off on Bluetooth inputs, where an open microphone drops playback quality.
public final class TBDWarmCapture: @unchecked Sendable {
    private let microphone: TBDSharedMicrophone
    private let lock = NSLock()
    private var token: TBDSharedMicrophone.Token?
    private var resampler = TBDMonoResampler()
    private var buffer = TBDPreRollBuffer()
    private var accepting = true
    private var generation = 0

    public init(microphone: TBDSharedMicrophone = .shared) { self.microphone = microphone }

    public var isWarm: Bool { lock.withLock { token != nil } }

    /// Starts or stops holding the microphone. `preferredUID` is the chosen input (nil: the system default).
    public func configure(enabled: Bool, preferredUID: String?) async {
        let bluetooth = (preferredUID.flatMap { TBDAudioDevices.input(uid: $0) } ?? TBDAudioDevices.defaultInput())?.isBluetooth ?? false
        guard enabled, !bluetooth else { await release(); return }
        guard lock.withLock({ token == nil }), await TBDSharedMicrophone.requestPermission() else { return }
        let mine = lock.withLock { () -> Int in generation += 1; buffer.clear(); resampler = TBDMonoResampler(); return generation }
        guard let new = try? await microphone.subscribe(handler: { [weak self] in self?.consume($0) }) else { return }
        let keep = lock.withLock { () -> Bool in
            guard generation == mine, token == nil else { return false }
            token = new
            return true
        }
        if !keep { await microphone.unsubscribe(new) }
    }

    public func release() async {
        let old = lock.withLock { () -> TBDSharedMicrophone.Token? in
            generation += 1
            buffer.clear()
            defer { token = nil }
            return token
        }
        if let old { await microphone.unsubscribe(old) }
    }

    /// The audio just before now, and stop collecting until `resumeCollecting()` (a recording has its own subscription).
    public func takePreRoll() -> [Float] {
        lock.withLock {
            accepting = false
            defer { buffer.clear() }
            return buffer.latest()
        }
    }

    /// Drops what was collected: the pre-roll holds media sound that a pause cannot remove.
    public func discardPreRoll() { lock.withLock { buffer.clear() } }

    public func resumeCollecting() { lock.withLock { buffer.clear(); accepting = true } }

    private func consume(_ pcm: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        buffer.append(resampler.convert(pcm))
    }
}
