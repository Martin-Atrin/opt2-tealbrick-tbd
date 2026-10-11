import Foundation

/// A value guarded by a lock.
final class NSLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// FIFO async mutex. Waiting honours task cancellation.
public final class TBDAsyncLock: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init() {}

    public func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                if !held { held = true; lock.unlock(); continuation.resume(); return }
                waiters.append((id, continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let index = waiters.firstIndex { $0.id == id }
            let waiter = index.map { waiters.remove(at: $0) }
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    public func release() {
        lock.lock()
        if waiters.isEmpty { held = false; lock.unlock(); return }
        let next = waiters.removeFirst()
        lock.unlock()
        next.continuation.resume()
    }

    public func withLock<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }
}

/// Serialises Neural Engine inference on macOS 14, where concurrent CoreML predictions can crash
/// (the shared ANE queue faults). A no-op on macOS 15 and later.
public enum TBDInferenceGate {
    static let lock = TBDAsyncLock()
    public static var required: Bool { if #available(macOS 15.0, *) { false } else { true } }

    public static func run<T>(_ body: () async throws -> T) async throws -> T {
        guard required else { return try await body() }
        return try await lock.withLock(body)
    }
}
