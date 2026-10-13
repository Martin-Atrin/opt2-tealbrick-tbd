import XCTest
@testable import TBDSpeech

/// v1 gesture rules (FnKeyStateMachine, HotkeyGestureController, HotkeyManager event paths): exact
/// key event → output sequences for the shared Fn key, push to talk, hands-free and chords.
final class HotkeyGestureTests: XCTestCase {
    typealias Out = TBDHotkeyGestureController.Output
    let fnFlag: UInt64 = 0x80_0000
    let optionFlag: UInt64 = 0x8_0000
    let commandFlag: UInt64 = 0x10_0000
    let shiftFlag: UInt64 = 0x2_0000
    let rightOptionBit: UInt64 = 0x40
    let rightCommandBit: UInt64 = 0x10

    func matcher(_ text: String, _ mode: TBDHotkeyGestureController.Mode, debounce: Int = 100) throws -> TBDDictationHotkeyMatcher {
        TBDDictationHotkeyMatcher(hotkey: try TBDHotkey.parse(text), gesture: TBDHotkeyGestureController(mode: mode, startupDebounceMs: debounce))
    }

    func fnDown(_ t: UInt64) -> TBDKeyEvent { .flagsChanged(keyCode: 63, flags: fnFlag, timestampMs: t) }
    func fnUp(_ t: UInt64) -> TBDKeyEvent { .flagsChanged(keyCode: 63, flags: 0, timestampMs: t) }

    func testV1TimingDefaults() {
        XCTAssertEqual(TBDFnKeyStateMachine.defaultStartupDebounceMs, 100)
        XCTAssertEqual(TBDFnKeyStateMachine.defaultTapThresholdMs, 400)
        XCTAssertEqual(TBDDictationHotkeyPlan.holdToTalkStopTailMs, 200)
        XCTAssertEqual(TBDHotkeyGestureController(tapThresholdMs: 9_000).tapThresholdMs, 500)
        XCTAssertEqual(TBDHotkeyGestureController(tapThresholdMs: 10).tapThresholdMs, 50)
    }

    // MARK: Shared key (hold to talk, double-tap for hands-free)

    func testSharedKeyHoldPastThresholdIsPushToTalk() throws {
        var m = try matcher("fn", .doubleTapAndHold)
        XCTAssertEqual(m.handle(fnDown(1000)).outputs, [.scheduleStartupDebounce(milliseconds: 100), .scheduleHoldWindow(milliseconds: 400)])
        XCTAssertEqual(m.startupDebounceElapsed(), [.startRecording(mode: .holdToTalk)])
        XCTAssertEqual(m.holdWindowElapsed(), [])
        XCTAssertEqual(m.gesture.fnState, .holdToTalk)
        XCTAssertEqual(m.handle(fnUp(1900)).outputs, [.cancelStartupDebounce, .cancelHoldWindow, .stopRecording])
        XCTAssertEqual(m.gesture.fnState, .idle)
        XCTAssertNil(m.activeRecordingMode)
    }

    func testSharedKeyBounceUnderDebounceStartsNothing() throws {
        var m = try matcher("fn", .doubleTapAndHold)
        _ = m.handle(fnDown(0))
        XCTAssertEqual(m.handle(fnUp(80)).outputs, [.cancelStartupDebounce, .cancelHoldWindow, .showReadyForSecondTap])
        XCTAssertEqual(m.gesture.fnState, .waitingForSecondTap)
        XCTAssertNil(m.activeRecordingMode)
    }

    func testSharedKeyQuickTapAfterDebounceDiscardsProvisionalTake() throws {
        var m = try matcher("fn", .doubleTapAndHold)
        _ = m.handle(fnDown(0))
        XCTAssertEqual(m.startupDebounceElapsed(), [.startRecording(mode: .holdToTalk)])
        XCTAssertEqual(m.handle(fnUp(250)).outputs, [.cancelStartupDebounce, .cancelHoldWindow, .discardRecording(showReadyPill: true)])
    }

    func testSharedKeyDoubleTapIsHandsFreeAndNextPressStops() throws {
        var m = try matcher("fn", .doubleTapAndHold)
        _ = m.handle(fnDown(0))
        _ = m.handle(fnUp(80))
        XCTAssertEqual(m.handle(fnDown(200)).outputs, [.startRecording(mode: .persistent)])
        XCTAssertEqual(m.handle(fnUp(260)).outputs, [.cancelStartupDebounce, .cancelHoldWindow])
        XCTAssertEqual(m.activeRecordingMode, .persistent)
        XCTAssertEqual(m.handle(fnDown(3000)).outputs, [.stopRecording])
        XCTAssertNil(m.activeRecordingMode)
    }

    func testSharedKeySlowSecondTapIsANewFirstTap() throws {
        var m = try matcher("fn", .doubleTapAndHold)
        _ = m.handle(fnDown(0))
        _ = m.handle(fnUp(80))
        XCTAssertEqual(m.handle(fnDown(600)).outputs, [.scheduleStartupDebounce(milliseconds: 100), .scheduleHoldWindow(milliseconds: 400)])
    }

