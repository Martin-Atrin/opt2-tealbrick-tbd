import AppKit
import TBDSpeech

/// Global hotkey listener (CGEventTap on the main run loop). Reports presses, releases, other keys
/// pressed while a modifier-only hotkey is held, and Escape.
@MainActor
final class TBDHotkeyMonitor {
    enum Event { case down, up, otherKey, escape }

    struct Binding {
        let hotkey: TBDHotkey
        let handler: @MainActor (Event, UInt64) -> Void
        var pressed = false
    }

    private var bindings: [Binding] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private(set) var isActive = false
    var onStatusChange: ((Bool) -> Void)?

    private static let relevantFlags: UInt64 = TBDHotkey.Modifier.allCases.reduce(0) { $0 | $1.flag }

    func set(_ bindings: [Binding]) {
        self.bindings = bindings
        stop()
        guard !bindings.isEmpty else { return }
        start()
    }

    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        updateStatus(false)
    }

    private func start() {
        // Key hotkeys must be swallowed (active tap); bare modifiers only need to be observed.
        let active = bindings.contains { !$0.hotkey.isModifierOnly }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: active ? .defaultTap : .listenOnly,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<TBDHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
        }, userInfo: refcon) else {
            // Permission missing: retry until the user grants it.
            updateStatus(false)
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.tap == nil, !self.bindings.isEmpty { self.start() } }
            }
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        updateStatus(true)
    }

    private func updateStatus(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        onStatusChange?(active)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let ms = event.timestamp / 1_000_000
        let flags = event.flags.rawValue & Self.relevantFlags
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        var swallow = false
        for index in bindings.indices {
            let hotkey = bindings[index].hotkey
            switch type {
            case .flagsChanged where hotkey.isModifierOnly:
                let down = Self.modifierHotkeyDown(hotkey, flags: flags, changedKey: code, wasDown: bindings[index].pressed)
                if down != bindings[index].pressed {
                    bindings[index].pressed = down
                    bindings[index].handler(down ? .down : .up, ms)
                }
            case .keyDown:
                if code == 53 { bindings[index].handler(.escape, ms); continue }
                if hotkey.isModifierOnly {
                    if bindings[index].pressed { bindings[index].handler(.otherKey, ms) }
                } else if code == hotkey.keyCode, Self.flagsMatch(hotkey, flags: flags) {
                    swallow = true
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, !bindings[index].pressed {
                        bindings[index].pressed = true
                        bindings[index].handler(.down, ms)
                    }
                }
            case .keyUp where !hotkey.isModifierOnly && code == hotkey.keyCode:
                if bindings[index].pressed {
                    swallow = true
                    bindings[index].pressed = false
                    bindings[index].handler(.up, ms)
                }
            default: break
            }
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Exact modifier match; F-keys may carry the fn flag on laptop keyboards, so it is ignored for them.
    static func flagsMatch(_ hotkey: TBDHotkey, flags: UInt64) -> Bool {
        let required = hotkey.modifiers.reduce(UInt64(0)) { $0 | $1.flag }
        let ignore = hotkey.modifiers.contains(.fn) ? 0 : TBDHotkey.Modifier.fn.flag
        return flags & ~ignore == required
    }

    static func modifierHotkeyDown(_ hotkey: TBDHotkey, flags: UInt64, changedKey: UInt16, wasDown: Bool) -> Bool {
        let required = hotkey.modifiers.reduce(UInt64(0)) { $0 | $1.flag }
        guard flags == required else { return false }
        // Side-specific bare modifier: only the chosen physical key toggles it.
        if let sideCode = hotkey.modifierKeyCode, hotkey.side != nil {
            return changedKey == sideCode ? !wasDown : wasDown
        }
        return true
    }
}
