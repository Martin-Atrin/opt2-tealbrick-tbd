import Foundation

/// One keyboard event from the global event tap, reduced to what hotkey matching needs.
/// `flags` is the raw CGEventFlags value (device-dependent left/right bits included).
public enum TBDKeyEvent: Equatable, Sendable {
    case flagsChanged(keyCode: UInt16, flags: UInt64, timestampMs: UInt64)
    case keyDown(keyCode: UInt16, flags: UInt64, timestampMs: UInt64)
    case keyUp(keyCode: UInt16, flags: UInt64, timestampMs: UInt64)
}

/// Left/right modifier detection on raw flags. Ported from v1 `MacParakeet/Hotkey/ModifierKeyMatcher.swift`.
public enum TBDModifierMatch {
    static func sidePressed(_ flags: UInt64, _ keyCode: UInt16) -> Bool {
        guard let mask = TBDHotkey.deviceMasks[keyCode] else { return false }
        return flags & mask != 0
    }

    /// Either side's device bit is present, so the flags can prove which side is down.
    private static func sideBitsPresent(_ flags: UInt64, _ keyCode: UInt16) -> Bool {
        guard let opposite = TBDHotkey.oppositeKeyCodes[keyCode], let mask = TBDHotkey.deviceMasks[keyCode],
              let oppositeMask = TBDHotkey.deviceMasks[opposite] else { return false }
        return flags & (mask | oppositeMask) != 0
    }

    static func sidePressed(_ flags: UInt64, _ keyCode: UInt16, changedKeyCode: UInt16?, previouslyPressed: Bool) -> Bool {
        guard let changedKeyCode else { return sidePressed(flags, keyCode) }
        if sideBitsPresent(flags, keyCode) { return sidePressed(flags, keyCode) }
        guard changedKeyCode == keyCode, let modifier = TBDHotkey.modifier(forKeyCode: keyCode) else { return previouslyPressed }
        return flags & modifier.flag != 0
    }

    static func oppositeSidePressed(_ flags: UInt64, _ keyCode: UInt16, changedKeyCode: UInt16?) -> Bool {
        guard let opposite = TBDHotkey.oppositeKeyCodes[keyCode] else { return false }
        guard let changedKeyCode else { return sidePressed(flags, opposite) }
        if sideBitsPresent(flags, keyCode) { return sidePressed(flags, opposite) }
        // Without device bits the event only proves which physical modifier changed.
        guard changedKeyCode == opposite, let modifier = TBDHotkey.modifier(forKeyCode: opposite) else { return false }
        return flags & modifier.flag != 0
    }

    static func changedTrackedModifierKeyCodes(from previous: UInt64, to current: UInt64, changedKeyCode: UInt16?) -> Set<UInt16> {
        var changed: Set<UInt16> = []
        for keyCode in TBDHotkey.sideSpecificModifierKeyCodes where sidePressed(previous, keyCode) != sidePressed(current, keyCode) {
            changed.insert(keyCode)
        }
        let fnFlag = TBDHotkey.Modifier.fn.flag
        if previous & fnFlag != current & fnFlag { changed.insert(63) }
        if let changedKeyCode {
            if TBDHotkey.fnKeyCodes.contains(changedKeyCode) { changed.insert(63) }
            else if TBDHotkey.deviceMasks[changedKeyCode] != nil { changed.insert(changedKeyCode) }
        }
        return changed
    }

    static let trackedFlags: UInt64 = TBDHotkey.relevantFlags

    /// All modifiers of a modifier chord are down, sides included (extra modifiers allowed).
    public static func modifierChordRequiredPressed(_ hotkey: TBDHotkey, flags: UInt64) -> Bool {
        guard hotkey.kind == .modifierChord, hotkey.modifiers.count >= 2 else { return false }
        let required = hotkey.requiredFlags
        guard flags & required == required else { return false }
        return hotkey.modifierChordKeyCodes.allSatisfy { sidePressed(flags, $0) }
    }