    func testFnShortcutIsNotDictation() throws {
        var m = try matcher("fn", .doubleTapAndHold)
        _ = m.handle(fnDown(0))
        // fn+arrow: any other key interrupts the pending gesture before it arms.
        XCTAssertEqual(m.handle(.keyDown(keyCode: 126, flags: fnFlag, timestampMs: 50)).outputs, [.cancelStartupDebounce, .cancelHoldWindow])
        XCTAssertEqual(m.startupDebounceElapsed(), [])
        // Releasing after a shortcut is a non-bare release: timers cleared, no take.
        XCTAssertEqual(m.handle(fnUp(300)).outputs, [.cancelStartupDebounce, .cancelHoldWindow])
        XCTAssertNil(m.activeRecordingMode)
    }

    func testEscapeCancelsAndBlocksUntilReset() throws {
        var m = try matcher("fn", .doubleTapAndHold)
        _ = m.handle(fnDown(0)); _ = m.handle(fnUp(80)); _ = m.handle(fnDown(200)); _ = m.handle(fnUp(260))
        XCTAssertEqual(m.handle(.keyDown(keyCode: 53, flags: 0, timestampMs: 900)).outputs, [.cancelStartupDebounce, .cancelHoldWindow, .cancelRecording])
        XCTAssertEqual(m.gesture.fnState, .cancelWindow)
        // Presses during the undo window are blocked.
        XCTAssertEqual(m.handle(fnDown(1200)).outputs, [])
        XCTAssertEqual(m.gesture.fnState, .blocked)
        m.resetToIdle()
        XCTAssertEqual(m.handle(fnDown(5000)).outputs, [.scheduleStartupDebounce(milliseconds: 100), .scheduleHoldWindow(milliseconds: 400)])
    }

    // MARK: Separate keys

    func testPushToTalkKeyHoldsAndReleases() throws {
        var m = try matcher("right_option", .holdOnly)
        let down = TBDKeyEvent.flagsChanged(keyCode: 61, flags: optionFlag | rightOptionBit, timestampMs: 0)
        let up = TBDKeyEvent.flagsChanged(keyCode: 61, flags: 0, timestampMs: 2000)
        XCTAssertEqual(m.handle(down).outputs, [.scheduleStartupDebounce(milliseconds: 100)])
        XCTAssertEqual(m.startupDebounceElapsed(), [.startRecording(mode: .holdToTalk)])
        XCTAssertEqual(m.handle(up).outputs, [.cancelStartupDebounce, .cancelHoldWindow, .stopRecording])
    }

    func testPushToTalkBounceUnderDebounceStartsNothing() throws {
        var m = try matcher("right_option", .holdOnly)
        _ = m.handle(.flagsChanged(keyCode: 61, flags: optionFlag | rightOptionBit, timestampMs: 0))
        XCTAssertEqual(m.handle(.flagsChanged(keyCode: 61, flags: 0, timestampMs: 60)).outputs, [.cancelStartupDebounce, .cancelHoldWindow])
        XCTAssertEqual(m.startupDebounceElapsed(), [])
    }

    func testPushToTalkWithAnotherKeyCancelsTheTake() throws {
        var m = try matcher("right_option", .holdOnly)
        _ = m.handle(.flagsChanged(keyCode: 61, flags: optionFlag | rightOptionBit, timestampMs: 0))
        _ = m.startupDebounceElapsed()
        XCTAssertEqual(m.handle(.keyDown(keyCode: 0, flags: optionFlag | rightOptionBit, timestampMs: 300)).outputs,
                       [.cancelStartupDebounce, .cancelHoldWindow, .cancelRecording])
    }

    func testLeftOptionDoesNotTriggerRightOptionKey() throws {
        var m = try matcher("right_option", .holdOnly)
        // The opposite side only interrupts (clears timers); it never starts a take.
        XCTAssertEqual(m.handle(.flagsChanged(keyCode: 58, flags: optionFlag | 0x20, timestampMs: 0)).outputs, [.cancelStartupDebounce, .cancelHoldWindow])
        XCTAssertEqual(m.startupDebounceElapsed(), [])
    }

    func testHandsFreeKeyTogglesOnReleaseOfABareTap() throws {
        var m = try matcher("right_cmd", .singleTapToggle)
        let down = TBDKeyEvent.flagsChanged(keyCode: 54, flags: commandFlag | rightCommandBit, timestampMs: 0)
        let up = TBDKeyEvent.flagsChanged(keyCode: 54, flags: 0, timestampMs: 100)
        XCTAssertEqual(m.handle(down).outputs, [])
        XCTAssertEqual(m.handle(up).outputs, [.startRecording(mode: .persistent)])
        XCTAssertEqual(m.handle(down).outputs, [])
        XCTAssertEqual(m.handle(up).outputs, [.stopRecording])
        // Right Command + C is a shortcut: no toggle.
        XCTAssertEqual(m.handle(down).outputs, [])
        XCTAssertEqual(m.handle(.keyDown(keyCode: 8, flags: commandFlag | rightCommandBit, timestampMs: 150)).outputs, [])
        XCTAssertEqual(m.handle(up).outputs, [])
        XCTAssertEqual(m.handle(.keyDown(keyCode: 53, flags: 0, timestampMs: 200)).outputs, [.escapeWhileIdle])
    }

