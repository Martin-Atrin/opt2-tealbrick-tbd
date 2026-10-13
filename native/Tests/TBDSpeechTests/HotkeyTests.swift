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

    func testRejectsUnparsableAndReservedHotkeys() {
        XCTAssertThrowsError(try TBDHotkey.parse("ctrl+esc")) { XCTAssertEqual($0 as? TBDHotkey.ParseError, .reserved("esc")) }
        XCTAssertThrowsError(try TBDHotkey.parse("hyper+x")) { XCTAssertEqual($0 as? TBDHotkey.ParseError, .unknownToken("hyper")) }
        XCTAssertThrowsError(try TBDHotkey.parse("")) { XCTAssertEqual($0 as? TBDHotkey.ParseError, .empty) }
        XCTAssertThrowsError(try TBDHotkey.parse("ctrl+a+b")) { XCTAssertEqual($0 as? TBDHotkey.ParseError, .unknownToken("b")) }
        XCTAssertNil(TBDHotkey.stored(""))
        XCTAssertNil(TBDHotkey.stored("none"))
        XCTAssertNil(TBDHotkey.stored("hyper+x"))
        XCTAssertEqual(TBDHotkey.stored("right_option"), TBDHotkey(modifiers: [.option], side: .right))
    }

    /// v1 allows bare keys with a warning (HotkeyTrigger.validateKeyCode) instead of refusing them.
    func testBareKeysParseAndCarryV1Warnings() throws {
        let d = try TBDHotkey.parse("d")
        XCTAssertEqual(d.kind, .keyCode)
        XCTAssertEqual(d.validation, .warned("May interfere with typing."))
        XCTAssertEqual(try TBDHotkey.parse("space").validation, .warned("May interfere with typing."))
        XCTAssertEqual(try TBDHotkey.parse("up").validation, .warned("May interfere with text editing."))
        XCTAssertEqual(try TBDHotkey.parse("f13").validation, .allowed)
        XCTAssertEqual(try TBDHotkey.parse("end").validation, .allowed)
        XCTAssertEqual(try TBDHotkey.parse("capslock").validation, .allowed)
        XCTAssertEqual(TBDHotkey(modifiers: [], keyCode: 53).validation, .blocked("Escape is reserved for canceling dictation."))
    }

    func testChordValidationMatchesV1() throws {
        XCTAssertEqual(try TBDHotkey.parse("cmd+space").validation, .warned("May not work \u{2014} system shortcut."))
        XCTAssertEqual(try TBDHotkey.parse("cmd+tab").validation, .warned("May not work \u{2014} system shortcut."))
        XCTAssertEqual(try TBDHotkey.parse("cmd+q").validation, .warned("Conflicts with a common system shortcut."))
        XCTAssertEqual(try TBDHotkey.parse("cmd+m").validation, .warned("Conflicts with a common system shortcut."))
        XCTAssertEqual(try TBDHotkey.parse("cmd+shift+m").validation, .allowed)
        XCTAssertEqual(try TBDHotkey.parse("ctrl+opt").validation, .allowed)
        XCTAssertEqual(try TBDHotkey.parse("right_option").validation, .allowed)
    }

    func testKindsSidesAndLabels() throws {
        let chord = try TBDHotkey.parse("left_ctrl+right_opt")
        XCTAssertEqual(chord.kind, .modifierChord)
        XCTAssertEqual(chord.sides, [.control: .left, .option: .right])
        XCTAssertEqual(chord.serialized, "left_ctrl+right_opt")
        XCTAssertEqual(chord.modifierChordKeyCodes, [59, 61])
        XCTAssertEqual(chord.shortSymbol, "L⌃R⌥")
        XCTAssertEqual(chord.longName, "Left Control+Right Option")
        // Sides only exist for modifier-only hotkeys (v1 chords have none).
        XCTAssertEqual(try TBDHotkey.parse("right_cmd+d").sides, [:])
        XCTAssertEqual(TBDHotkey.fn.formattedLabel, "🌐 Fn")
        XCTAssertEqual(try TBDHotkey.parse("right_option").formattedLabel, "R⌥ Right Option")
        XCTAssertEqual(try TBDHotkey.parse("cmd+shift+m").formattedLabel, "⇧⌘M")
        XCTAssertEqual(try TBDHotkey.parse("fn+space").shortSymbol, "fn+Space")
        XCTAssertEqual(try TBDHotkey.parse("end").longName, "End")
        XCTAssertEqual(try TBDHotkey.parse("pagedown").shortSymbol, "PgDn")
        XCTAssertEqual(try TBDHotkey.parse("right").serialized, "right")
        XCTAssertEqual(try TBDHotkey.parse("right").keyCode, 124)
    }

    func testOverlapAndConflictRulesMatchV1() throws {
        let fn = TBDHotkey.fn
        let option = try TBDHotkey.parse("option")
        let rightOption = try TBDHotkey.parse("right_option")
        let leftOption = try TBDHotkey.parse("left_option")
        let optSpace = try TBDHotkey.parse("opt+space")
        let fnSpace = try TBDHotkey.parse("fn+space")
        XCTAssertTrue(option.overlaps(with: rightOption))
        XCTAssertFalse(leftOption.overlaps(with: rightOption))
        // A bare Fn has no modifier requirement, so it never overlaps an Fn chord (v1 rule).
        XCTAssertFalse(fn.overlaps(with: fnSpace))
        XCTAssertTrue(rightOption.overlaps(with: optSpace))
        XCTAssertTrue(rightOption.conflicts(with: optSpace))
        // A bare-modifier dictation key may share its modifier with a chord.
        XCTAssertFalse(rightOption.conflicts(with: optSpace, selfMode: .bareModifierDictation))
        XCTAssertFalse(optSpace.conflicts(with: rightOption, otherMode: .bareModifierDictation))
        XCTAssertTrue(try TBDHotkey.parse("ctrl+opt").overlaps(with: try TBDHotkey.parse("ctrl+opt+shift")))
        XCTAssertTrue(try TBDHotkey.parse("f13").overlaps(with: try TBDHotkey.parse("cmd+f13")))
        XCTAssertFalse(try TBDHotkey.parse("cmd+d").overlaps(with: try TBDHotkey.parse("ctrl+d")))
        XCTAssertTrue(try TBDHotkey.parse("cmd+d").overlaps(with: try TBDHotkey.parse("cmd+shift+d")))
    }
}
