import AppKit
import Carbon

/// The pasteboard operations the paster needs. A fake stands in for it in tests.
@MainActor
protocol TBDPasteboarding: AnyObject {
    var changeCount: Int { get }
    /// Every item as type → data, so a restore brings back images and rich text too.
    func snapshot() -> [[String: Data]]
    func clear()
    @discardableResult func setString(_ text: String) -> Bool
    func restore(_ items: [[String: Data]])
}

@MainActor
final class TBDSystemPasteboard: TBDPasteboarding {
    private let board: NSPasteboard
    init(_ board: NSPasteboard = .general) { self.board = board }
    var changeCount: Int { board.changeCount }
    func snapshot() -> [[String: Data]] {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
        }
    }
    func clear() { board.clearContents() }
    func setString(_ text: String) -> Bool { board.setString(text, forType: .string) }
    func restore(_ items: [[String: Data]]) {
        guard !items.isEmpty else { return }
        board.writeObjects(items.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        })
    }
}

/// Synthetic keys the paster sends.
@MainActor
protocol TBDKeySending: AnyObject {
    func paste() throws
    func returnKey() throws
}

/// Pastes dictation into the frontmost app: text to the pasteboard, Cmd-V, then either restore the previous
/// clipboard (default) or leave the text there ("Keep dictation on clipboard", for remote desktops that need a
/// manual Cmd-V). A voice-return phrase sends Return after the paste (v1 `ClipboardService`).
@MainActor
final class TBDClipboardPaster {
    enum PasteError: LocalizedError, Equatable {
        case accessibilityRequired, eventFailed, clipboardWriteFailed
        var errorDescription: String? {
            switch self {
            case .accessibilityRequired: "Allow TBD in System Settings → Privacy & Security → Accessibility to paste automatically. The text is on the clipboard."
            case .eventFailed: "Could not send the paste shortcut. The text is on the clipboard."
            case .clipboardWriteFailed: "Could not put the text on the clipboard."
            }
        }
    }

    private let board: TBDPasteboarding
    private let keys: TBDKeySending
    private let isTrusted: () -> Bool
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let sleep: (Duration) async throws -> Void
    private let restoreDelay: TimeInterval
    private var generation = 0
    /// The person's clipboard while our text stands in for it, so a second dictation before the restore keeps the real original.
    private var pending: (original: [[String: Data]], ours: Int)?

    init(board: TBDPasteboarding, keys: TBDKeySending, isTrusted: @escaping () -> Bool,
         restoreDelay: TimeInterval = 1.5,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
         },
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.board = board; self.keys = keys; self.isTrusted = isTrusted
        self.restoreDelay = restoreDelay; self.schedule = schedule; self.sleep = sleep
    }

    /// Inserts `text`. With `pressReturn` and no text, only Return is sent.
    func insert(_ text: String, keepOnClipboard: Bool, pressReturn: Bool) async throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if pressReturn { try pressReturnKey() }
            return
        }
        // Without Accessibility or on a failed Cmd-V the text stays on the clipboard, so nothing said is lost.
        var saved: [[String: Data]]?
        if !keepOnClipboard {
            if let pending, board.changeCount == pending.ours { saved = pending.original } else { saved = board.snapshot() }
        }
        board.clear()
        guard board.setString(text) else {
            board.clear(); board.restore(saved ?? [])
            pending = nil
            throw PasteError.clipboardWriteFailed
        }
        let ours = board.changeCount
        pending = saved.map { ($0, ours) }
        guard isTrusted() else { throw PasteError.accessibilityRequired }
        generation += 1
        let mine = generation
        do { try keys.paste() } catch { throw PasteError.eventFailed }
        if let saved {
            // Slow apps (Electron, remote sessions) handle Cmd-V late: restore after a safe delay, and only when
            // nobody changed the clipboard meanwhile.
            // Strong self on purpose: the restore must run even if the paster is released first.
            schedule(restoreDelay) { [board] in
                guard self.generation == mine, board.changeCount == ours else { return }
                board.clear()
                board.restore(saved)
                self.pending = nil
            }
        }
        if pressReturn {
            // The paste landed; the keystroke is best effort.
            try? await sleep(.milliseconds(200))
            try? pressReturnKey()
        }
    }

    private func pressReturnKey() throws {
        guard isTrusted() else { throw PasteError.accessibilityRequired }
        do { try keys.returnKey() } catch { throw PasteError.eventFailed }
    }
}

/// Real key events (Cmd-V resolved for the current keyboard layout, plain Return).
@MainActor
final class TBDSystemKeys: TBDKeySending {
    func paste() throws { try post(code: TBDPasteService.keyCode(for: "v"), flags: .maskCommand) }
    func returnKey() throws { try post(code: 0x24, flags: []) }

    private func post(code: CGKeyCode, flags: CGEventFlags) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { throw TBDClipboardPaster.PasteError.eventFailed }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}

extension TBDClipboardPaster {
    static let system = TBDClipboardPaster(board: TBDSystemPasteboard(), keys: TBDSystemKeys(), isTrusted: { TBDPasteService.isTrusted })
}
