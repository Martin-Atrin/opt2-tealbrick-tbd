import XCTest
@testable import TBDSpeech

final class HotkeyTests: XCTestCase {
    func testParseBareAndSidedModifiers() throws {
        XCTAssertEqual(try TBDHotkey.parse("fn"), .fn)
        XCTAssertEqual(try TBDHotkey.parse("Globe"), .fn)
        let right = try TBDHotkey.parse("right_option")
        XCTAssertEqual(right, TBDHotkey(modifiers: [.option], side: .right))
        XCTAssertEqual(right.modifierKeyCode, 61)
        XCTAssertEqual(try TBDHotkey.parse("lcmd").modifierKeyCode, 55)
        XCTAssertEqual(right.displayName, "Right ⌥")
    }

    func testParseChordsAndKeys() throws {
        let chord = try TBDHotkey.parse("ctrl+opt")
        XCTAssertEqual(chord.modifiers, [.control, .option])
        XCTAssertTrue(chord.isModifierOnly)
        let f13 = try TBDHotkey.parse("F13")
        XCTAssertEqual(f13.keyCode, 105)
        XCTAssertTrue(f13.modifiers.isEmpty)
        XCTAssertEqual(f13.displayName, "F13")
        for (index, code) in [105, 107, 113, 106, 64, 79, 80].enumerated() {
            XCTAssertEqual(try TBDHotkey.parse("f\(13 + index)").keyCode, UInt16(code))
        }
        let combo = try TBDHotkey.parse("cmd + shift + d")
        XCTAssertEqual(combo.modifiers, [.command, .shift])
        XCTAssertEqual(combo.keyCode, 2)
        XCTAssertEqual(try TBDHotkey.parse("ctrl+opt+space").displayName, "⌃⌥Space")
    }

    func testSerializationRoundTrip() throws {
        for text in ["fn", "right_option", "ctrl+opt", "f13", "ctrl+opt+space", "fn+shift", "cmd+shift+d", "left_shift"] {
            let hotkey = try TBDHotkey.parse(text)
            XCTAssertEqual(try TBDHotkey.parse(hotkey.serialized), hotkey, text)
        }
        XCTAssertEqual(try TBDHotkey.parse("shift+ctrl+space").serialized, "ctrl+shift+space")
    }

    func testRejectsUnsafeHotkeys() {
        XCTAssertThrowsError(try TBDHotkey.parse("d")) { XCTAssertEqual($0 as? TBDHotkey.ParseError, .needsModifier("d")) }
        XCTAssertThrowsError(try TBDHotkey.parse("space"))
        XCTAssertThrowsError(try TBDHotkey.parse("ctrl+esc")) { XCTAssertEqual($0 as? TBDHotkey.ParseError, .reserved("esc")) }
        XCTAssertThrowsError(try TBDHotkey.parse("hyper+x")) { XCTAssertEqual($0 as? TBDHotkey.ParseError, .unknownToken("hyper")) }
        XCTAssertThrowsError(try TBDHotkey.parse("")) { XCTAssertEqual($0 as? TBDHotkey.ParseError, .empty) }
        XCTAssertThrowsError(try TBDHotkey.parse("ctrl+a+b"))
    }

    func testHoldToTalk() {
        var gesture = TBDHotkeyGesture(tapThresholdMs: 350)
        XCTAssertEqual(gesture.press(at: 1000), .none)
        XCTAssertEqual(gesture.armed(), .start)
        XCTAssertEqual(gesture.release(at: 2500), .stop)
        XCTAssertEqual(gesture.state, .idle)
    }

    func testTapForHandsFreeThenTapToStop() {
        var gesture = TBDHotkeyGesture(tapThresholdMs: 350)
        _ = gesture.press(at: 1000)
        XCTAssertEqual(gesture.armed(), .start)
        XCTAssertEqual(gesture.release(at: 1200), .handsFree)
        XCTAssertEqual(gesture.press(at: 5000), .stop)
        XCTAssertEqual(gesture.release(at: 5100), .none)
        XCTAssertEqual(gesture.state, .idle)
    }

    func testVeryQuickTapStartsHandsFree() {
        var gesture = TBDHotkeyGesture()
        _ = gesture.press(at: 0)
        XCTAssertEqual(gesture.release(at: 60), .startHandsFree)
        XCTAssertEqual(gesture.state, .handsFree)
    }

    func testShortcutWithModifierIsNotDictation() {
        var gesture = TBDHotkeyGesture()
        _ = gesture.press(at: 0)
        XCTAssertEqual(gesture.otherKey(), .none)
        XCTAssertEqual(gesture.armed(), .none)
        XCTAssertEqual(gesture.release(at: 900), .none)
        XCTAssertEqual(gesture.state, .idle)
        _ = gesture.press(at: 2000)
        XCTAssertEqual(gesture.armed(), .start)
        XCTAssertEqual(gesture.otherKey(), .cancel)
    }

    func testEscapeCancels() {
        var gesture = TBDHotkeyGesture()
        _ = gesture.press(at: 0); _ = gesture.armed(); _ = gesture.release(at: 100)
        XCTAssertEqual(gesture.escape(keyHeld: false), .cancel)
        XCTAssertEqual(gesture.state, .idle)
        _ = gesture.press(at: 1000); _ = gesture.armed()
        XCTAssertEqual(gesture.escape(keyHeld: true), .cancel)
        XCTAssertEqual(gesture.release(at: 3000), .none)
        XCTAssertEqual(gesture.state, .idle)
    }
}