    /// Exactly the chord: no extra modifiers and not the other side of a side-specific component.
    public static func modifierChordMatches(_ hotkey: TBDHotkey, flags: UInt64) -> Bool {
        guard modifierChordRequiredPressed(hotkey, flags: flags), flags & TBDHotkey.relevantFlags == hotkey.requiredFlags else { return false }
        let required = Set(hotkey.modifierChordKeyCodes)
        for keyCode in required {
            guard let opposite = TBDHotkey.oppositeKeyCodes[keyCode], !required.contains(opposite) else { continue }
            if sidePressed(flags, opposite) { return false }
        }
        return true
    }
}

/// Event matching for one dictation hotkey: turns key events into gesture outputs and decides whether
/// to swallow the event. Ported from v1 `MacParakeet/Hotkey/HotkeyManager.swift` (modifier, key, chord
/// and modifier-chord paths). Timers, the stop tail and the take itself belong to the coordinator.
public struct TBDDictationHotkeyMatcher {
    public typealias Output = TBDHotkeyGestureController.Output

    public let hotkey: TBDHotkey
    public private(set) var gesture: TBDHotkeyGestureController
    /// Take this hotkey currently controls (v1 `activeRecordingMode`).
    public private(set) var activeRecordingMode: TBDFnKeyStateMachine.RecordingMode?
    /// Physical key state (`CGEventSource.keyState`); a seam so tests need no keyboard.
    var physicalKeyState: (UInt16) -> Bool

    private var previousFlags: UInt64 = 0
    private var targetModifierWasPressed = false
    private var targetModifierGestureIsActive = false
    private var bareTap = true
    private var triggerKeyIsPressed = false
    private var chordModifierReleased = false
    private var modifierChordRequiredWasPressed = false
    private var modifierChordGestureIsActive = false
    private var modifierChordBlockedUntilRelease = false
    private var pressedNonFnKeyCodes: Set<UInt16> = []

    /// The "Escape cancels dictation" setting, read at each Escape press.
    public var escapeCancels: () -> Bool = { true }

    public init(hotkey: TBDHotkey, gesture: TBDHotkeyGestureController, physicalKeyState: @escaping (UInt16) -> Bool = { _ in false }) {
        self.hotkey = hotkey
        self.gesture = gesture
        self.physicalKeyState = physicalKeyState
    }

    public var mode: TBDHotkeyGestureController.Mode { gesture.mode }
    private var isSingleTap: Bool { gesture.mode == .singleTapToggle }
    private var isBareFn: Bool { hotkey == .fn }

    /// v1: the built-in bare Fn gesture only observes events; every other trigger may swallow its key.
    public var needsActiveTap: Bool { !isBareFn }

    public mutating func handle(_ event: TBDKeyEvent) -> (outputs: [Output], swallow: Bool) {
        let result: (outputs: [Output], swallow: Bool)
        switch hotkey.kind {
        case .modifier: result = (modifierPath(event), false)
        case .keyCode: result = keyCodePath(event)
        case .chord: result = chordPath(event)
        case .modifierChord: result = (modifierChordPath(event), false)
        }
        remember(result.outputs)
        return result
    }

    public mutating func startupDebounceElapsed() -> [Output] { remembered(gesture.startupDebounceElapsed()) }
    public mutating func holdWindowElapsed() -> [Output] { remembered(gesture.holdWindowElapsed()) }

    public mutating func suppressUntilReset() { gesture.suppressUntilReset(); activeRecordingMode = nil }
    public mutating func notifyCancelledByUI() { gesture.notifyCancelledByUI(); activeRecordingMode = nil }
    public mutating func resumeRecording(mode: TBDFnKeyStateMachine.RecordingMode) { gesture.resumeRecording(mode: mode); activeRecordingMode = mode }

    /// v1 `syncRecordingMode`: keep controlling a take this gesture mode can stop, else stand down.
    public mutating func syncRecordingMode(_ mode: TBDFnKeyStateMachine.RecordingMode) {
        if let resume = TBDHotkeyGestureController.resumeMode(mode, for: gesture.mode) { resumeRecording(mode: resume) } else { suppressUntilReset() }
    }

