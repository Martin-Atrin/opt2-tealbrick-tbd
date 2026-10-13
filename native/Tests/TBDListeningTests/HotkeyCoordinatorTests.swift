import XCTest
import TBDSpeech
@testable import TBDListening

/// Each Listening hotkey reaches its exact action (v1 AppHotkeyCoordinator), and the dictation delivery
/// rules for clipboard-only and AI polish hold with fake paste, pasteboard and cleanup seams.
@MainActor
final class HotkeyCoordinatorTests: XCTestCase {
    final class FakeTargets: TBDHotkeyTargets {
        enum Call: Equatable {
            case start(TBDFnKeyStateMachine.RecordingMode, TBDDictationTakeOptions)
            case stop, cancel, discard(Bool), ready, perform(TBDListeningAction), transform, transformID(String), report(String)
        }
        var calls: [Call] = []
        var acceptStart = true
        var hotkeyRecordingMode: TBDFnKeyStateMachine.RecordingMode?
        func hotkeyStartDictation(mode: TBDFnKeyStateMachine.RecordingMode, options: TBDDictationTakeOptions) -> Bool {
            calls.append(.start(mode, options)); return acceptStart
        }
        func hotkeyStopDictation() { calls.append(.stop) }
        func hotkeyCancelDictation() { calls.append(.cancel) }
        func hotkeyDiscardDictation(showReadyPill: Bool) { calls.append(.discard(showReadyPill)) }
        func hotkeyReadyForSecondTap() { calls.append(.ready) }
        func hotkeyPerform(_ action: TBDListeningAction) { calls.append(.perform(action)) }
        func hotkeyRunTransform() { calls.append(.transform) }
        func hotkeyRunTransform(id: String) { calls.append(.transformID(id)) }
        func hotkeyReport(_ message: String) { calls.append(.report(message)) }
    }

    /// Timers run only when the test says so.
    final class Clock {
        var pending: [(ms: Int, work: @MainActor () -> Void, cancelled: Bool)] = []
        func schedule(_ ms: Int, _ work: @escaping @MainActor () -> Void) -> () -> Void {
            pending.append((ms, work, false))
            let index = pending.count - 1
            return { [weak self] in self?.pending[index].cancelled = true }
        }
        @MainActor func fire(_ ms: Int) {
            for index in pending.indices where pending[index].ms == ms && !pending[index].cancelled {
                pending[index].cancelled = true
                pending[index].work()
            }
        }
    }

    var suite = ""
    var defaults: UserDefaults!
    var prefs: TBDListeningPreferences!
    let targets = FakeTargets()
    let clock = Clock()

    override func setUp() {
        suite = "tbd.tests.hotkeycoordinator.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        prefs = TBDListeningPreferences(defaults: defaults)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func coordinator() -> TBDHotkeyCoordinator {
        let clock = self.clock
        let coordinator = TBDHotkeyCoordinator(preferences: prefs, schedule: { clock.schedule($0, $1) })
        coordinator.targets = targets
        coordinator.refreshAll()
        return coordinator
    }

    func key(_ text: String) -> TBDHotkey { try! TBDHotkey.parse(text) }
    func down(_ code: UInt16, _ flags: UInt64 = 0) -> TBDKeyEvent { .keyDown(keyCode: code, flags: flags, timestampMs: 0) }
    func up(_ code: UInt16, _ flags: UInt64 = 0) -> TBDKeyEvent { .keyUp(keyCode: code, flags: flags, timestampMs: 0) }

    func testEachTransformHotkeyRunsItsTransformAndSkipsReservedKeys() {
        prefs.setHotkey(key("ctrl+opt+t"), for: .transform)
        let clock = self.clock
        let c = TBDHotkeyCoordinator(preferences: prefs, schedule: { clock.schedule($0, $1) })
        c.targets = targets
        c.transformPrompts = {
            [TBDPrompt(id: "polish", name: "Polish", content: "x", category: .transform, hotkey: "ctrl+opt+1"),
             TBDPrompt(id: "clash", name: "Clash", content: "x", category: .transform, hotkey: "ctrl+opt+t")]
        }
        c.refreshAll()
        XCTAssertTrue(c.handle(down(18, 0xC_0000)))           // ⌃⌥1
        XCTAssertTrue(c.handle(down(17, 0xC_0000)))           // ⌃⌥T stays the general Transform key
        XCTAssertEqual(targets.calls, [.transformID("polish"), .transform])
    }

