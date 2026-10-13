import AppKit
import TBDSpeech

/// Global keyboard listener (one CGEventTap on the main run loop). Hands every key event to the
/// hotkey coordinator, which returns whether to swallow it.
@MainActor
final class TBDHotkeyMonitor {
    private var handler: ((TBDKeyEvent) -> Bool)?
    private var activeTap = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private(set) var isActive = false
    var onStatusChange: ((Bool) -> Void)?

    /// Starts listening. `activeTap` is needed when a hotkey must swallow its key (anything but bare Fn).
    func set(activeTap: Bool, handler: ((TBDKeyEvent) -> Bool)?) {
        stop()
        self.handler = handler
        self.activeTap = activeTap
        guard handler != nil else { return }
        start()
    }

    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        updateStatus(false)
    }

    /// Current modifier flags (used to re-sync held keys after a reset).
    static var currentFlags: UInt64 { CGEventSource.flagsState(.combinedSessionState).rawValue }
    static func keyIsDown(_ code: UInt16) -> Bool { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) }

    private func start() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: activeTap ? .defaultTap : .listenOnly,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<TBDHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
        }, userInfo: refcon) else {
            // Permission missing: retry until the user grants it.
            updateStatus(false)
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.tap == nil, self.handler != nil { self.start() } }
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
        // Text typed by the streaming cursor must not look like a key press.
        if event.getIntegerValueField(.eventSourceUserData) == TBDStreamingInserter.eventMarker { return Unmanaged.passUnretained(event) }
        let ms = event.timestamp / 1_000_000
        let flags = event.flags.rawValue
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let keyEvent: TBDKeyEvent
        switch type {
        case .flagsChanged: keyEvent = .flagsChanged(keyCode: code, flags: flags, timestampMs: ms)
        case .keyDown: keyEvent = .keyDown(keyCode: code, flags: flags, timestampMs: ms)
        case .keyUp: keyEvent = .keyUp(keyCode: code, flags: flags, timestampMs: ms)
        default: return Unmanaged.passUnretained(event)
        }
        let swallow = handler?(keyEvent) ?? false
        return swallow && activeTap ? nil : Unmanaged.passUnretained(event)
    }
}