    /// Back to idle; `flags` (current modifier state) re-syncs which keys are still held.
    public mutating func resetToIdle(flags: UInt64 = 0) {
        triggerKeyIsPressed = false
        chordModifierReleased = false
        targetModifierGestureIsActive = false
        modifierChordGestureIsActive = false
        modifierChordBlockedUntilRelease = false
        activeRecordingMode = nil
        bareTap = true
        gesture.reset()
        reconcilePassiveFnKeyState()
        if hotkey.kind == .modifier {
            if let sideCode = sideSpecificCode {
                targetModifierWasPressed = TBDModifierMatch.sidePressed(flags, sideCode)
            } else {
                targetModifierWasPressed = flags & targetMask != 0
            }
            previousFlags = flags
        }
        if hotkey.kind == .modifierChord {
            modifierChordRequiredWasPressed = TBDModifierMatch.modifierChordRequiredPressed(hotkey, flags: flags)
            modifierChordBlockedUntilRelease = modifierChordRequiredWasPressed && !TBDModifierMatch.modifierChordMatches(hotkey, flags: flags)
        }
    }

    private mutating func remembered(_ outputs: [Output]) -> [Output] { remember(outputs); return outputs }

    private mutating func remember(_ outputs: [Output]) {
        for output in outputs {
            switch output {
            case .startRecording(let mode): activeRecordingMode = mode
            case .stopRecording, .cancelRecording, .discardRecording: activeRecordingMode = nil
            default: break
            }
        }
    }

    // MARK: Modifier path

    private var sideSpecificCode: UInt16? { hotkey.side != nil ? hotkey.modifierKeyCode : nil }
    private var targetMask: UInt64 { hotkey.modifiers.first?.flag ?? 0 }

    private mutating func modifierPath(_ event: TBDKeyEvent) -> [Output] {
        switch event {
        case let .flagsChanged(keyCode, flags, timestamp):
            let outputs = modifierFlagsChanged(flags: flags, timestamp: timestamp, changedKeyCode: keyCode)
            previousFlags = flags
            return outputs
        case let .keyDown(keyCode, _, _):
            return modifierKeyDown(keyCode)
        case let .keyUp(keyCode, _, _):
            return modifierKeyUp(keyCode)
        }
    }

    private mutating func released(timestamp: UInt64) -> [Output] {
        let outputs: [Output]
        if bareTap {
            // Single-tap keys toggle on release, so the modifier still works in shortcuts.
            outputs = isSingleTap ? gesture.triggerPressed(timestampMs: timestamp) : gesture.triggerReleased(timestampMs: timestamp)
        } else {
            outputs = isSingleTap ? [] : gesture.nonBareTriggerReleased()
        }
        bareTap = true
        return outputs
    }

