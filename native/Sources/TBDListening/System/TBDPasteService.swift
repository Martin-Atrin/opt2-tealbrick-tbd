import AppKit
import ApplicationServices
import Carbon

/// Pastes text into the frontmost app (pasteboard + synthetic Cmd-V, previous clipboard restored)
/// and reads the current selection. Needs the Accessibility permission.
@MainActor
enum TBDPasteService {
    enum PasteError: LocalizedError {
        case accessibilityRequired, eventFailed
        var errorDescription: String? {
            switch self {
            case .accessibilityRequired: "Allow TBD in System Settings → Privacy & Security → Accessibility to paste automatically. The text is on the clipboard."
            case .eventFailed: "Could not send the paste shortcut. The text is on the clipboard."
            }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt once.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    private static var restoreGeneration = 0

    /// Puts `text` on the pasteboard, sends Cmd-V and restores the previous clipboard shortly after.
    /// Without Accessibility the text stays on the clipboard and the error says so.
    static func paste(_ text: String, restoreClipboard: Bool = true) throws {
        let board = NSPasteboard.general
        let saved = restoreClipboard ? snapshot(board) : nil
        board.clearContents()
        board.setString(text, forType: .string)
        let ours = board.changeCount
        guard isTrusted else { throw PasteError.accessibilityRequired }
        try sendShortcut("v")
        guard let saved else { return }
        restoreGeneration += 1
        let generation = restoreGeneration
        // Slow apps (Electron, remote sessions) may handle Cmd-V late; restore only after a safe delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Restore only if nobody (user or app) changed the clipboard meanwhile.
            guard generation == restoreGeneration, board.changeCount == ours else { return }
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Selected text of the focused element: Accessibility first, then a Cmd-C round trip that
    /// restores the clipboard. Returns nil when nothing is selected.
    static func selectedText() async -> String? {
        if let text = axSelectedText(), !text.isEmpty { return text }
        guard isTrusted else { return nil }
        let board = NSPasteboard.general
        let saved = snapshot(board)
        let before = board.changeCount
        try? sendShortcut("c")
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(30))
            if board.changeCount != before { break }
        }
        let copied = board.changeCount != before ? board.string(forType: .string) : nil
        if board.changeCount != before {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
        return copied?.isEmpty == false ? copied : nil
    }

    private static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    /// Sends Cmd+<character>, resolving the key for the current keyboard layout (Dvorak, AZERTY…).
    private static func sendShortcut(_ character: Character) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw PasteError.eventFailed }
        let code = keyCode(for: character)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { throw PasteError.eventFailed }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func keyCode(for character: Character) -> CGKeyCode {
        let fallback: CGKeyCode = character == "c" ? 8 : 9
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data), let target = String(character).utf16.first else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for code in UInt16(0)..<128 {
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8), UInt32(LMGetKbdType()),
                                        UInt32(kUCKeyTranslateNoDeadKeysMask), &deadKeys, chars.count, &length, &chars)
            if status == noErr, length > 0, chars[0] == target { return CGKeyCode(code) }
        }
        return fallback
    }
}
