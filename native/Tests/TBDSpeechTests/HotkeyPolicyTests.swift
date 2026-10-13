import XCTest
@testable import TBDSpeech

/// v1 conflict policy, dictation hotkey plan, press-to-record recorder and the one-time migration.
final class HotkeyPolicyTests: XCTestCase {
    func key(_ text: String) -> TBDHotkey { try! TBDHotkey.parse(text) }

    func snapshot(handsFree: String? = "fn", pushToTalk: String? = "fn", meeting: String? = "cmd+shift+m", file: String? = nil,
                  url: String? = nil, aiPolish: String? = nil, clipboard: String? = nil, transform: String? = nil) -> TBDHotkeyConflictPolicy.Snapshot {
        TBDHotkeyConflictPolicy.Snapshot(handsFree: handsFree.map(key), pushToTalk: pushToTalk.map(key), meeting: meeting.map(key),
                                         fileTranscription: file.map(key), urlTranscription: url.map(key), dictationAIPolish: aiPolish.map(key),
                                         dictationClipboard: clipboard.map(key), transforms: [.init(name: "Transform Fix grammar", hotkey: transform.map(key))])
    }

    // MARK: Conflicts

    func testRecorderConflictMessagesAreExact() {
        let s = snapshot(file: "f13", url: "f14", clipboard: "f15")
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("f13"), surface: .dictationClipboard, snapshot: s),
                       .blocked("Conflicts with file transcription (F13)."))
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("cmd+shift+m"), surface: .urlTranscription, snapshot: s),
                       .blocked("Conflicts with meeting recording (⇧⌘M)."))
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("f15"), surface: .dictationAIPolish, snapshot: s),
                       .blocked("Conflicts with clipboard-only dictation (F15)."))
        // A bare Fn cannot be shared, even with a bare-modifier dictation key.
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("fn"), surface: .meeting, snapshot: s),
                       .blocked("Conflicts with hands-free mode (🌐 Fn)."))
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("f16"), surface: .meeting, snapshot: s), .allowed)
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: nil, surface: .meeting, snapshot: s), .allowed)
    }

    func testHandsFreeAndPushToTalkMayShareOneKeyButNotOverlap() {
        let s = snapshot(handsFree: "fn", pushToTalk: "right_option")
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("right_option"), surface: .handsFree, snapshot: s), .allowed)
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("option"), surface: .handsFree, snapshot: s),
                       .blocked("Conflicts with push to talk (R⌥ Right Option)."))
        // Dedicated keys can never share a trigger with a dictation key.
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("right_option"), surface: .dictationClipboard, snapshot: s),
                       .blocked("Conflicts with push to talk (R⌥ Right Option)."))
        // A bare-modifier dictation key may share its modifier with a chord elsewhere.
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("opt+space"), surface: .meeting, snapshot: s), .allowed)
    }

    func testSavedConflictMessageSaysDisabledExceptHandsFreeAgainstPushToTalk() {
        let s = snapshot(handsFree: "option", pushToTalk: "right_option", file: "f13", clipboard: "f13")
        XCTAssertEqual(TBDHotkeyConflictPolicy.conflictMessage(for: key("option"), surface: .handsFree, snapshot: s),
                       "Conflicts with push to talk (R⌥ Right Option).")
        XCTAssertEqual(TBDHotkeyConflictPolicy.conflictMessage(for: key("f13"), surface: .dictationClipboard, snapshot: s),
                       "Disabled — conflicts with file transcription (F13).")
        XCTAssertNil(TBDHotkeyConflictPolicy.conflictMessage(for: nil, surface: .dictationClipboard, snapshot: s))
    }

    func testTransformHotkeyRulesMatchV1() {
        let s = snapshot(file: "ctrl+opt+f")
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("f18"), surface: .transform, snapshot: s),
                       .blocked("Shortcut must include a modifier key (\u{2303}, \u{2325}, \u{21E7}, or \u{2318})."))
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("opt+e"), surface: .transform, snapshot: s),
                       .blocked("This shortcut produces a special character on Mac. Pick another combo."))
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("ctrl+opt+f"), surface: .transform, snapshot: s),
                       .blocked("This shortcut conflicts with file transcription."))
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("ctrl+opt+t"), surface: .transform, snapshot: s), .allowed)
        // Other hotkeys see the transform hotkey by its v1 name.
        let withTransform = snapshot(transform: "ctrl+opt+t")
        XCTAssertEqual(TBDHotkeyConflictPolicy.validation(candidate: key("ctrl+opt+t"), surface: .fileTranscription, snapshot: withTransform),
                       .blocked("Conflicts with Transform Fix grammar (⌃⌥T)."))
    }

    // MARK: Dictation plan

    func testSharedKeyPlanIsDoubleTapAndHoldWithStopTail() {
        let plan = TBDDictationHotkeyPlan.make(handsFree: .fn, pushToTalk: .fn)
        XCTAssertEqual(plan.specs, [.init(hotkey: .fn, gestureMode: .doubleTapAndHold, holdToTalkStopTailMs: 200)])
        XCTAssertNil(plan.conflict)
        XCTAssertEqual(TBDDictationHotkeyPlan.menuTitle(handsFree: .fn, pushToTalk: .fn), "Dictation: Hold Fn / Double-tap Fn")
    }

    func testSeparateKeysPlanAndExtraKeys() {
        let plan = TBDDictationHotkeyPlan.make(handsFree: key("right_cmd"), pushToTalk: key("right_option"), aiPolish: key("f16"), clipboard: key("f15"))
        XCTAssertEqual(plan.specs, [
            .init(hotkey: key("right_cmd"), gestureMode: .singleTapToggle),
            .init(hotkey: key("right_option"), gestureMode: .holdOnly, holdToTalkStopTailMs: 200),
            .init(hotkey: key("f15"), gestureMode: .singleTapToggle, clipboardOnly: true),
            .init(hotkey: key("f16"), gestureMode: .singleTapToggle, aiPolish: true),
        ])
        XCTAssertEqual(TBDDictationHotkeyPlan.menuTitle(handsFree: key("right_cmd"), pushToTalk: key("right_option")),
                       "Dictation: Hold Right Option / Tap Right Command")
    }

    func testOverlappingKeysKeepHandsFreeAndReportPushToTalk() {
        let plan = TBDDictationHotkeyPlan.make(handsFree: key("option"), pushToTalk: key("right_option"), clipboard: key("option"))
        XCTAssertEqual(plan.specs, [.init(hotkey: key("option"), gestureMode: .singleTapToggle)])
        XCTAssertEqual(plan.conflict, .init(hotkey: key("right_option"), conflicts: [key("option")]))
    }

    func testFnPushToTalkNextToFnChordWaitsTheTapThreshold() {
        let plan = TBDDictationHotkeyPlan.make(handsFree: key("fn+space"), pushToTalk: .fn)
        XCTAssertEqual(plan.specs.map(\.startupDebounceMs), [100, 400])
    }

    func testLabelOverridesForSharedKey() {
        XCTAssertEqual(TBDDictationHotkeyPlan.handsFreeLabelOverride(handsFree: .fn, pushToTalk: .fn), "Double-tap Fn")
        XCTAssertNil(TBDDictationHotkeyPlan.pushToTalkLabelOverride(pushToTalk: .fn, handsFree: .fn))
        XCTAssertEqual(TBDDictationHotkeyPlan.pushToTalkLabelOverride(pushToTalk: key("right_option"), handsFree: key("right_option")), "Hold R⌥")
        XCTAssertNil(TBDDictationHotkeyPlan.handsFreeLabelOverride(handsFree: .fn, pushToTalk: key("right_option")))
    }

    // MARK: Recorder

    let cmd: UInt64 = 0x10_0000, shift: UInt64 = 0x2_0000, option: UInt64 = 0x8_0000, control: UInt64 = 0x4_0000, fnFlag: UInt64 = 0x80_0000

    func testRecorderKeyEventsGiveExactChord() {
        var recorder = TBDHotkeyRecorder()
        XCTAssertEqual(recorder.flagsChanged(keyCode: 55, flags: cmd | 0x08), .recording)
        XCTAssertEqual(recorder.pendingLabel, "L⌘...")
        XCTAssertEqual(recorder.flagsChanged(keyCode: 56, flags: cmd | shift | 0x0A), .recording)
        let result = recorder.keyDown(keyCode: 46, flags: cmd | shift | 0x0A)
        XCTAssertEqual(result, .accepted(key("cmd+shift+m"), warning: nil))
        if case .accepted(let hotkey, _) = result {
            XCTAssertEqual(hotkey.serialized, "shift+cmd+m")
            XCTAssertEqual(hotkey.formattedLabel, "⇧⌘M")
        }
        XCTAssertFalse(recorder.isRecording)
    }

    func testRecorderEscapeCancels() {
        var recorder = TBDHotkeyRecorder()
        XCTAssertEqual(recorder.keyDown(keyCode: 53, flags: 0), .cancelled)
        XCTAssertFalse(recorder.isRecording)
    }

    func testRecorderBareModifiersAndChords() {
        var right = TBDHotkeyRecorder()
        XCTAssertEqual(right.flagsChanged(keyCode: 61, flags: option | 0x40), .recording)
        XCTAssertEqual(right.flagsChanged(keyCode: 61, flags: 0), .accepted(key("right_option"), warning: nil))

        var either = TBDHotkeyRecorder(mode: .generic)
        _ = either.flagsChanged(keyCode: 61, flags: option | 0x40)
        XCTAssertEqual(either.flagsChanged(keyCode: 61, flags: 0), .accepted(key("option"), warning: nil))

        var chord = TBDHotkeyRecorder(mode: .sideSpecific)
        _ = chord.flagsChanged(keyCode: 59, flags: control | 0x01)
        _ = chord.flagsChanged(keyCode: 61, flags: control | option | 0x41)
        XCTAssertEqual(chord.pendingLabel, "L⌃R⌥...")
        _ = chord.flagsChanged(keyCode: 61, flags: control | 0x01)
        XCTAssertEqual(chord.flagsChanged(keyCode: 59, flags: 0), .accepted(key("left_ctrl+right_opt"), warning: nil))

        var fn = TBDHotkeyRecorder()
        XCTAssertEqual(fn.flagsChanged(keyCode: 63, flags: fnFlag), .recording)
        XCTAssertEqual(fn.pendingLabel, "fn...")
        XCTAssertEqual(fn.flagsChanged(keyCode: 63, flags: 0), .accepted(.fn, warning: nil))
    }

    func testRecorderBareKeysAndFunctionKeyFnFlag() {
        var letter = TBDHotkeyRecorder()
        XCTAssertEqual(letter.keyDown(keyCode: 2, flags: 0), .accepted(key("d"), warning: "May interfere with typing."))
        // F19 carries the Fn flag without Fn held: it records as bare F19, not fn+F19.
        var f19 = TBDHotkeyRecorder()
        XCTAssertEqual(f19.keyDown(keyCode: 80, flags: fnFlag), .accepted(key("f19"), warning: nil))
        // A held Fn plus a letter is a real Fn chord.
        var fnD = TBDHotkeyRecorder()
        _ = fnD.flagsChanged(keyCode: 63, flags: fnFlag)
        XCTAssertEqual(fnD.keyDown(keyCode: 2, flags: fnFlag), .accepted(key("fn+d"), warning: nil))
    }

    func testRecorderConflictBlocksAndKeepsRecording() {
        let s = snapshot(file: "f13")
        var recorder = TBDHotkeyRecorder { TBDHotkeyConflictPolicy.validation(candidate: $0, surface: .urlTranscription, snapshot: s) }
        XCTAssertEqual(recorder.keyDown(keyCode: 105, flags: 0), .blocked("Conflicts with file transcription (F13)."))
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(recorder.keyDown(keyCode: 107, flags: 0), .accepted(key("f14"), warning: nil))
    }

    func testRecorderSideSpecificRefusesKeyChords() {
        var recorder = TBDHotkeyRecorder(mode: .sideSpecific)
        XCTAssertEqual(recorder.keyDown(keyCode: 2, flags: cmd | 0x08), .stopped(TBDHotkeyRecorder.sideSpecificKeyChordMessage))
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: Preferences and migration

    func withDefaults(_ body: (UserDefaults, TBDListeningPreferences) throws -> Void) throws {
        let suite = "tbd.tests.hotkeys.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, TBDListeningPreferences(defaults: defaults))
    }

    func testDefaultsMatchV1() throws {
        try withDefaults { _, prefs in
            XCTAssertEqual(prefs.hotkey(for: .handsFree), .fn)
            XCTAssertEqual(prefs.hotkey(for: .pushToTalk), .fn)
            XCTAssertEqual(prefs.hotkey(for: .meeting), key("cmd+shift+m"))
            for surface in [TBDHotkeySurface.fileTranscription, .urlTranscription, .dictationAIPolish, .dictationClipboard, .transform] {
                XCTAssertNil(prefs.hotkey(for: surface), "\(surface)")
            }
        }
    }

    func testStoredKeysAndDisabledValue() throws {
        try withDefaults { defaults, prefs in
            prefs.setHotkey(key("f13"), for: .fileTranscription)
            prefs.setHotkey(nil, for: .meeting)
            XCTAssertEqual(defaults.string(forKey: "tbd.listening.fileTranscriptionHotkeyTrigger"), "f13")
            XCTAssertEqual(defaults.string(forKey: "tbd.listening.meetingHotkeyTrigger"), "")
            XCTAssertNil(prefs.hotkey(for: .meeting))
            prefs.setHotkey(key("ctrl+opt+t"), for: .transform)
            XCTAssertEqual(prefs.transformHotkey, "ctrl+opt+t")
        }
    }

    func testMigrationMovesTheSingleHotkeyIntoBothKeysOnce() throws {
        try withDefaults { defaults, prefs in
            defaults.set("right_option", forKey: "tbd.listening.dictationHotkey")
            prefs.migrateDictationHotkeys()
            XCTAssertEqual(defaults.string(forKey: "tbd.listening.hotkeyTrigger"), "right_option")
            XCTAssertEqual(defaults.string(forKey: "tbd.listening.pushToTalkHotkeyTrigger"), "right_option")
            XCTAssertEqual(TBDDictationHotkeyPlan.make(handsFree: prefs.hotkey(for: .handsFree), pushToTalk: prefs.hotkey(for: .pushToTalk)).specs,
                           [.init(hotkey: key("right_option"), gestureMode: .doubleTapAndHold, holdToTalkStopTailMs: 200)])
            // Once: a later change is not overwritten by the old key.
            prefs.setHotkey(key("f13"), for: .pushToTalk)
            prefs.migrateDictationHotkeys()
            XCTAssertEqual(defaults.string(forKey: "tbd.listening.pushToTalkHotkeyTrigger"), "f13")
            XCTAssertEqual(defaults.string(forKey: "tbd.listening.hotkeyTrigger"), "right_option")
        }
    }

    func testMigrationOfAnInvalidOldHotkeyKeepsDictationOff() throws {
        try withDefaults { defaults, prefs in
            defaults.set("hyper+x", forKey: "tbd.listening.dictationHotkey")
            prefs.migrateDictationHotkeys()
            XCTAssertEqual(defaults.string(forKey: "tbd.listening.hotkeyTrigger"), "")
            XCTAssertEqual(defaults.string(forKey: "tbd.listening.pushToTalkHotkeyTrigger"), "")
            XCTAssertNil(prefs.hotkey(for: .handsFree))
        }
    }

    func testMigrationWithoutAnOldHotkeyWritesV1Defaults() throws {
        try withDefaults { defaults, prefs in
            prefs.migrateDictationHotkeys()
            XCTAssertEqual(defaults.string(forKey: "tbd.listening.hotkeyTrigger"), "fn")
            XCTAssertEqual(defaults.string(forKey: "tbd.listening.pushToTalkHotkeyTrigger"), "fn")
        }
    }

    func testStoredValueRepairMatchesV1() {
        typealias P = TBDDictationHotkeyPlan
        let fnSpace = key("fn+space")
        var r = P.resolveStored(handsFree: .some(fnSpace), pushToTalk: nil)
        XCTAssertTrue(r == (.fn, .fn, true, true))
        r = P.resolveStored(handsFree: .some(key("option")), pushToTalk: .some(key("right_option")))
        XCTAssertTrue(r == (.fn, key("right_option"), true, false))
        r = P.resolveStored(handsFree: .some(nil), pushToTalk: nil)
        XCTAssertTrue(r == (nil, nil, false, true))
        r = P.resolveStored(handsFree: .some(key("f13")), pushToTalk: .some(key("f14")))
        XCTAssertTrue(r == (key("f13"), key("f14"), false, false))
    }

    func testCLIDictationHotkeySetsTheSharedKey() throws {
        try withDefaults { _, prefs in
            try prefs.setConfig("dictationHotkey", to: "right_cmd")
            XCTAssertEqual(prefs.hotkey(for: .pushToTalk), key("right_cmd"))
            XCTAssertEqual(prefs.hotkey(for: .handsFree), key("right_cmd"))
            XCTAssertEqual(try prefs.configValue("dictationHotkey"), .string("right_command"))
            XCTAssertThrowsError(try prefs.setConfig("dictationHotkey", to: "hyper"))
        }
    }
}
