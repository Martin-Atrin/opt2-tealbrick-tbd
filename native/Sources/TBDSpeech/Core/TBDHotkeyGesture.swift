import Foundation

/// Double-tap / hold detection for one dictation hotkey. Pure; the hotkey coordinator feeds it
/// abstract presses and releases. Ported 1:1 from v1 `MacParakeetCore/STT/FnKeyStateMachine.swift`.
public struct TBDFnKeyStateMachine: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// Pressed once; waiting to see whether a second tap follows.
        case waitingForSecondTap
        /// Double-tap confirmed, recording until the next press.
        case persistent
        /// Held past the tap threshold, recording until release.
        case holdToTalk
        /// Escape pressed; inside the undo window.
        case cancelWindow
        /// Trigger pressed during the cancel window.
        case blocked
    }

    public enum Action: Equatable, Sendable {
        case none
        case startRecording(mode: RecordingMode)
        case stopRecording
        case cancelRecording
        case discardRecording(showReadyPill: Bool)
    }

    public enum RecordingMode: Equatable, Sendable {
        /// Hands-free: stays on until explicitly stopped.
        case persistent
        /// Push-to-talk: stops when the key is released.
        case holdToTalk
    }

    /// Presses shorter than this are taps (v1 default 400 ms, clamped to 50–500 ms).
    public static let defaultTapThresholdMs = 400
    public static let minimumTapThresholdMs = 50
    public static let maximumTapThresholdMs = 500
    /// A hold starts a provisional recording after this debounce, so modifier shortcuts do not flash the mic.
    public static let defaultStartupDebounceMs = 100

    public private(set) var state: State = .idle
    public let tapThresholdMs: Int
    private var fnDownTimestamp: UInt64 = 0
    private var firstTapTimestamp: UInt64 = 0
    private var hasActiveProvisionalRecording = false

    public init(tapThresholdMs: Int = defaultTapThresholdMs) {
        self.tapThresholdMs = Self.clampTapThresholdMs(tapThresholdMs)
    }

    public static func clampTapThresholdMs(_ value: Int) -> Int {
        min(max(value, minimumTapThresholdMs), maximumTapThresholdMs)
    }

    public mutating func fnDown(timestampMs: UInt64) -> Action {
        switch state {
        case .idle:
            fnDownTimestamp = timestampMs
            state = .waitingForSecondTap
            hasActiveProvisionalRecording = false
            return .none
        case .waitingForSecondTap:
            if timestampMs &- firstTapTimestamp <= UInt64(tapThresholdMs) {
                state = .persistent
                hasActiveProvisionalRecording = false
                return .startRecording(mode: .persistent)
            }
            // Too slow: a new first tap.
            fnDownTimestamp = timestampMs
            hasActiveProvisionalRecording = false
            return .none
        case .persistent:
            state = .idle
            hasActiveProvisionalRecording = false
            return .stopRecording
        case .holdToTalk:
            return .none
        case .cancelWindow, .blocked:
            state = .blocked
            return .none
        }
    }

    /// The startup debounce fired while still waiting on the first press.
    public mutating func startupTimerFired() -> Action {
        guard state == .waitingForSecondTap, !hasActiveProvisionalRecording else { return .none }
        hasActiveProvisionalRecording = true
        return .startRecording(mode: .holdToTalk)
    }

    public mutating func fnUp(timestampMs: UInt64) -> Action {
        switch state {
        case .waitingForSecondTap:
            if timestampMs &- fnDownTimestamp >= UInt64(tapThresholdMs) {
                state = .idle
                let shouldStop = hasActiveProvisionalRecording
                hasActiveProvisionalRecording = false
                return shouldStop ? .stopRecording : .none
            }
            // Quick release: discard the provisional capture and wait for the second tap.
            firstTapTimestamp = timestampMs
            let shouldDiscard = hasActiveProvisionalRecording
            hasActiveProvisionalRecording = false
            return shouldDiscard ? .discardRecording(showReadyPill: true) : .none
        case .holdToTalk:
            state = .idle
            hasActiveProvisionalRecording = false
            return .stopRecording
        case .blocked:
            state = .cancelWindow
            return .none
        default:
            return .none
        }
    }

    /// The tap-threshold timer fired while the trigger is still held.
    public mutating func holdTimerFired() -> Action {
        guard state == .waitingForSecondTap else { return .none }
        state = .holdToTalk
        if hasActiveProvisionalRecording {
            hasActiveProvisionalRecording = false
            return .none
        }
        return .startRecording(mode: .holdToTalk)
    }

    /// Other input interrupted the first-press / double-tap window. Discards silently only if a
    /// provisional recording had started.
    public mutating func interruptWaitingForSecondTap() -> Action {
        guard state == .waitingForSecondTap else { return .none }
        state = .idle
        fnDownTimestamp = 0
        firstTapTimestamp = 0
        let shouldDiscard = hasActiveProvisionalRecording
        hasActiveProvisionalRecording = false
        return shouldDiscard ? .discardRecording(showReadyPill: false) : .none
    }

    public mutating func escapePressed() -> Action {
        switch state {
        case .waitingForSecondTap where hasActiveProvisionalRecording:
            state = .cancelWindow
            hasActiveProvisionalRecording = false
            return .cancelRecording
        case .persistent, .holdToTalk:
            state = .cancelWindow
            hasActiveProvisionalRecording = false
            return .cancelRecording
        case .cancelWindow, .blocked:
            // Escape during the undo countdown confirms the cancel.
            state = .idle
            hasActiveProvisionalRecording = false
            return .cancelRecording
        default:
            return .none
        }
    }

    public mutating func blockUntilReset() {
        state = .cancelWindow
        hasActiveProvisionalRecording = false
    }

    public mutating func resumeRecording(mode: RecordingMode) {
        state = mode == .persistent ? .persistent : .holdToTalk
        hasActiveProvisionalRecording = false
    }

    public mutating func reset() {
        state = .idle
        fnDownTimestamp = 0
        firstTapTimestamp = 0
        hasActiveProvisionalRecording = false
    }
}