    private mutating func modifierFlagsChanged(flags: UInt64, timestamp: UInt64, changedKeyCode: UInt16) -> [Output] {
        if let target = sideSpecificCode {
            let wasPressed = targetModifierWasPressed
            let isPressed = TBDModifierMatch.sidePressed(flags, target, changedKeyCode: changedKeyCode, previouslyPressed: wasPressed)
            targetModifierWasPressed = isPressed
            if isPressed != wasPressed {
                if isPressed {
                    guard !TBDModifierMatch.oppositeSidePressed(flags, target, changedKeyCode: changedKeyCode) else { return [] }
                    targetModifierGestureIsActive = true
                    bareTap = true
                    return isSingleTap ? [] : gesture.triggerPressed(timestampMs: timestamp)
                }
                guard targetModifierGestureIsActive else { return [] }
                targetModifierGestureIsActive = false
                return released(timestamp: timestamp)
            }
            let changed = TBDModifierMatch.changedTrackedModifierKeyCodes(from: previousFlags, to: flags, changedKeyCode: changedKeyCode)
                .subtracting([target])
            if targetModifierGestureIsActive, !changed.isEmpty {
                bareTap = false
                return isSingleTap ? [] : gesture.interrupted()
            }
            // While double-tap mode waits for a second tap, an opposite-side tap still cancels it.
            if let opposite = TBDHotkey.oppositeKeyCodes[target], changed.contains(opposite),
               TBDModifierMatch.sidePressed(flags, opposite, changedKeyCode: changedKeyCode, previouslyPressed: false) {
                return isSingleTap ? [] : gesture.interrupted()
            }
            return []
        }

        let isPressed = flags & targetMask != 0
        if isPressed != targetModifierWasPressed {
            targetModifierWasPressed = isPressed
            if isPressed {
                targetModifierGestureIsActive = true
                bareTap = true
                if isBareFn {
                    reconcilePassiveFnKeyState()
                    if passiveFnInputIsContaminated(flags: flags) {
                        targetModifierGestureIsActive = false
                        bareTap = false
                        return interruptPendingPassiveFnWindow()
                    }
                }
                return isSingleTap ? [] : gesture.triggerPressed(timestampMs: timestamp)
            }
            guard targetModifierGestureIsActive else { return [] }
            targetModifierGestureIsActive = false
            return released(timestamp: timestamp)
        }

        // Another modifier changing breaks the "bare modifier" assumption like a keyDown would.
        if isBareFn {
            let changed = TBDModifierMatch.changedTrackedModifierKeyCodes(from: previousFlags, to: flags, changedKeyCode: changedKeyCode)
                .subtracting([63])
            let alphaShift: UInt64 = 0x0001_0000
            let capsLockChanged = changedKeyCode == 57 && (previousFlags & alphaShift) != (flags & alphaShift)
            guard !changed.isEmpty || capsLockChanged else { return [] }
            if targetModifierGestureIsActive {
                bareTap = false
                return isSingleTap ? [] : gesture.interrupted()
            }
            return interruptPendingPassiveFnWindow()
        }
        guard targetModifierGestureIsActive else { return [] }
        guard flags & TBDModifierMatch.trackedFlags & ~targetMask != 0 else { return [] }
        bareTap = false
        return isSingleTap ? [] : gesture.interrupted()
    }

    private static func isTrackableNonFnKeyCode(_ code: UInt16) -> Bool {
        code <= 127 && !TBDHotkey.fnKeyCodes.contains(code) && code != 57
    }

    private mutating func reconcilePassiveFnKeyState() {
        guard isBareFn else { return }
        pressedNonFnKeyCodes = Set((UInt16(0)...127).filter { Self.isTrackableNonFnKeyCode($0) && physicalKeyState($0) })
    }

    private func passiveFnInputIsContaminated(flags: UInt64) -> Bool {
        flags & TBDModifierMatch.trackedFlags & ~targetMask != 0 || !pressedNonFnKeyCodes.isEmpty
    }

    private mutating func interruptPendingPassiveFnWindow() -> [Output] {
        guard activeRecordingMode == nil, gesture.hasPendingTriggerPress else { return [] }
        return gesture.interrupted()
    }

    private mutating func modifierKeyDown(_ code: UInt16) -> [Output] {
        if isBareFn, Self.isTrackableNonFnKeyCode(code) {
            guard pressedNonFnKeyCodes.insert(code).inserted else { return [] }
            if targetModifierGestureIsActive { bareTap = false }
        }
        if code == TBDHotkey.escapeKeyCode { return escapeOutputs() }
        // macOS sends a synthetic keyDown 179 when Fn is released; it must not reset the gesture.
        guard !TBDHotkey.fnKeyCodes.contains(code) else { return [] }
        if targetModifierGestureIsActive { bareTap = false }
        return isSingleTap ? [] : gesture.interrupted()
    }

    private mutating func modifierKeyUp(_ code: UInt16) -> [Output] {
        guard isBareFn, Self.isTrackableNonFnKeyCode(code) else { return [] }
        pressedNonFnKeyCodes.remove(code)
        guard targetModifierGestureIsActive else { return interruptPendingPassiveFnWindow() }
        bareTap = false
        return isSingleTap ? [] : gesture.interrupted()
    }

    /// v1 "Escape cancels dictation": when off, Escape leaves the take and the gesture alone (and keeps its job
    /// in the app being dictated into).
    private mutating func escapeOutputs() -> [Output] { escapeCancels() ? gesture.escapePressed() : [] }

    // MARK: Key path