    func testImmediateHotkeysMapToTheirActions() {
        prefs.setHotkey(key("f13"), for: .fileTranscription)
        prefs.setHotkey(key("f14"), for: .urlTranscription)
        prefs.setHotkey(key("ctrl+opt+t"), for: .transform)
        let c = coordinator()
        XCTAssertTrue(c.handle(down(46, 0x12_0000)))          // ⇧⌘M (v1 default meeting key)
        XCTAssertTrue(c.handle(down(105)))
        XCTAssertTrue(c.handle(down(107)))
        XCTAssertTrue(c.handle(down(17, 0xC_0000)))           // ⌃⌥T
        XCTAssertEqual(targets.calls, [.perform(.meeting), .perform(.transcribeFile), .perform(.transcribeURL), .transform])
        XCTAssertEqual(TBDListeningAction.meeting.effect, .toggleMeeting)
        XCTAssertEqual(TBDListeningAction.transcribeFile.effect, .pickFiles)
        XCTAssertEqual(TBDListeningAction.transcribeURL.effect, .promptForURL)
        XCTAssertFalse(c.handle(down(2)))                     // typing passes through
    }

    func testClipboardAndAIPolishKeysStartTheirTakeAndToggle() {
        prefs.setHotkey(key("f15"), for: .dictationClipboard)
        prefs.setHotkey(key("f16"), for: .dictationAIPolish)
        let c = coordinator()
        _ = c.handle(down(113)); _ = c.handle(up(113))
        XCTAssertEqual(targets.calls, [.start(.persistent, .init(aiPolish: false, clipboardOnly: true))])
        _ = c.handle(down(113))
        XCTAssertEqual(targets.calls.last, .stop)
        _ = c.handle(up(113))
        targets.calls = []
        let f16 = key("f16").keyCode!
        _ = c.handle(down(f16))
        XCTAssertEqual(targets.calls, [.start(.persistent, .init(aiPolish: true, clipboardOnly: false))])
    }

    func testOtherDictationKeysStandDownWhileOneOwnsTheTake() {
        prefs.setHotkey(key("f15"), for: .dictationClipboard)
        prefs.setHotkey(key("f16"), for: .dictationAIPolish)
        let c = coordinator()
        _ = c.handle(down(key("f15").keyCode!))
        targets.calls = []
        _ = c.handle(down(key("f16").keyCode!))
        XCTAssertEqual(targets.calls, [], "AI polish key is suppressed while clipboard-only records")
    }

    func testPushToTalkStopsAfterTheV1Tail() {
        prefs.setHotkey(key("f13"), for: .pushToTalk)
        prefs.setHotkey(key("f14"), for: .handsFree)
        let c = coordinator()
        _ = c.handle(down(105))
        clock.fire(100)
        XCTAssertEqual(targets.calls, [.start(.holdToTalk, .init())])
        _ = c.handle(up(105))
        XCTAssertEqual(targets.calls.count, 1, "stop waits for the tail")
        clock.fire(200)
        XCTAssertEqual(targets.calls.last, .stop)
    }

    func testRefusedStartLeavesTheNextPressAbleToStart() {
        prefs.setHotkey(key("f14"), for: .handsFree)
        prefs.setHotkey(nil, for: .pushToTalk)
        let c = coordinator()
        targets.acceptStart = false
        _ = c.handle(down(107))
        targets.acceptStart = true
        _ = c.handle(up(107))
        _ = c.handle(down(107))
        XCTAssertEqual(targets.calls, [.start(.persistent, .init()), .start(.persistent, .init())])
    }

    func testSharedFnKeyDoubleTapRoutesThroughTheController() {
        prefs.setHotkey(nil, for: .meeting)
        let c = coordinator()   // v1 defaults: Fn for both keys
        let fnDown = TBDKeyEvent.flagsChanged(keyCode: 63, flags: 0x80_0000, timestampMs: 0)
        let fnUp = TBDKeyEvent.flagsChanged(keyCode: 63, flags: 0, timestampMs: 60)
        XCTAssertFalse(c.handle(fnDown))
        XCTAssertFalse(c.needsActiveTap, "bare Fn only observes events")
        _ = c.handle(fnUp)
        _ = c.handle(.flagsChanged(keyCode: 63, flags: 0x80_0000, timestampMs: 150))
        XCTAssertEqual(targets.calls, [.ready, .start(.persistent, .init())])
    }