/// Gesture flow for one dictation hotkey in one of v1's four modes, with timer directives but no
/// event-tap wiring. Ported 1:1 from v1 `MacParakeetCore/STT/HotkeyGestureController.swift`.
public struct TBDHotkeyGestureController: Sendable {
    public typealias RecordingMode = TBDFnKeyStateMachine.RecordingMode

    public enum Mode: Equatable, Sendable {
        /// Shared push-to-talk and hands-free key: hold to talk, double-tap for hands-free.
        case doubleTapAndHold
        case doubleTapOnly
        /// Push-to-talk key.
        case holdOnly
        /// Hands-free, clipboard-only and AI-polish keys: tap to start, tap to stop.
        case singleTapToggle
    }

    public enum Output: Equatable, Sendable {
        case startRecording(mode: RecordingMode)
        case stopRecording
        case cancelRecording
        case discardRecording(showReadyPill: Bool)
        case showReadyForSecondTap
        case escapeWhileIdle
        case scheduleStartupDebounce(milliseconds: Int)
        case scheduleHoldWindow(milliseconds: Int)
        case cancelStartupDebounce
        case cancelHoldWindow
    }

    private enum HoldOnlyState: Equatable, Sendable { case idle, pressed, active, cancelWindow, blocked }
    private enum SingleTapState: Equatable, Sendable { case idle, active, cancelWindow, blocked }

    public let mode: Mode
    public let tapThresholdMs: Int
    public let startupDebounceMs: Int
    private var stateMachine: TBDFnKeyStateMachine
    private var holdOnlyState: HoldOnlyState = .idle
    private var singleTapState: SingleTapState = .idle
    private var suppressedUntilReset = false

    public init(mode: Mode = .doubleTapAndHold,
                tapThresholdMs: Int = TBDFnKeyStateMachine.defaultTapThresholdMs,
                startupDebounceMs: Int = TBDFnKeyStateMachine.defaultStartupDebounceMs) {
        let threshold = TBDFnKeyStateMachine.clampTapThresholdMs(tapThresholdMs)
        self.mode = mode
        self.tapThresholdMs = threshold
        self.startupDebounceMs = min(threshold, max(0, startupDebounceMs))
        stateMachine = TBDFnKeyStateMachine(tapThresholdMs: threshold)
    }

