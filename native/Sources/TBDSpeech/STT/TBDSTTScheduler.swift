import Foundation

/// Kinds of speech work, highest priority first.
public enum TBDJobKind: Int, Comparable, Sendable, CaseIterable {
    case dictation = 0, meetingLive, meetingFinal, file

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    /// Dictation runs on its own lane; everything else shares the background lane by priority.
    public var lane: TBDLane { self == .dictation ? .interactive : .background }
}

/// Serialises speech jobs per lane with priority ordering (dictation > meeting live preview >
/// meeting final > file batch) and FIFO order within a kind. Work runs in the caller's task, so
/// cancelling the caller cancels a running job, and cancelling a queued caller removes its job.
public actor TBDSTTScheduler {
    private struct Waiter {
        let id: UUID
        let kind: TBDJobKind
        let order: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var busy: Set<TBDLane> = []
    private var waiters: [Waiter] = []
    private var order: UInt64 = 0
    private var cancelledEarly: Set<UUID> = []
    /// Live preview chunks older than this backlog are dropped so the preview stays current.
    public let liveBacklogLimit: Int

    public init(liveBacklogLimit: Int = 8) { self.liveBacklogLimit = max(1, liveBacklogLimit) }

    /// Runs `work` when its lane is free and no higher-priority job is waiting.
    public func run<T: Sendable>(_ kind: TBDJobKind, _ work: @Sendable () async throws -> T) async throws -> T {
        try await acquire(kind)
        defer { release(kind.lane) }
        try Task.checkCancellation()
        return try await work()
    }

    /// Number of jobs waiting (not running).
    public var pendingCount: Int { waiters.count }

    private func acquire(_ kind: TBDJobKind) async throws {
        let lane = kind.lane
        if !busy.contains(lane), !waiters.contains(where: { $0.kind.lane == lane }) {
            busy.insert(lane)
            return
        }
        let id = UUID()
        order &+= 1
        let position = order
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelledEarly.remove(id) != nil { continuation.resume(throwing: CancellationError()); return }
                waiters.append(Waiter(id: id, kind: kind, order: position, continuation: continuation))
                if kind == .meetingLive { trimLiveBacklog() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { cancelledEarly.insert(id); return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func trimLiveBacklog() {
        let live = waiters.filter { $0.kind == .meetingLive }.sorted { $0.order < $1.order }
        guard live.count > liveBacklogLimit else { return }
        for stale in live.prefix(live.count - liveBacklogLimit) {
            waiters.removeAll { $0.id == stale.id }
            stale.continuation.resume(throwing: TBDSpeechError.dropped)
        }
    }

    private func release(_ lane: TBDLane) {
        let candidates = waiters.enumerated().filter { $0.element.kind.lane == lane }
        guard let next = candidates.min(by: { ($0.element.kind, $0.element.order) < ($1.element.kind, $1.element.order) }) else {
            busy.remove(lane)
            return
        }
        waiters.remove(at: next.offset)
        next.element.continuation.resume()
    }
}
