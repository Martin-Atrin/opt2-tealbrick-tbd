import AppKit
import TBDSpeech

/// Runs the retention sweep at launch, once a day while running, and right after a policy change.
/// Also owns "Delete all Listening data".
@MainActor
final class TBDRetentionController: ObservableObject {
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var lastResult: TBDRetentionSweeper.Result?
    @Published private(set) var sweeping = false
    var onMessage: ((String) -> Void)?

    private let env: TBDListeningEnvironment
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = 0

    init(env: TBDListeningEnvironment) { self.env = env }

    func start() {
        sweep(force: false)
        timer?.invalidate()
        // Checks hourly; the 24-hour throttle decides when a sweep actually runs.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep(force: false) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
    }

    /// Changes one kind's policy. Entering a mode that deletes data asks first, every time.
    func set(_ policy: TBDRetentionPolicy, for kind: TBDRetentionKind) {
        var settings = env.preferences.retention
        let old = settings[kind]
        guard old != policy else { return }
        let modeChanged = old.mode != policy.mode
        if modeChanged, let message = policy.confirmation(for: kind) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = policy.mode == .deleteAudioAfterTranscription ? "Stop keeping audio?" : "Delete automatically?"
            alert.informativeText = message
            alert.addButton(withTitle: policy.mode == .deleteAudioAfterTranscription ? "Stop keeping audio" : "Turn on deletion")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        settings[kind] = policy
        env.preferences.retention = settings
        objectWillChange.send()
        if policy.mode == .deleteAfterDays { sweep(force: true) }
    }

    func sweep(force: Bool) {
        let prefs = env.preferences
        let settings = prefs.retention
        guard settings.sweeps, let database = env.database else { return }
        if !force, let last = prefs.lastRetentionSweep, Date().timeIntervalSince(last) < Self.minimumInterval { return }
        if force { task?.cancel() } else if task != nil { return }
        generation += 1
        let current = generation
        sweeping = true
        task = Task.detached(priority: .utility) { [weak self] in
            let outcome = Result(catching: { try TBDRetentionSweeper(database: database).sweep(settings) })
            await self?.finish(outcome, generation: current)
        }
    }

    private func finish(_ outcome: Result<TBDRetentionSweeper.Result, Error>, generation: Int) {
        guard generation == self.generation else { return }
        task = nil
        sweeping = false
        switch outcome {
        case .success(let result):
            lastResult = result
            // A partial failure makes the next trigger due again.
            env.preferences.lastRetentionSweep = result.failed == 0 ? Date() : nil
            if result.changed { env.changed() }
        case .failure(let error):
            env.preferences.lastRetentionSweep = nil
            onMessage?("Retention cleanup failed: \(error.localizedDescription)")
        }
    }

    // MARK: Delete all

    /// Deletes every dictation, voice note, meeting and transcription with its audio, after confirming.
    /// Settings, vocabulary, snippets and speech models stay.
    func deleteAll(context: TBDListeningContext) {
        if context.isCapturing || context.files.isBusy || context.meetings.finalizingStage != nil {
            let alert = NSAlert()
            alert.messageText = "Listening is busy"
            alert.informativeText = "Stop recording and wait for transcriptions to finish, then try again."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete all Listening data?"
        alert.informativeText = "This permanently deletes every dictation, voice note, meeting, transcript, note, answer and saved audio file. Settings, vocabulary, snippets and speech models stay. This cannot be undone."
        alert.addButton(withTitle: "Delete everything")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try env.database?.deleteAllListeningData()
            for folder in [TBDListeningPaths.dictations, TBDListeningPaths.voiceNotes, TBDListeningPaths.meetings,
                           TBDListeningPaths.downloads, TBDListeningPaths.temporary] {
                try? FileManager.default.removeItem(at: folder)
            }
            env.selectedTranscriptionID = nil
            env.changed()
            onMessage?("All Listening data was deleted")
        } catch {
            onMessage?("Could not delete Listening data: \(error.localizedDescription)")
        }
    }
}
