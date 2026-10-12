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
        let report: (String) -> Void = { [weak runtime] in runtime?.report($0) }
        meetings.onMessage = report
        files.onMessage = report
        transforms.onMessage = report
        retention.onMessage = report
        hotkeys.onStatusChange = { [weak self] in self?.hotkeysActive = $0 }
    }

    var isCapturing: Bool { dictation.isRecording || voice.chatActive || voice.noteRecording || meetings.isRecording }

    func start() {
        reloadHotkeys()
        meetings.start()
        retention.start()
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

    /// Re-reads hotkey preferences. Invalid strings disable that hotkey.
    func reloadHotkeys() {
        var bindings: [TBDHotkeyMonitor.Binding] = []
        if let hotkey = try? TBDHotkey.parse(env.preferences.dictationHotkey) {
            bindings.append(.init(hotkey: hotkey) { [weak self] event, ms in self?.dictation.handle(event, at: ms) })
        }
        if !env.preferences.transformHotkey.isEmpty, let hotkey = try? TBDHotkey.parse(env.preferences.transformHotkey) {
            bindings.append(.init(hotkey: hotkey) { [weak self] event, _ in if event == .down { self?.transforms.run() } })
        }
        hotkeys.set(bindings)
    }

    var hotkeyPermissionMissing: Bool { !hotkeys.isActive }

    func perform(_ action: String) {
        switch action {
        case "dictation": dictation.toggle()
        case "meeting": meetings.toggle()
        case "transcribeFile": files.pickFiles()
        case "transcribeURL": files.promptForURL()
        case "transform": transforms.chooseAndRun()
        case "openLibrary":
            env.selectedTab = .library
            runtime?.bringToFront()
        default: runtime?.report("Unknown Listening action")
        }
    }

    func bringToFront() { runtime?.bringToFront() }
}
