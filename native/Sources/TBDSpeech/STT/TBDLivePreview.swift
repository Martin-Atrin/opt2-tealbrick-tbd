import Foundation

/// Display-only text while someone dictates. Created by the caller before recording starts (so
/// no samples are missed while the engine loads) and attached to the live engine with
/// `TBDSpeechService.startLivePreview(_:)`.
///
/// Two modes, as in the donor:
/// - streaming: engines with native partials (Nemotron, Parakeet Unified) get every sample;
/// - tail: fast batch engines (Parakeet v2/v3) re-transcribe the last 15 s once a second,
///   single flight, so a slow pass never queues up.
///
/// The dictation result never comes from here: it is transcribed from the recorded audio after
/// `stop()` has drained the preview, so a dropped or failed preview only affects the overlay.
public final class TBDLivePreview: @unchecked Sendable {
    public enum Mode: String, Sendable, Equatable { case streaming, tail }

    /// The preview mode an engine supports, or nil when it shows nothing while recording.
    public static func mode(for kind: TBDSpeechEngineKind) -> Mode? {
        let capabilities = kind.capabilities
        if capabilities.streaming { return .streaming }
        if capabilities.tailPreview { return .tail }
        return nil
    }

    public static let tailInterval: Duration = .seconds(1)
    public static let tailWindowSamples = 15 * 16_000
    /// Longest wait for an in-flight preview pass on stop (the final pass waits for the lane).
    public static let drainTimeout: Duration = .seconds(2)

    private let samples: AsyncStream<[Float]>
    private let samplesContinuation: AsyncStream<[Float]>.Continuation
    private let partials: AsyncStream<String>
    private let partialsContinuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var worker: Task<Void, Never>?
    private var consumer: Task<Void, Never>?
    private var stopped = false
    private var onEnd: (@Sendable () async -> Void)?

    /// `onPartial` runs on the main actor, in order, newest text only.
    public init(onPartial: @escaping @MainActor @Sendable (String) -> Void) {
        (samples, samplesContinuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(400))
        (partials, partialsContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        let partials = self.partials
        consumer = Task {
            for await text in partials { await onPartial(text) }
        }
    }

    /// Feeds 16 kHz mono samples. Non-blocking; safe from the audio tap thread.
    public func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        samplesContinuation.yield(chunk)
    }

    /// Ends the preview and waits (bounded) until the engine is free for the final pass.
    public func stop() async {
        let (worker, onEnd) = lock.withLock { () -> (Task<Void, Never>?, (@Sendable () async -> Void)?) in
            stopped = true
            defer { self.onEnd = nil }
            return (self.worker, self.onEnd)
        }
        samplesContinuation.finish()
        if let worker {
            let finished = await Self.wait(for: worker, timeout: Self.drainTimeout)
            if !finished { worker.cancel(); await worker.value }
        }
        // Deliver what is queued (newest only), then end.
        partialsContinuation.finish()
        await consumer?.value
        await onEnd?()
    }

    private static func wait(for task: Task<Void, Never>, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Starts the worker. Returns false when already stopped.
    func start(engine: any TBDSpeechEngine, mode: Mode, language: String?, onEnd: @escaping @Sendable () async -> Void) -> Bool {
        let samples = self.samples
        let partials = partialsContinuation
        return lock.withLock {
            guard !stopped, worker == nil else { return false }
            self.onEnd = onEnd
            switch mode {
            case .streaming:
                guard let streaming = engine as? any TBDStreamingSpeechEngine else { return false }
                worker = Task { await Self.stream(streaming, language: language, samples: samples, partials: partials) }
            case .tail:
                worker = Task { await Self.tail(engine, samples: samples, partials: partials) }
            }
            return true
        }
    }

    private static func stream(_ engine: any TBDStreamingSpeechEngine, language: String?, samples: AsyncStream<[Float]>,
                               partials: AsyncStream<String>.Continuation) async {
        do {
            try await engine.beginLive(language: language) { partials.yield($0) }
        } catch {
            return
        }
        do {
            for await chunk in samples {
                try Task.checkCancellation()
                try await engine.appendLive(chunk)
            }
        } catch {}
        // Partials are display-only, so the session's own final text is not needed.
        await engine.cancelLive()
    }

    private static func tail(_ engine: any TBDSpeechEngine, samples: AsyncStream<[Float]>,
                             partials: AsyncStream<String>.Continuation) async {
        var window = TBDTailWindow(capacity: tailWindowSamples)
        let clock = ContinuousClock()
        var lastPass = clock.now
        for await chunk in samples {
            if Task.isCancelled { break }
            window.append(chunk)
            guard lastPass.duration(to: clock.now) >= tailInterval else { continue }
            lastPass = clock.now
            let audio = window.samples
            guard audio.count >= 8_000 else { continue }
            do {
                let transcript = try await engine.transcribe(samples: audio, lane: .interactive)
                partials.yield(transcript.trimmedText)
            } catch is CancellationError {
                break
            } catch {
                continue
            }
        }
    }
}

/// The most recent `capacity` samples, with amortised trimming.
struct TBDTailWindow {
    let capacity: Int
    private var storage: [Float] = []
    private var start = 0

    init(capacity: Int) { self.capacity = max(1, capacity) }

    mutating func append(_ chunk: [Float]) {
        storage.append(contentsOf: chunk)
        let visible = storage.count - start
        if visible > capacity { start += visible - capacity }
        if start > capacity, start * 2 > storage.count {
            storage.removeFirst(start)
            start = 0
        }
    }

    var samples: [Float] { start < storage.count ? Array(storage[start...]) : [] }
}

extension TBDSpeechService {
    /// Attaches `preview` to the live engine. Returns the mode, or nil when the live engine shows
    /// no preview or its model is not downloaded (the preview then stays empty).
    @discardableResult
    public func startLivePreview(_ preview: TBDLivePreview) -> TBDLivePreview.Mode? {
        let selection = selection(for: .live)
        guard let mode = TBDLivePreview.mode(for: selection.kind), isReady(.live) else { return nil }
        let engine = retain(selection)
        let started = preview.start(engine: engine, mode: mode, language: selection.language) { [weak self] in
            await self?.release(engine)
        }
        if !started { release(engine) }
        return started ? mode : nil
    }
}
