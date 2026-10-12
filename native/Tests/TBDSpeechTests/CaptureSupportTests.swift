import XCTest
@testable import TBDSpeech

final class CaptureSupportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func touch(_ path: String, bytes: Int = 1) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    func testUndoWindowCountsDownAndExpires() {
        var undo = TBDCancelUndo()
        let take = URL(fileURLWithPath: "/tmp/a.wav")
        XCTAssertTrue(undo.hold(take, durationMs: 1200, window: .fiveSeconds).accepted)
        let generation = undo.pending!.generation
        XCTAssertEqual(undo.pending?.remaining, 5)
        for _ in 0..<4 { XCTAssertNil(undo.tick(generation: generation)) }
        XCTAssertEqual(undo.pending?.remaining, 1)
        XCTAssertEqual(undo.tick(generation: generation), take, "expiry hands back the audio to delete")
        XCTAssertNil(undo.pending)
        XCTAssertNil(undo.undo(), "nothing to undo after expiry")
    }

    func testUndoReturnsTheTakeAndStaleTicksAreIgnored() {
        var undo = TBDCancelUndo()
        let first = URL(fileURLWithPath: "/tmp/1.wav"), second = URL(fileURLWithPath: "/tmp/2.wav")
        _ = undo.hold(first, durationMs: 500, window: .oneSecond)
        let old = undo.pending!.generation
        let replaced = undo.hold(second, durationMs: 900, window: .fiveSeconds)
        XCTAssertEqual(replaced.discard, first, "a newer cancel discards the older take")
        XCTAssertNil(undo.tick(generation: old), "the old timer cannot expire the new take")
        XCTAssertEqual(undo.pending?.remaining, 5)
        let taken = undo.undo()
        XCTAssertEqual(taken?.url, second)
        XCTAssertEqual(taken?.durationMs, 900)
        XCTAssertNil(undo.discard())
    }

    func testUndoOffDiscardsImmediately() {
        var undo = TBDCancelUndo()
        let result = undo.hold(URL(fileURLWithPath: "/tmp/x.wav"), durationMs: 800, window: .off)
        XCTAssertFalse(result.accepted)
        XCTAssertNil(undo.pending)
        _ = undo.hold(URL(fileURLWithPath: "/tmp/y.wav"), durationMs: 800, window: .oneSecond)
        XCTAssertEqual(undo.discard(), URL(fileURLWithPath: "/tmp/y.wav"))
    }

    func testFolderDropExpandsRecursivelyInNaturalOrder() throws {
        _ = try touch("course/lecture10.mp3")
        _ = try touch("course/lecture2.m4a")
        _ = try touch("course/sub/lecture1.wav")
        _ = try touch("course/notes.txt")
        _ = try touch("course/.hidden.mp3")
        let single = try touch("extra.MOV")
        let result = TBDAudioFileEnumerator.expand([root.appendingPathComponent("course"), single, single])
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["extra.MOV", "lecture1.wav", "lecture2.m4a", "lecture10.mp3"])
        XCTAssertEqual(result.dropped, 0)

        let limited = TBDAudioFileEnumerator.expand([root.appendingPathComponent("course")], maxFiles: 2)
        XCTAssertEqual(limited.files.count, 2)
        XCTAssertGreaterThanOrEqual(limited.dropped, 1)
        XCTAssertEqual(TBDAudioFileEnumerator.expand([root.appendingPathComponent("course/notes.txt")]).skippedUnsupported, 1)
    }

    func testCalendarSkipsByOccurrenceAndSeriesWithPruning() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var skips = TBDCalendarSkips()
        skips.occurrences.insert(TBDCalendarSkips.occurrenceKey(id: "e1", start: now))
        XCTAssertTrue(skips.skips(id: "e1", seriesID: "s1", start: now))
        XCTAssertFalse(skips.skips(id: "e1", seriesID: "s1", start: now.addingTimeInterval(7 * 86_400)), "next week's occurrence still records")
        skips.series.insert("s1")
        XCTAssertTrue(skips.skips(id: "e2", seriesID: "s1", start: now.addingTimeInterval(7 * 86_400)))
        skips.occurrences.insert(TBDCalendarSkips.occurrenceKey(id: "old", start: now.addingTimeInterval(-20 * 86_400)))
        skips.prune(now: now)
        XCTAssertEqual(skips.occurrences, [TBDCalendarSkips.occurrenceKey(id: "e1", start: now)])
        XCTAssertEqual(skips.series, ["s1"], "series skips are kept")
        let data = try! JSONEncoder().encode(skips)
        XCTAssertEqual(try! JSONDecoder().decode(TBDCalendarSkips.self, from: data), skips)
    }

    func testRecoveryScanOffersViableRecordingsOnly() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        func folder(_ name: String, state: TBDMeetingManifest.State, bytes: Int, started: TimeInterval) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            _ = try touch("\(name)/microphone.wav", bytes: bytes)
            try TBDMeetingManifest(id: name, title: "Meeting", startedAt: Date(timeIntervalSince1970: started), state: state,
                                   durationMs: 0, transcriptionID: name + "-t").write(to: url)
            return url
        }
        let late = try folder("late", state: .recording, bytes: 64_000, started: 2000)
        let early = try folder("early", state: .stopped, bytes: 64_000, started: 1000)
        let tiny = try folder("tiny", state: .recording, bytes: 600, started: 1500)
        _ = try folder("done", state: .done, bytes: 64_000, started: 500)
        let scan = TBDMeetingRecovery.scan(meetingsRoot: root, database: db)
        XCTAssertEqual(scan.offer.map(\.folder.lastPathComponent), [early, late].map(\.lastPathComponent), "oldest first, finished ones skipped")
        XCTAssertEqual(scan.empty.map(\.lastPathComponent), [tiny.lastPathComponent])
    }
}
