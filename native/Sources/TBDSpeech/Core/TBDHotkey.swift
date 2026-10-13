import Foundation

/// A global hotkey: a bare modifier (Fn, Right Option), a modifier chord (Control+Option,
/// Left Control+Right Option), a bare key (F13, End) or a key with modifiers (Command+Shift+M).
/// Text form: tokens joined by "+", for example `fn`, `right_option`, `ctrl+opt`, `left_ctrl+right_opt`,
/// `f13`, `cmd+shift+m`. The empty string means "no hotkey" (disabled) wherever a hotkey is stored.
///
/// Semantics (kinds, validation, overlap and conflict rules, labels) follow v1
/// `MacParakeetCore/STT/HotkeyTrigger.swift` so a hotkey behaves the same as before.
public struct TBDHotkey: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Modifier: String, CaseIterable, Sendable, Comparable {
        case fn, control, option, shift, command
        public static func < (lhs: Self, rhs: Self) -> Bool { allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)! }
        var symbol: String { ["fn": "fn ", "control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"][rawValue]! }
        var name: String { ["fn": "fn", "control": "ctrl", "option": "opt", "shift": "shift", "command": "cmd"][rawValue]! }
        /// v1 display name ("Control") and short symbol ("⌃").
        var longName: String { ["fn": "Fn", "control": "Control", "option": "Option", "shift": "Shift", "command": "Command"][rawValue]! }
        var shortSymbol: String { self == .fn ? "fn" : symbol }
        /// CGEventFlags bit for this modifier.
        public var flag: UInt64 {
            switch self {
            case .fn: 0x0080_0000
            case .control: 0x0004_0000
            case .option: 0x0008_0000
            case .shift: 0x0002_0000
            case .command: 0x0010_0000
            }
        }
        /// Device key codes (left, right); nil for Fn.
        var keyCodes: (left: UInt16, right: UInt16)? {
            switch self {
            case .fn: nil
            case .shift: (56, 60)
            case .control: (59, 62)
            case .option: (58, 61)
            case .command: (55, 54)
            }
        }
    }

    public enum Side: String, Sendable { case left, right }

    /// v1 `HotkeyTrigger.Kind` without `.disabled` (a disabled hotkey is stored as "" / nil).
    public enum Kind: String, Sendable { case modifier, keyCode, chord, modifierChord }

    /// v1 `HotkeyTrigger.ValidationResult`.
    public enum Validation: Equatable, Sendable {
        case allowed
        case warned(String)
        case blocked(String)
    }

    /// v1 `HotkeyTrigger.ConflictMode`: a bare-modifier dictation hotkey may share its modifier with chords.
    public enum ConflictMode: Equatable, Sendable { case exclusive, bareModifierDictation }

    public var modifiers: Set<Modifier>
    /// Virtual key code, or nil for modifier-only hotkeys.
    public var keyCode: UInt16?
    /// Left or right requirement per modifier, for modifier-only hotkeys. Missing: either side.
    public private(set) var sides: [Modifier: Side]

    public init(modifiers: Set<Modifier>, keyCode: UInt16? = nil, side: Side? = nil) {
        var sides: [Modifier: Side] = [:]
        if let side, modifiers.count == 1, let modifier = modifiers.first { sides[modifier] = side }
        self.init(modifiers: modifiers, keyCode: keyCode, sides: sides)
    }

    public init(modifiers: Set<Modifier>, keyCode: UInt16?, sides: [Modifier: Side]) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        // v1 records sides only for modifier-only hotkeys, and never for Fn.
        self.sides = keyCode == nil ? sides.filter { modifiers.contains($0.key) && $0.key != .fn } : [:]
    }

    /// For a single bare modifier: the required left or right key.
    public var side: Side? {
        get { modifiers.count == 1 ? modifiers.first.flatMap { sides[$0] } : nil }
        set {
            guard modifiers.count == 1, let modifier = modifiers.first, modifier != .fn, keyCode == nil else { return }
            sides[modifier] = newValue
        }
    }

    public static let fn = TBDHotkey(modifiers: [.fn])

    public var isModifierOnly: Bool { keyCode == nil }

    public var kind: Kind {
        if keyCode != nil { return modifiers.isEmpty ? .keyCode : .chord }
        return modifiers.count == 1 ? .modifier : .modifierChord
    }

    /// Fn reports key code 63, or 179 on newer keyboards (v1 `HotkeyTrigger.fnKeyCodes`).
    public static let fnKeyCodes: Set<UInt16> = [63, 179]
    public static let escapeKeyCode: UInt16 = 53

    /// Device key code of a side-specific bare modifier (63 for Fn).
    public var modifierKeyCode: UInt16? {
        guard keyCode == nil, modifiers.count == 1, let modifier = modifiers.first else { return nil }
        if modifier == .fn { return 63 }
        guard let side = sides[modifier], let codes = modifier.keyCodes else { return nil }
        return side == .left ? codes.left : codes.right
    }

    /// Device key codes required by a side-specific modifier chord.
    public var modifierChordKeyCodes: [UInt16] {
        guard kind == .modifierChord else { return [] }
        return modifiers.sorted().compactMap { modifier in
            guard let side = sides[modifier], let codes = modifier.keyCodes else { return nil }
            return side == .left ? codes.left : codes.right
        }
    }

    public var description: String { serialized }

    /// Canonical text form (inverse of `parse`).
    public var serialized: String {
        var parts = modifiers.sorted().map { modifier in
            sides[modifier].map { "\($0.rawValue)_\(modifiers.count == 1 ? modifier.rawValue : modifier.name)" } ?? modifier.name
        }
        if let keyCode { parts.append(Self.keyName(keyCode) ?? "key\(keyCode)") }
        return parts.joined(separator: "+")
    }

    /// Short label for the UI, for example "fn", "⌃⌥Space", "Right ⌥", "F13".
    public var displayName: String {
        let key = keyCode.map { (Self.keyName($0) ?? "?").capitalized } ?? ""
        if let side, keyCode == nil, let modifier = modifiers.first { return "\(side.rawValue.capitalized) \(modifier.symbol)" }
        let mods = modifiers.sorted().map(\.symbol).joined()
        return (mods + key).trimmingCharacters(in: .whitespaces)
    }

    // MARK: v1 labels (HotkeyTrigger.displayName / shortSymbol / formattedLabel)

    /// Long name, for example "Fn", "Right Option", "Command+Shift+M", "Left Control+Right Option".
    public var longName: String {
        switch kind {
        case .modifier:
            let modifier = modifiers.first!
            return sides[modifier].map { "\($0.rawValue.capitalized) \(modifier.longName)" } ?? modifier.longName
        case .keyCode:
            return Self.keyLabel(keyCode!).displayName
        case .chord:
            return (modifiers.sorted().map(\.longName) + [Self.keyLabel(keyCode!).displayName]).joined(separator: "+")
        case .modifierChord:
            return modifiers.sorted().map { modifier in
                sides[modifier].map { "\($0.rawValue.capitalized) \(modifier.longName)" } ?? modifier.longName
            }.joined(separator: "+")
        }
    }

    /// Compact symbol, for example "fn", "R⌥", "F13", "⇧⌘M", "fn+Space", "L⌃R⌥".
    public var shortSymbol: String {
        func sided(_ modifier: Modifier) -> String {
            (sides[modifier].map { $0 == .left ? "L" : "R" } ?? "") + modifier.shortSymbol
        }
        switch kind {
        case .modifier: return sided(modifiers.first!)
        case .keyCode: return Self.keyLabel(keyCode!).shortSymbol
        case .chord:
            let symbols = modifiers.sorted().map(\.shortSymbol)
            let key = Self.keyLabel(keyCode!).shortSymbol
            return modifiers.contains(.fn) ? (symbols + [key]).joined(separator: "+") : symbols.joined() + key
        case .modifierChord: return modifiers.sorted().map(sided).joined()
        }
    }

    /// Label for Settings rows: "🌐 Fn", "R⌥ Right Option", "⇧⌘M".
    public var formattedLabel: String {
        switch kind {
        case .modifier:
            if modifiers == [.fn] { return "🌐 Fn" }
            return shortSymbol == longName ? longName : "\(shortSymbol) \(longName)"
        case .keyCode, .chord, .modifierChord:
            return shortSymbol
        }
    }

    // MARK: Validation (v1 HotkeyTrigger.validation)

    public var validation: Validation {
        switch kind {
        case .modifier: return .allowed
        case .keyCode: return Self.validateKey(keyCode!)
        case .chord: return Self.validateChord(keyCode: keyCode!, modifiers: modifiers)
        case .modifierChord: return modifiers.count >= 2 ? .allowed : .blocked("Press at least two modifier keys.")
        }
    }

    static let escapeReservedMessage = "Escape is reserved for canceling dictation."

    private static func validateKey(_ code: UInt16) -> Validation {
        if code == escapeKeyCode { return .blocked(escapeReservedMessage) }
        if [49, 36, 48].contains(code) { return .warned("May interfere with typing.") }
        if [126, 125, 123, 124].contains(code) { return .warned("May interfere with text editing.") }
        let safe: Set<UInt16> = functionKeys.union([115, 119, 116, 121, 117, 57])
        return safe.contains(code) ? .allowed : .warned("May interfere with typing.")
    }

    private static func validateChord(keyCode code: UInt16, modifiers: Set<Modifier>) -> Validation {
        if code == escapeKeyCode { return .blocked(escapeReservedMessage) }
        let hasCommand = modifiers.contains(.command)
        if hasCommand && (code == 48 || code == 49) { return .warned("May not work \u{2014} system shortcut.") }
        // Cmd+Q, Cmd+W, Cmd+H, Cmd+M. Only bare Cmd+M is Minimize; Cmd+Shift+M stays allowed.
        if hasCommand && [12, 13, 4, 46].contains(code) {
            if code == 46 && modifiers != [.command] { return .allowed }
            return .warned("Conflicts with a common system shortcut.")
        }
        return .allowed
    }

    // MARK: Overlap and conflict (v1 HotkeyTrigger.overlaps / conflicts)

    struct Requirement: Equatable {
        let modifier: Modifier
        let side: Side?
        func isCompatible(with other: Requirement) -> Bool {
            guard modifier == other.modifier else { return false }
            if let side, let otherSide = other.side { return side == otherSide }
            return true
        }
    }

    /// A bare Fn modifier has no requirement, so it never overlaps a chord that uses Fn (v1 rule).
    private var bareModifierRequirement: Requirement? {
        guard kind == .modifier, let modifier = modifiers.first, modifier != .fn else { return nil }
        return Requirement(modifier: modifier, side: sides[modifier])
    }

    private var chordRequirements: [Requirement] { modifiers.sorted().map { Requirement(modifier: $0, side: nil) } }
    private var modifierChordRequirements: [Requirement] { modifiers.sorted().map { Requirement(modifier: $0, side: sides[$0]) } }

    private static func requirements(_ required: [Requirement], canBeSatisfiedBy candidates: [Requirement]) -> Bool {
        required.allSatisfy { requirement in candidates.contains { requirement.isCompatible(with: $0) } }
    }

    /// True when one hotkey can fire while the other is pressed.
    public func overlaps(with other: TBDHotkey) -> Bool {
        if self == other { return true }
        switch (kind, other.kind) {
        case (.modifier, .modifier):
            guard let lhs = bareModifierRequirement, let rhs = other.bareModifierRequirement else { return false }
            return lhs.isCompatible(with: rhs)
        case (.modifier, .modifierChord):
            guard let lhs = bareModifierRequirement else { return false }
            return other.modifierChordRequirements.contains { lhs.isCompatible(with: $0) }
        case (.modifier, .chord):
            guard let lhs = bareModifierRequirement else { return false }
            return other.chordRequirements.contains { lhs.isCompatible(with: $0) }
        case (.modifierChord, .modifier), (.chord, .modifier), (.chord, .modifierChord), (.chord, .keyCode):
            return other.overlaps(with: self)
        case (.modifierChord, .modifierChord):
            let lhs = modifierChordRequirements, rhs = other.modifierChordRequirements
            guard lhs.count >= 2, rhs.count >= 2 else { return false }
            return Self.requirements(lhs, canBeSatisfiedBy: rhs) || Self.requirements(rhs, canBeSatisfiedBy: lhs)
        case (.modifierChord, .chord):
            let lhs = modifierChordRequirements, rhs = other.chordRequirements
            guard lhs.count >= 2, !rhs.isEmpty else { return false }
            return Self.requirements(lhs, canBeSatisfiedBy: rhs)
        case (.keyCode, .keyCode), (.keyCode, .chord):
            return keyCode == other.keyCode
        case (.chord, .chord):
            guard keyCode == other.keyCode else { return false }
            let lhs = chordRequirements, rhs = other.chordRequirements
            return Self.requirements(lhs, canBeSatisfiedBy: rhs) || Self.requirements(rhs, canBeSatisfiedBy: lhs)
        default:
            return false
        }
    }

    public func conflicts(with other: TBDHotkey, selfMode: ConflictMode = .exclusive, otherMode: ConflictMode = .exclusive) -> Bool {
        guard overlaps(with: other) else { return false }
        if selfMode == .bareModifierDictation, Self.bareModifierDictationCanShare(self, with: other) { return false }
        if otherMode == .bareModifierDictation, Self.bareModifierDictationCanShare(other, with: self) { return false }
        return true
    }

    private static func bareModifierDictationCanShare(_ dictation: TBDHotkey, with other: TBDHotkey) -> Bool {
        guard let lhs = dictation.bareModifierRequirement else { return false }
        switch other.kind {
        case .chord: return other.chordRequirements.contains { lhs.isCompatible(with: $0) }
        case .modifierChord: return other.modifierChordRequirements.contains { lhs.isCompatible(with: $0) }
        default: return false
        }
    }

    // MARK: Event flags

    /// All modifier bits a hotkey compares (v1 `relevantModifierBits`).
    public static let relevantFlags: UInt64 = Modifier.allCases.reduce(0) { $0 | $1.flag }

    /// Flags the modifiers of this hotkey set.
    public var requiredFlags: UInt64 { modifiers.reduce(UInt64(0)) { $0 | $1.flag } }

    /// F-keys, arrows and the navigation cluster carry the Fn flag on their own events; for chords on
    /// those keys that do not require Fn it is noise (v1 `ignoredChordEventFlags`).
    public var ignoredChordFlags: UInt64 {
        guard kind == .chord, let keyCode, Self.isFunctionFamily(keyCode), !modifiers.contains(.fn) else { return 0 }
        return Modifier.fn.flag
    }

    /// Device-dependent left/right bits (IOKit NX_DEVICE*KEYMASK) by modifier key code.
    static let deviceMasks: [UInt16: UInt64] = [56: 0x02, 60: 0x04, 59: 0x01, 62: 0x2000, 58: 0x20, 61: 0x40, 55: 0x08, 54: 0x10]
    static let oppositeKeyCodes: [UInt16: UInt16] = [56: 60, 60: 56, 59: 62, 62: 59, 58: 61, 61: 58, 55: 54, 54: 55]
    public static let sideSpecificModifierKeyCodes: [UInt16] = [59, 62, 58, 61, 56, 60, 55, 54]

    /// Modifier for a device key code (63/179 → fn, 61 → option).
    public static func modifier(forKeyCode code: UInt16) -> Modifier? {
        if fnKeyCodes.contains(code) { return .fn }
        return Modifier.allCases.first { $0.keyCodes.map { $0.left == code || $0.right == code } ?? false }
    }

    public static func side(forKeyCode code: UInt16) -> Side? {
        guard let modifier = modifier(forKeyCode: code), let codes = modifier.keyCodes else { return nil }
        return codes.left == code ? .left : .right
    }

    // MARK: Text form

    public enum ParseError: Error, Equatable, LocalizedError {
        case empty, unknownToken(String), needsModifier(String), reserved(String)
        public var errorDescription: String? {
            switch self {
            case .empty: "Enter a hotkey."
            case .unknownToken(let token): "Unknown key \"\(token)\"."
            case .needsModifier(let key): "\"\(key)\" needs a modifier (for example ctrl+opt+\(key)) so typing still works."
            case .reserved(let key): "\"\(key)\" is reserved (Escape cancels dictation)."
            }
        }
    }

    /// Parses the text form. Bare keys are accepted (v1 allows them with a warning, see `validation`);
    /// Escape is refused because it cancels dictation.
    public static func parse(_ text: String) throws -> TBDHotkey {
        let tokens = text.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !tokens.isEmpty, !tokens.contains(where: \.isEmpty) else { throw ParseError.empty }
        var modifiers = Set<Modifier>()
        var sides: [Modifier: Side] = [:]
        var keyCode: UInt16?
        for token in tokens {
            if let modifier = modifierAliases[token] { modifiers.insert(modifier); continue }
            if let (tokenSide, rest) = sided(token), let modifier = modifierAliases[rest], modifier != .fn {
                modifiers.insert(modifier); sides[modifier] = tokenSide; continue
            }
            guard keyCode == nil, let code = keyCodes[token] else { throw ParseError.unknownToken(token) }
            if code == escapeKeyCode { throw ParseError.reserved(token) }
            keyCode = code
        }
        guard !modifiers.isEmpty || keyCode != nil else { throw ParseError.empty }
        return TBDHotkey(modifiers: modifiers, keyCode: keyCode, sides: sides)
    }

    /// Stored text → hotkey; "", "none", "disabled" and unparsable text mean no hotkey.
    public static func stored(_ text: String) -> TBDHotkey? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty, value != "none", value != "disabled" else { return nil }
        return try? parse(value)
    }

    private static func sided(_ token: String) -> (Side, String)? {
        for (prefix, side) in [("right_", Side.right), ("left_", .left), ("right", .right), ("left", .left), ("r", .right), ("l", .left)]
            where token.hasPrefix(prefix) && token.count > prefix.count {
            return (side, String(token.dropFirst(prefix.count)))
        }
        return nil
    }

    static let modifierAliases: [String: Modifier] = [
        "fn": .fn, "globe": .fn, "ctrl": .control, "control": .control, "⌃": .control,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift, "cmd": .command, "command": .command, "⌘": .command,
    ]

    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// Keys that carry the Fn flag on their own events: F1–F20, arrows, navigation, Help (v1 `KeyCodeNames`).
    public static func isFunctionFamily(_ code: UInt16) -> Bool {
        functionKeys.contains(code) || [123, 124, 125, 126, 115, 116, 117, 119, 121, 114].contains(code)
    }

    static let keyCodes: [String: UInt16] = {
        var map: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
            "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
            "delete": 51, "escape": 53, "esc": 53, "capslock": 57, "keypadenter": 76,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
            "up": 126, "down": 125, "left": 123, "right": 124,
            "uparrow": 126, "downarrow": 125, "leftarrow": 123, "rightarrow": 124,
        ]
        let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in fkeys.enumerated() { map["f\(index + 1)"] = code }
        return map
    }()

    static func keyName(_ code: UInt16) -> String? {
        let preferred = ["return", "escape", "up", "down", "left", "right"]
        let names = keyCodes.filter { $0.value == code }.map(\.key)
        return names.first { preferred.contains($0) } ?? names.sorted { $0.count > $1.count || ($0.count == $1.count && $0 < $1) }.first
    }

    /// v1 `KeyCodeNames.name(for:)`: display name and compact symbol; "Key <code>" when unknown.
    public static func keyLabel(_ code: UInt16) -> (displayName: String, shortSymbol: String) {
        if let index = functionKeyOrder.firstIndex(of: code) { return ("F\(index + 1)", "F\(index + 1)") }
        let special: [UInt16: (String, String)] = [
            115: ("Home", "Home"), 119: ("End", "End"), 116: ("Page Up", "PgUp"), 121: ("Page Down", "PgDn"),
            117: ("Forward Delete", "⌦"), 126: ("Up Arrow", "↑"), 125: ("Down Arrow", "↓"), 123: ("Left Arrow", "←"),
            124: ("Right Arrow", "→"), 48: ("Tab", "⇥"), 49: ("Space", "Space"), 36: ("Return", "↩"), 53: ("Escape", "Esc"),
            57: ("Caps Lock", "⇪"), 51: ("Delete", "⌫"), 76: ("Enter", "⌅"),
        ]
        if let entry = special[code] { return entry }
        if let name = keyCodes.first(where: { $0.value == code && $0.key.count == 1 })?.key {
            return (name.uppercased(), name.uppercased())
        }
        return ("Key \(code)", "Key \(code)")
    }

    private static let functionKeyOrder: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
}