    /// The underlying double-tap state (tests and diagnostics).
    public var fnState: TBDFnKeyStateMachine.State { stateMachine.state }

    /// A press is still being evaluated (not yet a tap, hold or double-tap).
    public var hasPendingTriggerPress: Bool {
        switch mode {
        case .holdOnly: holdOnlyState == .pressed
        case .doubleTapAndHold, .doubleTapOnly: stateMachine.state == .waitingForSecondTap
        case .singleTapToggle: false
        }
    }

    public mutating func triggerPressed(timestampMs: UInt64) -> [Output] {
        guard !suppressedUntilReset else { return [] }
        if mode == .holdOnly {
            switch holdOnlyState {
            case .idle:
                holdOnlyState = .pressed
                return [.scheduleStartupDebounce(milliseconds: startupDebounceMs)]
            case .cancelWindow, .blocked:
                holdOnlyState = .blocked
                return []
            case .pressed, .active:
                return []
            }
        }
        if mode == .singleTapToggle {
            switch singleTapState {
            case .idle:
                singleTapState = .active
                return [.startRecording(mode: .persistent)]
            case .active:
                singleTapState = .idle
                return [.stopRecording]
            case .cancelWindow, .blocked:
                singleTapState = .blocked
                return []
            }
        }
        let action = stateMachine.fnDown(timestampMs: timestampMs)
        var results = Self.outputs(for: action)
        if mode == .doubleTapAndHold, action == .none, stateMachine.state == .waitingForSecondTap {
            results.append(.scheduleStartupDebounce(milliseconds: startupDebounceMs))
            results.append(.scheduleHoldWindow(milliseconds: tapThresholdMs))
        }
        return results
    }

    public mutating func triggerReleased(timestampMs: UInt64) -> [Output] {
        guard !suppressedUntilReset else { return [] }
        var results: [Output] = [.cancelStartupDebounce, .cancelHoldWindow]
        if mode == .holdOnly {
            switch holdOnlyState {
            case .pressed: holdOnlyState = .idle
            case .active: holdOnlyState = .idle; results.append(.stopRecording)
            case .blocked: holdOnlyState = .cancelWindow
            case .idle, .cancelWindow: break
            }
            return results
        }
        if mode == .singleTapToggle { return [] }
        let action = stateMachine.fnUp(timestampMs: timestampMs)
        results.append(contentsOf: Self.outputs(for: action))
        if action == .none, stateMachine.state == .waitingForSecondTap { results.append(.showReadyForSecondTap) }
        return results
    }

    /// The trigger was released after other keys were pressed with it (a shortcut, not dictation).
    public mutating func nonBareTriggerReleased() -> [Output] {
        guard !suppressedUntilReset else { return [] }
        var results: [Output] = [.cancelStartupDebounce, .cancelHoldWindow]
        if mode == .holdOnly {
            switch holdOnlyState {
            case .pressed: holdOnlyState = .idle
            case .active: holdOnlyState = .idle; results.append(.cancelRecording)
            case .blocked: holdOnlyState = .cancelWindow
            case .idle, .cancelWindow: break
            }
            return results
        }
        if mode == .singleTapToggle { return [] }
        switch stateMachine.state {
        case .holdToTalk:
            stateMachine.reset()
            results.append(.cancelRecording)
        case .waitingForSecondTap:
            results.append(contentsOf: Self.outputs(for: stateMachine.interruptWaitingForSecondTap()))
        default:
            break
        }
        return results
    }

    /// Another key interrupted the gesture.
    public mutating func interrupted() -> [Output] {
        guard !suppressedUntilReset else { return [] }
        if mode == .holdOnly { return nonBareTriggerReleased() }
        if mode == .singleTapToggle { return [] }
        var results: [Output] = [.cancelStartupDebounce, .cancelHoldWindow]
        switch stateMachine.state {
        case .waitingForSecondTap:
            results.append(contentsOf: Self.outputs(for: stateMachine.interruptWaitingForSecondTap()))
            return results
        case .holdToTalk:
            stateMachine.reset()
            results.append(.cancelRecording)
            return results
        default:
            return []
        }
    }

