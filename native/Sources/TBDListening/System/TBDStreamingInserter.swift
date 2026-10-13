import AppKit
import Carbon
import CoreGraphics
import TBDSpeech

/// Types text into the focused app as Unicode key events, in eased groups (the "Streaming cursor" setting, v1
/// `StreamingCursorInserter`). The person's own key press or click interrupts it: the rest is typed at once, before their key.
protocol TBDStreamingPosting: Sendable {
    func typeUnicode(_ text: String) throws
}

enum TBDStreamingError: Error, Equatable {
    case unavailable
    /// Some text was typed, the rest could not be. The caller puts the whole text on the clipboard.
    case partialInsert
}

/// Serialises the posts so an interrupt cannot reorder or repeat a group.
final class TBDStreamingPlayback: @unchecked Sendable {
    private let posting: TBDStreamingPosting
    private let lock = NSRecursiveLock()
    private var remaining: [String]
    private(set) var isInterrupted = false
    private(set) var committed = 0

    init(posting: TBDStreamingPosting, batches: [String]) { self.posting = posting; remaining = batches }

    func interruptAndDrain() {
        lock.lock(); defer { lock.unlock() }
        isInterrupted = true
        try? drain(soft: true)
    }

    /// Types `expected` if it is still the next group and no interrupt happened.
    func play(_ expected: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !isInterrupted, remaining.first == expected else { return }
        remaining.removeFirst()
        do { try posting.typeUnicode(expected); committed += 1 } catch { remaining.insert(expected, at: 0); throw error }
    }

    func drainRemaining() throws { lock.lock(); defer { lock.unlock() }; try drain(soft: false) }

    private func drain(soft: Bool) throws {
        while let chunk = remaining.first {
            remaining.removeFirst()
            guard !chunk.isEmpty else { continue }
            do { try posting.typeUnicode(chunk); committed += 1 } catch {
                remaining.insert(chunk, at: 0)
                if soft { return }
                throw error
            }
        }
    }
}

struct TBDCGStreamingPosting: TBDStreamingPosting {
    func typeUnicode(_ text: String) throws {
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .hidSystemState) else { throw TBDStreamingError.unavailable }
        var units = Array(text.utf16)
        guard !units.isEmpty else { return }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { throw TBDStreamingError.unavailable }
        down.flags = []; up.flags = []
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: TBDStreamingInserter.eventMarker)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.post(tap: .cghidEventTap)
        }
    }
}

@MainActor
final class TBDStreamingInserter {
    /// Marks the events this type posts so the hotkey monitor and the interrupt tap ignore them.
    nonisolated static let eventMarker: Int64 = 0x5442_4443
    private let posting: TBDStreamingPosting
    private let sleep: (Duration) async throws -> Void

    init(posting: TBDStreamingPosting = TBDCGStreamingPosting(), sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.posting = posting; self.sleep = sleep
    }

    /// Whether streaming may be used now: Reduce Motion is off and the keyboard layout accepts Unicode events.
    static func allowed(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) -> Bool {
        !reduceMotion && TBDStreamingCursor.inputSourceAllowsStreaming(asciiCapable: asciiCapableInputSource())
    }

    static func asciiCapableInputSource() -> Bool? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return nil }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    func insert(_ text: String) async throws {
        let batches = TBDStreamingSchedule.batches(for: text)
        let playback = TBDStreamingPlayback(posting: posting, batches: batches.map(\.text))
        let interrupt = TBDStreamingInterrupt { playback.interruptAndDrain() }
        defer { interrupt.invalidate() }
        do {
            for batch in batches {
                try Task.checkCancellation()
                if playback.isInterrupted { break }
                if batch.delayBefore > .zero { try await sleep(batch.delayBefore) }
                try Task.checkCancellation()
                try playback.play(batch.text)
            }
            try playback.drainRemaining()
        } catch is CancellationError {
            playback.interruptAndDrain()
            return
        } catch {
            if playback.committed == 0 { throw error }
            do { try playback.drainRemaining() } catch { throw TBDStreamingError.partialInsert }
        }
        if playback.committed > 0, batches.count > 1, !playback.isInterrupted { try? await sleep(.milliseconds(80)) }
    }
}

/// Listens (head insert) for a key press or click while text streams; the first one fires `onInterrupt`, and the
/// event is re-posted after the remainder so the person's key lands after the text.
private final class TBDStreamingInterrupt: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retained: Unmanaged<TBDStreamingInterrupt>?
    private let onInterrupt: @Sendable () -> Void
    private let lock = NSLock()
    private var fired = false

    init(onInterrupt: @escaping @Sendable () -> Void) {
        self.onInterrupt = onInterrupt
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
        let retained = Unmanaged.passRetained(self)
        self.retained = retained
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<TBDStreamingInterrupt>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
        }, userInfo: retained.toOpaque()) else {
            retained.release(); self.retained = nil
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        retained?.release()
        retained = nil; tap = nil; source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == TBDStreamingInserter.eventMarker { return Unmanaged.passUnretained(event) }
        lock.lock(); let first = !fired; fired = true; lock.unlock()
        guard first else { return Unmanaged.passUnretained(event) }
        onInterrupt()
        guard let copy = event.copy() else { return Unmanaged.passUnretained(event) }
        copy.post(tap: .cghidEventTap)
        return nil
    }
}
