import Foundation
import TBDSpeech

/// What the Listening hotkeys drive. `TBDListeningContext` implements it with the real controllers.
@MainActor
protocol TBDHotkeyTargets: AnyObject {
    func hotkeyStartDictation(mode: TBDFnKeyStateMachine.RecordingMode, options: TBDDictationTakeOptions) -> Bool
    func hotkeyStopDictation()
    func hotkeyCancelDictation()
    func hotkeyDiscardDictation(showReadyPill: Bool)
    func hotkeyReadyForSecondTap()
    /// Meeting start/stop, transcribe file, transcribe URL (the menu-bar actions).
    func hotkeyPerform(_ action: TBDListeningAction)
    func hotkeyRunTransform()
    func hotkeyReport(_ message: String)
    /// Recording mode of a live dictation take, nil when idle.
    var hotkeyRecordingMode: TBDFnKeyStateMachine.RecordingMode? { get }
}

/// Builds and runs every Listening hotkey: the dictation keys (push to talk, hands-free, clipboard-only,
/// AI polish) with their gesture rules, and the immediate keys (meeting, file, URL, transform).
/// Ported from v1 `MacParakeet/App/AppHotkeyCoordinator.swift` plus the timer and stop-tail handling of
/// v1 `HotkeyManager`.
@MainActor
final class TBDHotkeyCoordinator {
    /// Cancels a scheduled timer.
    typealias Cancel = () -> Void
    /// Runs `work` after `milliseconds` on the main actor; a seam so tests control time.
    typealias Schedule = @MainActor (_ milliseconds: Int, _ work: @escaping @MainActor () -> Void) -> Cancel

    final class DictationEntry {
        let spec: TBDDictationHotkeyPlan.Spec
        var matcher: TBDDictationHotkeyMatcher
        var cancelStartup: Cancel?
        var cancelHold: Cancel?
        var cancelStopTail: Cancel?
        init(spec: TBDDictationHotkeyPlan.Spec, matcher: TBDDictationHotkeyMatcher) { self.spec = spec; self.matcher = matcher }
    }

    struct ShortcutEntry {
        let surface: TBDHotkeySurface
        var matcher: TBDShortcutMatcher
    }

    weak var targets: TBDHotkeyTargets?
    private let preferences: TBDListeningPreferences
    private let schedule: Schedule
    private let currentFlags: () -> UInt64
    private let physicalKeyState: (UInt16) -> Bool
    /// Called after the hotkey set changes, with whether any hotkey must swallow its key.
    var onChange: ((_ hasHotkeys: Bool, _ needsActiveTap: Bool) -> Void)?

    private(set) var dictationEntries: [DictationEntry] = []
    private(set) var shortcutEntries: [ShortcutEntry] = []
    private var activeSpec: TBDDictationHotkeyPlan.Spec?
    /// Open press-to-record recorders; while > 0 every global hotkey stands down.
    private(set) var suspendCount = 0
    private var migrated = false

    init(preferences: TBDListeningPreferences,
         schedule: @escaping Schedule = TBDHotkeyCoordinator.mainQueueSchedule,
         currentFlags: @escaping () -> UInt64 = { 0 },
         physicalKeyState: @escaping (UInt16) -> Bool = { _ in false }) {
        self.preferences = preferences
        self.schedule = schedule
        self.currentFlags = currentFlags
        self.physicalKeyState = physicalKeyState
    }