    private mutating func keyCodePath(_ event: TBDKeyEvent) -> (outputs: [Output], swallow: Bool) {
        guard let trigger = hotkey.keyCode else { return ([], false) }
        switch event {
        case let .keyDown(code, _, timestamp):
            if code == trigger {
                guard !triggerKeyIsPressed else { return ([], true) }   // key repeat
                triggerKeyIsPressed = true
                return (gesture.triggerPressed(timestampMs: timestamp), true)
            }
            if code == TBDHotkey.escapeKeyCode { return (escapeOutputs(), false) }
            return (gesture.interrupted(), false)
        case let .keyUp(code, _, timestamp):
            guard code == trigger else { return ([], false) }
            guard triggerKeyIsPressed else { return ([], true) }
            triggerKeyIsPressed = false
            return (gesture.triggerReleased(timestampMs: timestamp), true)
        case .flagsChanged:
            return ([], false)
        }
    }

    // MARK: Chord path

    private mutating func chordPath(_ event: TBDKeyEvent) -> (outputs: [Output], swallow: Bool) {
        guard let trigger = hotkey.keyCode else { return ([], false) }
        let required = hotkey.requiredFlags
        switch event {
        case let .keyDown(code, rawFlags, timestamp):
            let flags = rawFlags & TBDHotkey.relevantFlags
            if code == trigger {
                guard flags & required == required else { return (gesture.interrupted(), false) }
                guard !triggerKeyIsPressed else { return ([], true) }
                triggerKeyIsPressed = true
                chordModifierReleased = false
                return (gesture.triggerPressed(timestampMs: timestamp), true)
            }
            if code == TBDHotkey.escapeKeyCode { return (escapeOutputs(), false) }
            return (gesture.interrupted(), false)
        case let .keyUp(code, _, timestamp):
            guard code == trigger, triggerKeyIsPressed else { return ([], false) }
            triggerKeyIsPressed = false
            let outputs = chordModifierReleased ? [] : gesture.triggerReleased(timestampMs: timestamp)
            chordModifierReleased = false
            return (outputs, true)
        case let .flagsChanged(_, rawFlags, timestamp):
            // Releasing any required modifier while the key is held ends the gesture.
            if triggerKeyIsPressed, !chordModifierReleased, rawFlags & TBDHotkey.relevantFlags & required != required {
                chordModifierReleased = true
                return (gesture.triggerReleased(timestampMs: timestamp), false)
            }
            return ([], false)
        }
    }

    // MARK: Modifier-chord path

    private mutating func modifierChordPath(_ event: TBDKeyEvent) -> [Output] {
        switch event {
        case let .flagsChanged(_, flags, timestamp):
            let requiredPressed = TBDModifierMatch.modifierChordRequiredPressed(hotkey, flags: flags)
            let exactPressed = TBDModifierMatch.modifierChordMatches(hotkey, flags: flags)
            let wasRequiredPressed = modifierChordRequiredWasPressed
            modifierChordRequiredWasPressed = requiredPressed
            guard requiredPressed else {
                modifierChordBlockedUntilRelease = false
                guard modifierChordGestureIsActive else { bareTap = true; return [] }
                modifierChordGestureIsActive = false
                return released(timestamp: timestamp)
            }
            if !wasRequiredPressed {
                bareTap = true
                modifierChordBlockedUntilRelease = !exactPressed
            }
            if modifierChordGestureIsActive, !exactPressed {
                modifierChordBlockedUntilRelease = true
                guard bareTap else { return [] }
                bareTap = false
                return isSingleTap ? [] : gesture.interrupted()
            }
            if exactPressed, !modifierChordGestureIsActive {
                guard !modifierChordBlockedUntilRelease else { return [] }
                modifierChordGestureIsActive = true
                bareTap = true
                return isSingleTap ? [] : gesture.triggerPressed(timestampMs: timestamp)
            }
            return []
        case let .keyDown(code, _, _):
            if code == TBDHotkey.escapeKeyCode { return escapeOutputs() }
            guard !TBDHotkey.fnKeyCodes.contains(code) else { return [] }
            if modifierChordGestureIsActive { bareTap = false }
            return isSingleTap ? [] : gesture.interrupted()
        case .keyUp:
            return []
        }
    }
}