    func testRuntimeConflictTurnsTheLaterHotkeyOffAndReportsIt() {
        prefs.setHotkey(key("f13"), for: .fileTranscription)
        prefs.setHotkey(key("f13"), for: .urlTranscription)
        let c = coordinator()
        XCTAssertEqual(targets.calls, [
            .report("Hotkey F13 is off: it conflicts with F13. Change it in Settings > Capture."),
            .report("Hotkey F13 is off: it conflicts with F13. Change it in Settings > Capture."),
        ])
        targets.calls = []
        XCTAssertFalse(c.handle(down(105)))
        XCTAssertEqual(targets.calls, [])
    }

    func testSuspendStandsDownUntilResume() {
        prefs.setHotkey(key("f13"), for: .fileTranscription)
        let c = coordinator()
        c.suspend()
        XCTAssertFalse(c.hasHotkeys)
        XCTAssertFalse(c.handle(down(105)))
        c.resume()
        XCTAssertTrue(c.handle(down(105)))
        XCTAssertEqual(targets.calls, [.perform(.transcribeFile)])
    }

    // MARK: Delivery

    func testClipboardOnlyCopiesAndNeverPastes() async throws {
        var pasted: [String] = []
        var copied: [String] = []
        var cleaned: [String] = []
        let delivery = TBDDictationDelivery(paste: { pasted.append($0) }, copy: { copied.append($0) },
                                            cleanup: { cleaned.append($0); return "cleaned" })
        let outcome = try await delivery.deliver("hello world", options: .init(clipboardOnly: true), cleanupSetting: false)
        XCTAssertEqual(outcome, .init(text: "hello world", destination: .copied, cleanupWarning: ""))
        XCTAssertEqual(copied, ["hello world"])
        XCTAssertEqual(pasted, [])
        XCTAssertEqual(cleaned, [])
        let empty = try await delivery.deliver("  ", options: .init(clipboardOnly: true), cleanupSetting: false)
        XCTAssertEqual(empty.destination, .skipped)
        XCTAssertEqual(copied, ["hello world"])
    }

    func testAIPolishForcesCleanupEvenWhenTheSettingIsOff() async throws {
        var pasted: [String] = []
        var cleaned: [String] = []
        let delivery = TBDDictationDelivery(paste: { pasted.append($0) }, copy: { _ in XCTFail("no copy") },
                                            cleanup: { cleaned.append($0); return "Hello, world." })
        let outcome = try await delivery.deliver("hello world", options: .init(aiPolish: true), cleanupSetting: false)
        XCTAssertEqual(outcome, .init(text: "Hello, world.", destination: .pasted, cleanupWarning: ""))
        XCTAssertEqual(cleaned, ["hello world"])
        XCTAssertEqual(pasted, ["Hello, world."])
    }

    func testPlainDictationSkipsCleanupWhenTheSettingIsOff() async throws {
        var pasted: [String] = []
        let delivery = TBDDictationDelivery(paste: { pasted.append($0) }, copy: { _ in },
                                            cleanup: { _ in XCTFail("no cleanup"); return "" })
        let outcome = try await delivery.deliver("hello", options: .init(), cleanupSetting: false)
        XCTAssertEqual(outcome.destination, .pasted)
        XCTAssertEqual(pasted, ["hello"])
    }

    func testAIPolishFallsBackToRawTextWhenTheModelFails() async throws {
        struct Down: Error {}
        var pasted: [String] = []
        let delivery = TBDDictationDelivery(paste: { pasted.append($0) }, copy: { _ in }, cleanup: { _ in throw Down() })
        let outcome = try await delivery.deliver("hello", options: .init(aiPolish: true), cleanupSetting: false)
        XCTAssertEqual(outcome, .init(text: "hello", destination: .pasted, cleanupWarning: "Cleanup unavailable; kept raw transcript."))
        XCTAssertEqual(pasted, ["hello"])
    }

    func testModeGuideRowsMatchV1() {
        let rows = TBDDictationHotkeyRows.guide(handsFree: .fn, pushToTalk: .fn, clipboard: key("f15"), aiPolish: nil)
        XCTAssertEqual(rows, [
            .init(key: "fn", verb: "Hold", action: "Push to talk", detail: "Release to stop"),
            .init(key: "fn", verb: "Double-tap", action: "Hands-free mode", detail: "Tap again to stop"),
            .init(key: "F15", verb: "Tap", action: "Clipboard-only", detail: "Copies; does not paste"),
        ])
    }
}