    static func mainQueueSchedule(_ milliseconds: Int, _ work: @escaping @MainActor () -> Void) -> Cancel {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: item)
        return { item.cancel() }
    }

    var hasHotkeys: Bool { !dictationEntries.isEmpty || !shortcutEntries.isEmpty }
    var needsActiveTap: Bool { !shortcutEntries.isEmpty || dictationEntries.contains { $0.matcher.needsActiveTap } }

    /// Menu title for the dictation keys (v1 `hotkeyMenuTitle`).
    var menuTitle: String {
        TBDDictationHotkeyPlan.menuTitle(handsFree: preferences.hotkey(for: .handsFree), pushToTalk: preferences.hotkey(for: .pushToTalk),
                                         aiPolish: preferences.hotkey(for: .dictationAIPolish), clipboard: preferences.hotkey(for: .dictationClipboard))
    }

    // MARK: Setup

    /// Rebuilds every hotkey from preferences (v1 `refreshAllHotkeys`). Skipped while a recorder is open.
    func refreshAll() {
        if !migrated { preferences.migrateDictationHotkeys(); migrated = true }
        guard suspendCount == 0 else { return }
        stopAll()
        setupAll()
    }

    func suspend() {
        suspendCount += 1
        if suspendCount == 1 { stopAll(); onChange?(false, false) }
    }

    func resume() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        if suspendCount == 0 { setupAll() }
    }

    func stopAll() {
        for entry in dictationEntries { cancelTimers(entry) }
        dictationEntries = []
        shortcutEntries = []
    }

    private func setupAll() {
        let snapshot = preferences.hotkeySnapshot
        setupDictation(snapshot)
        for surface in [TBDHotkeySurface.meeting, .fileTranscription, .urlTranscription] {
            guard let hotkey = snapshot.hotkey(for: surface) else { continue }
            let conflicts = TBDHotkeyConflictPolicy.conflictingHotkeys(for: hotkey, among: TBDHotkeyConflictPolicy.runtimePeers(of: surface, snapshot: snapshot))
            if !conflicts.isEmpty { reportConflict(hotkey, conflicts); continue }
            shortcutEntries.append(ShortcutEntry(surface: surface, matcher: TBDShortcutMatcher(hotkey: hotkey)))
        }
        // v1 TransformsCoordinator skips a transform shortcut that collides with a reserved hotkey.
        if let hotkey = snapshot.hotkey(for: .transform) {
            if let conflict = TBDHotkeyConflictPolicy.conflict(for: hotkey, surface: .transform, snapshot: snapshot) {
                reportConflict(hotkey, [conflict.hotkey])
            } else {
                shortcutEntries.append(ShortcutEntry(surface: .transform, matcher: TBDShortcutMatcher(hotkey: hotkey)))
            }
        }
        onChange?(hasHotkeys, needsActiveTap)
    }

    private func setupDictation(_ snapshot: TBDHotkeyConflictPolicy.Snapshot) {
        let plan = TBDDictationHotkeyPlan.make(handsFree: snapshot.handsFree, pushToTalk: snapshot.pushToTalk,
                                               aiPolish: snapshot.dictationAIPolish, clipboard: snapshot.dictationClipboard)
        if let conflict = plan.conflict { reportConflict(conflict.hotkey, conflict.conflicts) }
        let activeMode = targets?.hotkeyRecordingMode
        if activeMode == nil { activeSpec = nil }
        dictationEntries = plan.specs.map { spec in
            let gesture = TBDHotkeyGestureController(mode: spec.gestureMode, startupDebounceMs: spec.startupDebounceMs)
            var matcher = TBDDictationHotkeyMatcher(hotkey: spec.hotkey, gesture: gesture, physicalKeyState: physicalKeyState)
            let preferences = self.preferences
            matcher.escapeCancels = { preferences.escapeCancelsDictation }
            let entry = DictationEntry(spec: spec, matcher: matcher)
            let shouldResume = TBDDictationHotkeyPlan.shouldResume(spec, activeMode: activeMode, activeSpec: activeSpec)
            if shouldResume, let mode = TBDHotkeyGestureController.resumeMode(activeMode, for: spec.gestureMode) {
                entry.matcher.resumeRecording(mode: mode)
            } else if activeMode != nil {
                entry.matcher.suppressUntilReset()
            }
            return entry
        }
    }

    private func reportConflict(_ hotkey: TBDHotkey, _ conflicts: [TBDHotkey]) {
        let names = conflicts.map(\.formattedLabel).joined(separator: ", ")
        targets?.hotkeyReport("Hotkey \(hotkey.formattedLabel) is off: it conflicts with \(names). Change it in Settings > Capture.")
    }

    // MARK: Events

    /// One global key event. Returns true when the event must be swallowed.
    func handle(_ event: TBDKeyEvent) -> Bool {
        var swallow = false
        for entry in dictationEntries {
            let before = entry.matcher.activeRecordingMode
            let result = entry.matcher.handle(event)
            swallow = swallow || result.swallow
            apply(result.outputs, to: entry, modeBefore: before)
        }
        for index in shortcutEntries.indices {
            let result = shortcutEntries[index].matcher.handle(event)
            swallow = swallow || result.swallow
            if result.fired { fire(shortcutEntries[index].surface) }
        }
        return swallow
    }

    private func fire(_ surface: TBDHotkeySurface) {
        switch surface {
        case .meeting: targets?.hotkeyPerform(.meeting)
        case .fileTranscription: targets?.hotkeyPerform(.transcribeFile)
        case .urlTranscription: targets?.hotkeyPerform(.transcribeURL)
        case .transform: targets?.hotkeyRunTransform()
        default: break
        }
    }

    private func apply(_ outputs: [TBDDictationHotkeyMatcher.Output], to entry: DictationEntry, modeBefore: TBDFnKeyStateMachine.RecordingMode?) {
        for output in outputs {
            switch output {
            case .startRecording(let mode):
                entry.cancelStopTail?(); entry.cancelStopTail = nil
                start(entry, mode: mode)
            case .stopRecording:
                entry.cancelStopTail?(); entry.cancelStopTail = nil
                if modeBefore == .holdToTalk, entry.spec.holdToTalkStopTailMs > 0 {
                    // Keep the last syllable: push to talk stops a moment after release.
                    entry.cancelStopTail = schedule(entry.spec.holdToTalkStopTailMs) { [weak self, weak entry] in
                        entry?.cancelStopTail = nil
                        self?.stopTake()
                    }
                } else {
                    stopTake()
                }
            case .cancelRecording:
                entry.cancelStopTail?(); entry.cancelStopTail = nil
                activeSpec = nil
                targets?.hotkeyCancelDictation()
            case .discardRecording(let showReadyPill):
                entry.cancelStopTail?(); entry.cancelStopTail = nil
                activeSpec = nil
                targets?.hotkeyDiscardDictation(showReadyPill: showReadyPill)
            case .showReadyForSecondTap:
                targets?.hotkeyReadyForSecondTap()
            case .escapeWhileIdle:
                break
            case .scheduleStartupDebounce(let milliseconds):
                entry.cancelStartup?()
                entry.cancelStartup = schedule(milliseconds) { [weak self, weak entry] in
                    guard let self, let entry else { return }
                    entry.cancelStartup = nil
                    let before = entry.matcher.activeRecordingMode
                    self.apply(entry.matcher.startupDebounceElapsed(), to: entry, modeBefore: before)
                }
            case .scheduleHoldWindow(let milliseconds):
                entry.cancelHold?()
                entry.cancelHold = schedule(milliseconds) { [weak self, weak entry] in
                    guard let self, let entry else { return }
                    entry.cancelHold = nil
                    let before = entry.matcher.activeRecordingMode
                    self.apply(entry.matcher.holdWindowElapsed(), to: entry, modeBefore: before)
                }
            case .cancelStartupDebounce:
                entry.cancelStartup?(); entry.cancelStartup = nil
            case .cancelHoldWindow:
                entry.cancelHold?(); entry.cancelHold = nil
            }
        }
    }

    private func start(_ entry: DictationEntry, mode: TBDFnKeyStateMachine.RecordingMode) {
        let options = TBDDictationTakeOptions(aiPolish: entry.spec.aiPolish, clipboardOnly: entry.spec.clipboardOnly)
        guard targets?.hotkeyStartDictation(mode: mode, options: options) == true else {
            // A refused start must leave the next press able to start a take.
            entry.matcher.resetToIdle(flags: currentFlags())
            return
        }
        for other in dictationEntries where other !== entry { other.matcher.suppressUntilReset(); cancelTimers(other) }
        activeSpec = entry.spec
    }

    private func stopTake() {
        activeSpec = nil
        resetDictationGestures()
        targets?.hotkeyStopDictation()
    }

    private func cancelTimers(_ entry: DictationEntry) {
        entry.cancelStartup?(); entry.cancelStartup = nil
        entry.cancelHold?(); entry.cancelHold = nil
        entry.cancelStopTail?(); entry.cancelStopTail = nil
    }

    // MARK: Dictation flow hooks

    /// The take ended (or never started): every dictation hotkey returns to idle.
    func resetDictationGestures() {
        activeSpec = nil
        let flags = currentFlags()
        for entry in dictationEntries {
            entry.cancelStartup?(); entry.cancelStartup = nil
            entry.cancelHold?(); entry.cancelHold = nil
            entry.matcher.resetToIdle(flags: flags)
        }
    }

    /// Cancel from the pill: block every dictation hotkey until the flow resets them.
    func notifyCancelledByUI() {
        activeSpec = nil
        for entry in dictationEntries {
            entry.cancelStopTail?(); entry.cancelStopTail = nil
            entry.matcher.notifyCancelledByUI()
        }
    }

    /// A take started outside a hotkey (menu): hotkeys that can stop it take it over, the rest stand down.
    func syncRecordingMode(_ mode: TBDFnKeyStateMachine.RecordingMode) {
        for entry in dictationEntries {
            if TBDDictationHotkeyPlan.shouldResume(entry.spec, activeMode: mode, activeSpec: activeSpec) {
                entry.matcher.syncRecordingMode(mode)
            } else {
                entry.matcher.suppressUntilReset()
            }
        }
    }
}

extension TBDListeningContext: TBDHotkeyTargets {
    func hotkeyStartDictation(mode: TBDFnKeyStateMachine.RecordingMode, options: TBDDictationTakeOptions) -> Bool {
        dictation.hotkeyStart(mode: mode, options: options)
    }
    func hotkeyStopDictation() { dictation.finish() }
    func hotkeyCancelDictation() { dictation.cancel() }
    func hotkeyDiscardDictation(showReadyPill: Bool) { dictation.hotkeyDiscard(showReadyPill: showReadyPill) }
    func hotkeyReadyForSecondTap() { dictation.showReadyForSecondTap() }
    func hotkeyPerform(_ action: TBDListeningAction) { perform(action) }
    func hotkeyRunTransform() { transforms.run() }
    func hotkeyReport(_ message: String) { report(message) }
    var hotkeyRecordingMode: TBDFnKeyStateMachine.RecordingMode? { dictation.recordingMode }
}
