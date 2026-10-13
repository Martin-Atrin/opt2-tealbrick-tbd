import Foundation

/// Press-to-record capture for a hotkey row: feed it the key events seen while recording and it
/// returns the recorded hotkey, a blocking message, or a cancel. Pure, so the exact key-to-hotkey rules
/// are testable. Ported from the event logic of v1 `MacParakeet/Views/Settings/HotkeyRecorderView.swift`.
///
/// `flags` are raw modifier flags (NSEvent `modifierFlags.rawValue`), device left/right bits included.
public struct TBDHotkeyRecorder {
    public enum CaptureMode: Sendable {
        /// Keys, chords, and modifiers with the side that was pressed.
        case standard
        /// "Record Either-Side Modifier".
        case generic
        /// "Record Specific-Side Modifier Chord" (modifier-only).
        case sideSpecific
    }

    public enum Result: Equatable, Sendable {
        /// Still recording.
        case recording
        /// Recorded; the warning (if any) is shown under the row.
        case accepted(TBDHotkey, warning: String?)
        /// Refused; recording continues so the person can try another key.
        case blocked(String)
        /// Refused and recording stopped.
        case stopped(String)
        /// Escape: recording stopped, nothing changed.
        case cancelled
    }

    struct Component: Hashable {
        let modifier: TBDHotkey.Modifier
        let side: TBDHotkey.Side?
    }

    public static let sideSpecificKeyChordMessage =
        "Specific-side recording only supports modifier-only shortcuts. Use Change... for modifier+key shortcuts."

    public let mode: CaptureMode
    public private(set) var isRecording = true
    private let additionalValidation: (TBDHotkey) -> TBDHotkey.Validation
    private var pending: [Component] = []
    private var candidate: [Component] = []

    public init(mode: CaptureMode = .standard, additionalValidation: @escaping (TBDHotkey) -> TBDHotkey.Validation = { _ in .allowed }) {
        self.mode = mode
        self.additionalValidation = additionalValidation
    }

    /// Held modifiers while recording, for example "⌃⌥..." (nil when none are held).
    public var pendingLabel: String? {
        guard !pending.isEmpty else { return nil }
        let symbols: String
        if pending.map(\.modifier) == [.fn] {
            symbols = "fn"
        } else if mode == .generic {
            let names = Set(pending.map(\.modifier))
            symbols = TBDHotkey.Modifier.allCases.filter(names.contains).map(\.shortSymbol).joined(separator: names.contains(.fn) ? "+" : "")
        } else {
            symbols = Self.hotkey(from: Self.normalized(pending), keepSides: true)?.shortSymbol ?? ""
        }
        return symbols + "..."
    }

    public mutating func cancel() { stop() }

    public mutating func keyDown(keyCode: UInt16, flags: UInt64) -> Result {
        guard isRecording else { return .cancelled }
        if keyCode == TBDHotkey.escapeKeyCode { stop(); return .cancelled }
        let held = Self.chordModifiers(flags: flags, keyCode: keyCode, pending: pending)
        if held.isEmpty {
            return judge(TBDHotkey(modifiers: [], keyCode: keyCode))
        }
        guard mode != .sideSpecific else { stop(); return .stopped(Self.sideSpecificKeyChordMessage) }
        let result = judge(TBDHotkey(modifiers: Set(held), keyCode: keyCode))
        if case .blocked = result { pending = []; candidate = [] }
        return result
    }

    public mutating func flagsChanged(keyCode: UInt16, flags: UInt64) -> Result {
        guard isRecording, let modifier = TBDHotkey.modifier(forKeyCode: keyCode) else { return .recording }
        if modifier == .fn {
            if flags & TBDHotkey.Modifier.fn.flag != 0 {
                pending = [Component(modifier: .fn, side: nil)]
                candidate = pending
                return .recording
            }
            guard candidate.contains(Component(modifier: .fn, side: nil)) else { return .recording }
            pending = []; candidate = []
            return judge(.fn)
        }
        let held = componentsAfterFlagsChanged(keyCode: keyCode, modifier: modifier, flags: flags)
        guard held.isEmpty else {
            pending = held
            candidate = Self.normalized(candidate + held)
            return .recording
        }
        let released = candidate
        pending = []; candidate = []
        if let chord = modifierChord(from: released) { return judge(chord) }
        switch mode {
        case .generic: return judge(TBDHotkey(modifiers: [modifier]))
        case .standard, .sideSpecific: return judge(TBDHotkey(modifiers: [modifier], side: TBDHotkey.side(forKeyCode: keyCode)))
        }
    }

