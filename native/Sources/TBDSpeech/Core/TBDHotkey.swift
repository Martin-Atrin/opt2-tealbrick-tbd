import Foundation

/// A global hotkey: a bare modifier (Fn, Right Option), a modifier chord (Control+Option),
/// a function key (F13–F19) or a key with modifiers (Control+Option+Space).
/// Text form: tokens joined by "+", for example `fn`, `right_option`, `ctrl+opt`, `f13`, `cmd+shift+d`.
public struct TBDHotkey: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Modifier: String, CaseIterable, Sendable, Comparable {
        case fn, control, option, shift, command
        public static func < (lhs: Self, rhs: Self) -> Bool { allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)! }
        var symbol: String { ["fn": "fn ", "control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"][rawValue]! }
        var name: String { ["fn": "fn", "control": "ctrl", "option": "opt", "shift": "shift", "command": "cmd"][rawValue]! }
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
    }

    public enum Side: String, Sendable { case left, right }

    public var modifiers: Set<Modifier>
    /// Virtual key code, or nil for modifier-only hotkeys.
    public var keyCode: UInt16?
    /// For a single bare modifier: require the left or right key.
    public var side: Side?

    public init(modifiers: Set<Modifier>, keyCode: UInt16? = nil, side: Side? = nil) {
        self.modifiers = modifiers; self.keyCode = keyCode; self.side = side
    }

    public static let fn = TBDHotkey(modifiers: [.fn])

    public var isModifierOnly: Bool { keyCode == nil }

    /// Device key code of a side-specific bare modifier.
    public var modifierKeyCode: UInt16? {
        guard keyCode == nil, modifiers.count == 1, let modifier = modifiers.first else { return nil }
        if modifier == .fn { return 63 }
        guard let side else { return nil }
        let codes: [Modifier: (UInt16, UInt16)] = [.shift: (56, 60), .control: (59, 62), .option: (58, 61), .command: (55, 54)]
        return codes[modifier].map { side == .left ? $0.0 : $0.1 }
    }

    public var description: String { serialized }

    /// Canonical text form (inverse of `parse`).
    public var serialized: String {
        var parts = modifiers.sorted().map(\.name)
        if let side, parts.count == 1 { parts = ["\(side.rawValue)_\(modifiers.first!.rawValue)"] }
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

    public static func parse(_ text: String) throws -> TBDHotkey {
        let tokens = text.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard !tokens.isEmpty, !tokens.contains(where: \.isEmpty) else { throw ParseError.empty }
        var modifiers = Set<Modifier>()
        var side: Side?
        var keyCode: UInt16?
        for token in tokens {
            if let modifier = modifierAliases[token] { modifiers.insert(modifier); continue }
            if let (tokenSide, rest) = sided(token), let modifier = modifierAliases[rest], modifier != .fn {
                modifiers.insert(modifier); side = tokenSide; continue
            }
            guard keyCode == nil, let code = keyCodes[token] else { throw ParseError.unknownToken(token) }
            if code == 53 { throw ParseError.reserved(token) }
            keyCode = code
        }
        if side != nil && (modifiers.count != 1 || keyCode != nil) { side = nil }
        if let keyCode, modifiers.isEmpty, !functionKeys.contains(keyCode) {
            throw ParseError.needsModifier(keyName(keyCode) ?? "key")
        }
        guard !modifiers.isEmpty || keyCode != nil else { throw ParseError.empty }
        return TBDHotkey(modifiers: modifiers, keyCode: keyCode, side: side)
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

    static let keyCodes: [String: UInt16] = {
        var map: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
            "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
            "delete": 51, "escape": 53, "esc": 53,
        ]
        let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in fkeys.enumerated() { map["f\(index + 1)"] = code }
        return map
    }()

    static func keyName(_ code: UInt16) -> String? {
        let preferred = ["return", "escape"]
        let names = keyCodes.filter { $0.value == code }.map(\.key)
        return names.first { preferred.contains($0) } ?? names.sorted { $0.count > $1.count || ($0.count == $1.count && $0 < $1) }.first
    }
}

/// Hold-or-tap gesture for a dictation hotkey: hold to talk (stop on release), tap for hands-free
/// (stop on the next press). Escape cancels. Pure state machine; the monitor feeds it events.
public struct TBDHotkeyGesture: Sendable {
    public enum State: Equatable, Sendable { case idle, pending, holding, handsFree, waitingForRelease, blocked }
    public enum Action: Equatable, Sendable { case none, start, startHandsFree, handsFree, stop, cancel }

    public private(set) var state: State = .idle
    private var pressedAt: UInt64 = 0
    /// Presses shorter than this are taps.
    public let tapThresholdMs: UInt64

    public init(tapThresholdMs: UInt64 = 350) { self.tapThresholdMs = tapThresholdMs }

    /// Hotkey went down. Recording starts on `armed()` so modifier shortcuts (fn+arrow) do not flash the mic.
    public mutating func press(at ms: UInt64) -> Action {
        switch state {
        case .idle: state = .pending; pressedAt = ms; return .none
        case .handsFree: state = .waitingForRelease; return .stop
        default: return .none
        }
    }

    /// Debounce elapsed while still held.
    public mutating func armed() -> Action {
        guard state == .pending else { return .none }
        state = .holding
        return .start
    }

    public mutating func release(at ms: UInt64) -> Action {
        switch state {
        case .pending: state = .handsFree; return .startHandsFree
        case .holding:
            if ms &- pressedAt < tapThresholdMs { state = .handsFree; return .handsFree }
            state = .idle; return .stop
        case .waitingForRelease, .blocked: state = .idle; return .none
        default: return .none
        }
    }

    /// Another key was pressed while a modifier-only hotkey is held: it is a shortcut, not dictation.
    public mutating func otherKey() -> Action {
        switch state {
        case .pending: state = .blocked; return .none
        case .holding: state = .blocked; return .cancel
        default: return .none
        }
    }

    public mutating func escape(keyHeld: Bool) -> Action {
        switch state {
        case .holding, .handsFree, .pending:
            let wasRecording = state != .pending
            state = keyHeld ? .blocked : .idle
            return wasRecording ? .cancel : .none
        default: return .none
        }
    }

    /// Recording ended elsewhere (UI button, error).
    public mutating func reset(keyHeld: Bool = false) { state = keyHeld ? .blocked : .idle }
}