/// Event matching for an immediate-action hotkey (meeting, file, URL, transform): fires once per press.
/// Ported from v1 `MacParakeet/Hotkey/GlobalShortcutManager.swift`.
public struct TBDShortcutMatcher {
    public let hotkey: TBDHotkey
    private var targetModifierWasPressed = false
    private var triggerKeyIsPressed = false
    private var modifierChordRequiredWasPressed = false
    private var modifierChordTriggeredDuringPress = false
    private var modifierChordBlockedUntilRelease = false

    public init(hotkey: TBDHotkey) { self.hotkey = hotkey }

    /// Returns whether the action fires and whether the event is swallowed.
    public mutating func handle(_ event: TBDKeyEvent) -> (fired: Bool, swallow: Bool) {
        switch hotkey.kind {
        case .modifier:
            guard case let .flagsChanged(code, flags, _) = event else { return (false, false) }
            return (modifierFlagsChanged(flags: flags, changedKeyCode: code), false)
        case .modifierChord:
            guard case let .flagsChanged(_, flags, _) = event else { return (false, false) }
            return (modifierChordFlagsChanged(flags: flags), false)
        case .keyCode:
            guard let trigger = hotkey.keyCode else { return (false, false) }
            switch event {
            case let .keyDown(code, _, _):
                guard code == trigger else { return (false, false) }
                guard !triggerKeyIsPressed else { return (false, true) }
                triggerKeyIsPressed = true
                return (true, true)
            case let .keyUp(code, _, _):
                guard code == trigger else { return (false, false) }
                triggerKeyIsPressed = false
                return (false, true)
            case .flagsChanged:
                return (false, false)
            }
        case .chord:
            guard let trigger = hotkey.keyCode else { return (false, false) }
            switch event {
            case let .keyDown(code, rawFlags, _):
                guard code == trigger, rawFlags & TBDHotkey.relevantFlags & ~hotkey.ignoredChordFlags == hotkey.requiredFlags else { return (false, false) }
                guard !triggerKeyIsPressed else { return (false, true) }
                triggerKeyIsPressed = true
                return (true, true)
            case let .keyUp(code, _, _):
                guard code == trigger, triggerKeyIsPressed else { return (false, false) }
                triggerKeyIsPressed = false
                return (false, true)
            case .flagsChanged:
                return (false, false)
            }
        }
    }

    private mutating func modifierFlagsChanged(flags: UInt64, changedKeyCode: UInt16) -> Bool {
        if hotkey.side != nil, let target = hotkey.modifierKeyCode {
            let isPressed = TBDModifierMatch.sidePressed(flags, target, changedKeyCode: changedKeyCode, previouslyPressed: targetModifierWasPressed)
            let oppositePressed = TBDModifierMatch.oppositeSidePressed(flags, target, changedKeyCode: changedKeyCode)
            guard isPressed else { targetModifierWasPressed = false; return false }
            guard !targetModifierWasPressed else { return false }
            targetModifierWasPressed = true
            return !oppositePressed
        }
        let isPressed = flags & (hotkey.modifiers.first?.flag ?? 0) != 0
        guard isPressed != targetModifierWasPressed else { return false }
        targetModifierWasPressed = isPressed
        return isPressed
    }

    private mutating func modifierChordFlagsChanged(flags: UInt64) -> Bool {
        let requiredPressed = TBDModifierMatch.modifierChordRequiredPressed(hotkey, flags: flags)
        let exactPressed = TBDModifierMatch.modifierChordMatches(hotkey, flags: flags)
        guard requiredPressed else {
            modifierChordRequiredWasPressed = false
            modifierChordTriggeredDuringPress = false
            modifierChordBlockedUntilRelease = false
            return false
        }
        if !modifierChordRequiredWasPressed {
            modifierChordRequiredWasPressed = true
            modifierChordTriggeredDuringPress = false
            modifierChordBlockedUntilRelease = !exactPressed
        }
        guard exactPressed, !modifierChordBlockedUntilRelease, !modifierChordTriggeredDuringPress else { return false }
        modifierChordTriggeredDuringPress = true
        return true
    }
}