    public mutating func escapePressed() -> [Output] {
        guard !suppressedUntilReset else { return [] }
        if mode == .holdOnly {
            var results: [Output] = [.cancelStartupDebounce, .cancelHoldWindow]
            switch holdOnlyState {
            case .pressed: holdOnlyState = .idle
            case .active: holdOnlyState = .cancelWindow; results.append(.cancelRecording)
            case .cancelWindow, .blocked: holdOnlyState = .idle; results.append(.cancelRecording)
            case .idle: return [.escapeWhileIdle]
            }
            return results
        }
        if mode == .singleTapToggle {
            switch singleTapState {
            case .active: singleTapState = .cancelWindow; return [.cancelRecording]
            case .cancelWindow, .blocked: singleTapState = .idle; return [.cancelRecording]
            case .idle: return [.escapeWhileIdle]
            }
        }
        let wasWaitingForSecondTap = stateMachine.state == .waitingForSecondTap
        let action = stateMachine.escapePressed()
        if action == .none {
            if wasWaitingForSecondTap {
                stateMachine.reset()
                return [.cancelStartupDebounce, .cancelHoldWindow]
            }
            return [.escapeWhileIdle]
        }
        return [.cancelStartupDebounce, .cancelHoldWindow] + Self.outputs(for: action)
    }

    public mutating func startupDebounceElapsed() -> [Output] {
        guard !suppressedUntilReset else { return [] }
        switch mode {
        case .doubleTapOnly, .singleTapToggle: return []
        case .holdOnly:
            guard holdOnlyState == .pressed else { return [] }
            holdOnlyState = .active
            return [.startRecording(mode: .holdToTalk)]
        case .doubleTapAndHold:
            return Self.outputs(for: stateMachine.startupTimerFired())
        }
    }

    public mutating func holdWindowElapsed() -> [Output] {
        guard !suppressedUntilReset, mode == .doubleTapAndHold else { return [] }
        return Self.outputs(for: stateMachine.holdTimerFired())
    }

    /// Another dictation hotkey owns the current take: ignore this one until the flow resets it.
    public mutating func suppressUntilReset() {
        suppressedUntilReset = true
        holdOnlyState = .idle
        singleTapState = .idle
        stateMachine.reset()
    }

    /// Cancel came from the UI: every dictation hotkey stays blocked until the flow resets it.
    public mutating func notifyCancelledByUI() {
        suppressedUntilReset = false
        switch mode {
        case .holdOnly: holdOnlyState = .cancelWindow
        case .singleTapToggle: singleTapState = .cancelWindow
        case .doubleTapAndHold, .doubleTapOnly: stateMachine.blockUntilReset()
        }
    }

    public mutating func resumeRecording(mode recordingMode: RecordingMode) {
        suppressedUntilReset = false
        switch mode {
        case .holdOnly: holdOnlyState = recordingMode == .holdToTalk ? .active : .idle
        case .singleTapToggle: singleTapState = recordingMode == .persistent ? .active : .idle
        case .doubleTapAndHold, .doubleTapOnly: stateMachine.resumeRecording(mode: recordingMode)
        }
    }

    public mutating func reset() {
        suppressedUntilReset = false
        holdOnlyState = .idle
        singleTapState = .idle
        stateMachine.reset()
    }

    /// v1 `HotkeyManager.resumeMode`: which take a hotkey in `gestureMode` can keep controlling.
    public static func resumeMode(_ activeMode: RecordingMode?, for gestureMode: Mode) -> RecordingMode? {
        guard let activeMode else { return nil }
        switch (activeMode, gestureMode) {
        case (.persistent, .singleTapToggle), (.persistent, .doubleTapOnly), (.persistent, .doubleTapAndHold),
             (.holdToTalk, .holdOnly), (.holdToTalk, .doubleTapAndHold):
            return activeMode
        case (.persistent, .holdOnly), (.holdToTalk, .singleTapToggle), (.holdToTalk, .doubleTapOnly):
            return nil
        }
    }

    private static func outputs(for action: TBDFnKeyStateMachine.Action) -> [Output] {
        switch action {
        case .none: []
        case .startRecording(let mode): [.startRecording(mode: mode)]
        case .stopRecording: [.stopRecording]
        case .cancelRecording: [.cancelRecording]
        case .discardRecording(let showReadyPill): [.discardRecording(showReadyPill: showReadyPill)]
        }
    }
}
