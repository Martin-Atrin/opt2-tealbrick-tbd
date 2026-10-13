import AppKit
import TBDSpeech

/// Owns the Listening controllers and wires hotkeys and menu actions to them.
@MainActor
final class TBDListeningContext {
    let env = TBDListeningEnvironment()
    let dictation: TBDDictationController
    let voice: TBDVoiceCapture
    let meetings: TBDMeetingController
    let files: TBDFileQueue
    let transforms: TBDTransformController
    let retention: TBDRetentionController
    private let hotkeys = TBDHotkeyMonitor()
    let hotkeyCoordinator: TBDHotkeyCoordinator
    private weak var runtime: TBDListeningRuntime?
    private(set) var hotkeysActive = false

    init(runtime: TBDListeningRuntime) {
        self.runtime = runtime
        dictation = TBDDictationController(env: env)
        voice = TBDVoiceCapture(env: env)
        meetings = TBDMeetingController(env: env)
        files = TBDFileQueue(env: env)
        transforms = TBDTransformController(env: env)
        retention = TBDRetentionController(env: env)
        hotkeyCoordinator = TBDHotkeyCoordinator(preferences: env.preferences, currentFlags: { TBDHotkeyMonitor.currentFlags },
                                                 physicalKeyState: TBDHotkeyMonitor.keyIsDown)
        let report: (String) -> Void = { [weak runtime] in runtime?.report($0) }
        meetings.onMessage = report
        files.onMessage = report
        transforms.onMessage = report
        retention.onMessage = report
        hotkeys.onStatusChange = { [weak self] in self?.hotkeysActive = $0 }
        wireHotkeys()
    }

    var isCapturing: Bool { dictation.isRecording || voice.chatActive || voice.noteRecording || meetings.isRecording }

    func start() {
        reloadHotkeys()
        meetings.start()
        retention.start()
        if let database = env.database {
            // One-time import of the earlier version's library, off the main thread.
            Task { [weak self] in
                let outcome = await Task.detached(priority: .utility) { TBDLegacyImport.runAtStart(into: database) }.value
                if outcome.changed { self?.env.changed() }
                if let message = outcome.message { self?.runtime?.report(message) }
            }
        }
        Task { await env.speech.warmUp() }
    }

    func stop() {
        hotkeys.stop()
        retention.stop()
        dictation.cancel()
        meetings.shutdown()
        files.cancelAll()
        Task { await env.speech.shutdown() }
    }

    /// Re-reads hotkey preferences (TBDHotkeyCoordinator). Invalid strings disable that hotkey.
    func reloadHotkeys() { hotkeyCoordinator.refreshAll() }

    private func wireHotkeys() {
        hotkeyCoordinator.targets = self
        hotkeyCoordinator.onChange = { [weak self] hasHotkeys, activeTap in
            guard let self else { return }
            self.hotkeys.set(activeTap: activeTap, handler: hasHotkeys ? { [weak self] in self?.hotkeyCoordinator.handle($0) ?? false } : nil)
        }
        dictation.onHotkeysReset = { [weak self] in self?.hotkeyCoordinator.resetDictationGestures() }
        dictation.onCancelledByUI = { [weak self] in self?.hotkeyCoordinator.notifyCancelledByUI() }
        dictation.onStartedOutsideHotkey = { [weak self] in self?.hotkeyCoordinator.syncRecordingMode($0) }
    }

    func report(_ message: String) { runtime?.report(message) }

    var hotkeyPermissionMissing: Bool { !hotkeys.isActive }

    func perform(_ action: TBDListeningAction) {
        switch action.effect {
        case .toggleDictation: dictation.toggle()
        case .toggleMeeting: meetings.toggle()
        case .pickFiles: show(.library); files.pickFiles()
        case .promptForURL: show(.library); files.promptForURL()
        case .chooseTransform: transforms.chooseAndRun()
        case .show(let page): show(TBDListeningTab(rawValue: page) ?? .library)
        }
    }

    private func show(_ tab: TBDListeningTab) {
        env.selectedTab = tab
        runtime?.bringToFront()
    }

    func bringToFront() { runtime?.bringToFront() }
}
