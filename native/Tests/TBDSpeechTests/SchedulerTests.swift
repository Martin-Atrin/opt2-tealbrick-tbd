import XCTest
@testable import TBDSpeech

private actor Log {
    var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}

final class SchedulerTests: XCTestCase {
    /// While the background lane is busy, waiting jobs run by priority, FIFO within a kind.
    func testBackgroundPriorityOrder() async throws {
        let scheduler = TBDSTTScheduler()
        let log = Log()
        let gate = AsyncStream<Void>.makeStream()
        let blocker = Task { try await scheduler.run(.file) { for await _ in gate.stream { break }; await log.add("blocker") } }
        try await Task.sleep(for: .milliseconds(50))
        var jobs: [Task<Void, Error>] = []
        for (kind, name) in [(TBDJobKind.file, "file1"), (.meetingFinal, "final"), (.file, "file2"), (.meetingLive, "live")] {
            jobs.append(Task { try await scheduler.run(kind) { await log.add(name) } })
            try await Task.sleep(for: .milliseconds(20))
        }
        gate.continuation.yield(())
        try await blocker.value
        for job in jobs { try await job.value }
        let entries = await log.entries
        XCTAssertEqual(entries, ["blocker", "live", "final", "file1", "file2"])
    }

    /// Dictation uses its own lane and does not wait for a running file job.
    func testDictationDoesNotWaitForBackground() async throws {
        let scheduler = TBDSTTScheduler()
        let gate = AsyncStream<Void>.makeStream()
        let blocker = Task { try await scheduler.run(.file) { for await _ in gate.stream { break } } }
        try await Task.sleep(for: .milliseconds(50))
        let value = try await scheduler.run(.dictation) { 42 }
        XCTAssertEqual(value, 42)
        gate.continuation.yield(())
        try await blocker.value
    }

    func testCancellingQueuedJobRemovesIt() async throws {
        let scheduler = TBDSTTScheduler()
        let log = Log()
        let gate = AsyncStream<Void>.makeStream()
        let blocker = Task { try await scheduler.run(.file) { for await _ in gate.stream { break } } }
        try await Task.sleep(for: .milliseconds(50))
        let queued = Task { try await scheduler.run(.file) { await log.add("ran") } }
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()
        do { try await queued.value; XCTFail("expected cancellation") } catch is CancellationError {}
        let pending = await scheduler.pendingCount
        XCTAssertEqual(pending, 0)
        gate.continuation.yield(())
        try await blocker.value
        let entries = await log.entries
        XCTAssertEqual(entries, [])
    }

    func testCancellingRunningJobCancelsWork() async throws {
        let scheduler = TBDSTTScheduler()
        let running = Task { try await scheduler.run(.file) { try await Task.sleep(for: .seconds(30)) } }
        try await Task.sleep(for: .milliseconds(50))
        running.cancel()
        do { try await running.value; XCTFail("expected cancellation") } catch is CancellationError {}
        let value = try await scheduler.run(.file) { "next" }
        XCTAssertEqual(value, "next")
    }

    func testLiveBacklogDropsOldestChunks() async throws {
        let scheduler = TBDSTTScheduler(liveBacklogLimit: 2)
        let gate = AsyncStream<Void>.makeStream()
        let blocker = Task { try await scheduler.run(.file) { for await _ in gate.stream { break } } }
        try await Task.sleep(for: .milliseconds(50))
        var chunks: [Task<Int, Error>] = []
        for index in 0..<4 {
            chunks.append(Task { try await scheduler.run(.meetingLive) { index } })
            try await Task.sleep(for: .milliseconds(20))
        }
        gate.continuation.yield(())
        try await blocker.value
        var results: [String] = []
        for chunk in chunks {
            do { results.append(String(try await chunk.value)) } catch TBDSpeechError.dropped { results.append("dropped") }
        }
        XCTAssertEqual(results, ["dropped", "dropped", "2", "3"])
    }
}