    func testChordHotkeyIsSwallowedAndIgnoresRepeat() throws {
        var m = try matcher("cmd+shift+d", .singleTapToggle)
        let down = TBDKeyEvent.keyDown(keyCode: 2, flags: commandFlag | shiftFlag, timestampMs: 0)
        let first = m.handle(down)
        XCTAssertEqual(first.outputs, [.startRecording(mode: .persistent)])
        XCTAssertTrue(first.swallow)
        XCTAssertEqual(m.handle(down).outputs, [])           // key repeat
        let up = m.handle(.keyUp(keyCode: 2, flags: commandFlag | shiftFlag, timestampMs: 90))
        XCTAssertEqual(up.outputs, [])
        XCTAssertTrue(up.swallow)
        // Plain D is typing, not the hotkey.
        let plain = m.handle(.keyDown(keyCode: 2, flags: 0, timestampMs: 500))
        XCTAssertFalse(plain.swallow)
    }

    func testModifierChordStartsOnlyOnTheExactChord() throws {
        var m = try matcher("ctrl+opt", .holdOnly)
        let ctrl: UInt64 = 0x4_0000
        XCTAssertEqual(m.handle(.flagsChanged(keyCode: 59, flags: ctrl | 0x01, timestampMs: 0)).outputs, [])
        XCTAssertEqual(m.handle(.flagsChanged(keyCode: 58, flags: ctrl | optionFlag | 0x21, timestampMs: 10)).outputs,
                       [.scheduleStartupDebounce(milliseconds: 100)])
        XCTAssertEqual(m.startupDebounceElapsed(), [.startRecording(mode: .holdToTalk)])
        XCTAssertEqual(m.handle(.flagsChanged(keyCode: 58, flags: ctrl | 0x01, timestampMs: 900)).outputs,
                       [.cancelStartupDebounce, .cancelHoldWindow, .stopRecording])
    }

    func testSuppressedHotkeyIgnoresPressesUntilReset() throws {
        var m = try matcher("f15", .singleTapToggle)
        m.suppressUntilReset()
        XCTAssertEqual(m.handle(.keyDown(keyCode: 113, flags: 0, timestampMs: 0)).outputs, [])
        m.resetToIdle()
        _ = m.handle(.keyUp(keyCode: 113, flags: 0, timestampMs: 10))
        XCTAssertEqual(m.handle(.keyDown(keyCode: 113, flags: 0, timestampMs: 100)).outputs, [.startRecording(mode: .persistent)])
    }

    func testResumeModeTable() {
        typealias G = TBDHotkeyGestureController
        XCTAssertEqual(G.resumeMode(.persistent, for: .singleTapToggle), .persistent)
        XCTAssertEqual(G.resumeMode(.holdToTalk, for: .doubleTapAndHold), .holdToTalk)
        XCTAssertNil(G.resumeMode(.persistent, for: .holdOnly))
        XCTAssertNil(G.resumeMode(.holdToTalk, for: .singleTapToggle))
        XCTAssertNil(G.resumeMode(nil, for: .holdOnly))
    }

    // MARK: Immediate hotkeys (meeting, file, URL)

    func testShortcutFiresOncePerPress() throws {
        var m = TBDShortcutMatcher(hotkey: try TBDHotkey.parse("cmd+shift+m"))
        let down = TBDKeyEvent.keyDown(keyCode: 46, flags: commandFlag | shiftFlag, timestampMs: 0)
        XCTAssertTrue(m.handle(down) == (true, true))
        XCTAssertTrue(m.handle(down) == (false, true))
        XCTAssertTrue(m.handle(.keyUp(keyCode: 46, flags: commandFlag | shiftFlag, timestampMs: 5)) == (false, true))
        XCTAssertTrue(m.handle(.keyDown(keyCode: 46, flags: commandFlag, timestampMs: 9)) == (false, false))
        // F-keys carry the Fn flag on laptops; a chord without Fn ignores it.
        var f = TBDShortcutMatcher(hotkey: try TBDHotkey.parse("cmd+f13"))
        XCTAssertTrue(f.handle(.keyDown(keyCode: 105, flags: commandFlag | fnFlag, timestampMs: 0)) == (true, true))
    }

    func testModifierShortcutFiresOnPressNotRepeatedFlags() throws {
        var m = TBDShortcutMatcher(hotkey: try TBDHotkey.parse("right_option"))
        XCTAssertTrue(m.handle(.flagsChanged(keyCode: 61, flags: optionFlag | rightOptionBit, timestampMs: 0)).fired)
        XCTAssertFalse(m.handle(.flagsChanged(keyCode: 56, flags: optionFlag | rightOptionBit | shiftFlag | 0x02, timestampMs: 5)).fired)
        XCTAssertFalse(m.handle(.flagsChanged(keyCode: 61, flags: 0, timestampMs: 9)).fired)
        XCTAssertTrue(m.handle(.flagsChanged(keyCode: 61, flags: optionFlag | rightOptionBit, timestampMs: 20)).fired)
    }
}