    /// v1 `combinedValidation`: built-in rules first, then conflicts with other TBD hotkeys.
    public func validate(_ hotkey: TBDHotkey) -> TBDHotkey.Validation {
        Self.combine(hotkey.validation, additionalValidation(hotkey))
    }

    public static func combine(_ primary: TBDHotkey.Validation, _ secondary: TBDHotkey.Validation) -> TBDHotkey.Validation {
        switch (primary, secondary) {
        case (.blocked(let message), _), (_, .blocked(let message)): return .blocked(message)
        case (.warned(let message), _), (_, .warned(let message)): return .warned(message)
        default: return .allowed
        }
    }

    private mutating func judge(_ hotkey: TBDHotkey) -> Result {
        switch validate(hotkey) {
        case .blocked(let message): return .blocked(message)
        case .warned(let message): stop(); return .accepted(hotkey, warning: message)
        case .allowed: stop(); return .accepted(hotkey, warning: nil)
        }
    }

    private mutating func stop() {
        isRecording = false
        pending = []
        candidate = []
    }

    private func modifierChord(from components: [Component]) -> TBDHotkey? {
        let list = mode == .generic ? components.map { Component(modifier: $0.modifier, side: nil) } : components
        let normalized = Self.normalized(list)
        guard Set(normalized.map(\.modifier)).count >= 2 else { return nil }
        return Self.hotkey(from: normalized, keepSides: mode != .generic)
    }

    private func componentsAfterFlagsChanged(keyCode: UInt16, modifier: TBDHotkey.Modifier, flags: UInt64) -> [Component] {
        switch mode {
        case .generic:
            return Self.chordModifiers(flags: flags, keyCode: keyCode, pending: []).map { Component(modifier: $0, side: nil) }
        case .standard, .sideSpecific:
            let sideHeld = TBDHotkey.sideSpecificModifierKeyCodes.compactMap { code -> Component? in
                guard TBDModifierMatch.sidePressed(flags, code), let modifier = TBDHotkey.modifier(forKeyCode: code) else { return nil }
                return Component(modifier: modifier, side: TBDHotkey.side(forKeyCode: code))
            }
            if !sideHeld.isEmpty { return Self.normalized(sideHeld) }
            let changed = Component(modifier: modifier, side: TBDHotkey.side(forKeyCode: keyCode))
            var current = pending
            if current.contains(changed) {
                current.removeAll { $0 == changed }
            } else if flags & modifier.flag != 0 {
                current = Self.normalized(current + [changed])
            }
            return current
        }
    }

    /// Modifiers held for a key chord. macOS sets the Fn flag on F-keys, arrows and navigation keys
    /// even when Fn is not held, so Fn comes from the flags only for other keys (or from a held Fn).
    static func chordModifiers(flags: UInt64, keyCode: UInt16, pending: [Component]) -> [TBDHotkey.Modifier] {
        var names = Set(pending.map(\.modifier))
        if flags & TBDHotkey.Modifier.fn.flag != 0, !TBDHotkey.isFunctionFamily(keyCode) { names.insert(.fn) }
        for modifier in [TBDHotkey.Modifier.control, .option, .shift, .command] where flags & modifier.flag != 0 { names.insert(modifier) }
        return TBDHotkey.Modifier.allCases.filter(names.contains)
    }

    /// v1 `normalizedModifierComponents`: no Fn, no duplicates, ⌃⌥⇧⌘ order.
    static func normalized(_ components: [Component]) -> [Component] {
        var seen: Set<Component> = []
        return components.filter { $0.modifier != .fn && seen.insert($0).inserted }
            .sorted { lhs, rhs in
                lhs.modifier != rhs.modifier ? lhs.modifier < rhs.modifier : (lhs.side == .left && rhs.side != .left)
            }
    }

    /// Both sides of one modifier collapse to "either side" (opt2 stores one side per modifier).
    static func hotkey(from components: [Component], keepSides: Bool) -> TBDHotkey? {
        guard !components.isEmpty else { return nil }
        var sides: [TBDHotkey.Modifier: TBDHotkey.Side] = [:]
        var both: Set<TBDHotkey.Modifier> = []
        for component in components {
            guard keepSides, let side = component.side else { continue }
            if let existing = sides[component.modifier], existing != side { both.insert(component.modifier) }
            sides[component.modifier] = side
        }
        for modifier in both { sides[modifier] = nil }
        return TBDHotkey(modifiers: Set(components.map(\.modifier)), keyCode: nil, sides: sides)
    }
}
