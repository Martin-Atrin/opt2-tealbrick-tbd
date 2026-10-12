import AppKit
import TBDSpeech

/// Hotkey dictation: record → transcribe (interactive lane) → text pipeline → optional cleanup →
/// paste into the frontmost app → history.
@MainActor
final class TBDDictationController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published var lastMessage = ""

    private let env: TBDListeningEnvironment
    private var gesture = TBDHotkeyGesture()
    private var recorder: TBDAudioRecorder?
    private var armWork: DispatchWorkItem?
    private var levelTimer: Timer?
    private var targetApp: NSRunningApplication?
    private var processing: Task<Void, Never>?
    private var starting: Task<Void, Never>?
    private var hotkeyHeld = false
    private var undo = TBDCancelUndo()
    private var undoTimer: Timer?
    private var undoTarget: NSRunningApplication?

    init(env: TBDListeningEnvironment) {
        self.env = env
        env.overlay.model.onStop = { [weak self] in self?.finish() }
        env.overlay.model.onCancel = { [weak self] in self?.cancel() }
        env.overlay.model.onUndo = { [weak self] in self?.undoCancel() }
    }

    /// A cancelled take that Undo can still bring back.
    var undoPending: Bool { undo.pending != nil }

    var isBusy: Bool { isRecording || isProcessing }

    // MARK: Hotkey

    func handle(_ event: TBDHotkeyMonitor.Event, at ms: UInt64) {
        switch event {
        case .down:
            hotkeyHeld = true
            perform(gesture.press(at: ms))
            if gesture.state == .pending {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.perform(self.gesture.armed())
                }
                armWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
        case .up:
            hotkeyHeld = false
            armWork?.cancel()
            perform(gesture.release(at: ms))
        case .otherKey:
            armWork?.cancel()
            perform(gesture.otherKey())
        case .escape:
            perform(gesture.escape(keyHeld: hotkeyHeld))
        }
    }

    private func perform(_ action: TBDHotkeyGesture.Action) {
        switch action {
        case .none: break
        case .start: begin(handsFree: false)
        case .startHandsFree: begin(handsFree: true)
        case .handsFree: env.overlay.show(.recording(handsFree: true))
        case .stop: finish()
        case .cancel: cancel()
        }
    }

    /// Menu action: start hands-free, or stop and paste.
    func toggle() {
        if isRecording { finish() } else if !isProcessing { gesture.reset(); _ = gesture.press(at: 0); _ = gesture.release(at: 0); begin(handsFree: true) }
    }

    // MARK: Recording

    private func begin(handsFree: Bool) {
        guard recorder == nil, !isProcessing else { gesture.reset(keyHeld: hotkeyHeld); return }
        discardUndo()
        targetApp = NSWorkspace.shared.frontmostApplication
        let recorder = TBDAudioRecorder(microphone: env.microphone)
        self.recorder = recorder
        isRecording = true
        env.overlay.show(.recording(handsFree: handsFree))
        starting = Task {
            defer { starting = nil }
            do {
                try await recorder.start()
                // finish() and cancel() wait for this task, so only the live UI is started here.
                if self.recorder === recorder { startLevelTimer(recorder) }
            } catch {
                if self.recorder === recorder { self.recorder = nil; isRecording = false }
                gesture.reset(keyHeld: hotkeyHeld)
                show(error.localizedDescription)
            }
        }
    }

    private func startLevelTimer(_ recorder: TBDAudioRecorder) {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.env.overlay.update(levels: recorder.recentLevels, elapsedMs: recorder.elapsedMs)
                // Microphone lost or disk full: keep what was said.
                if recorder.interrupted, self.recorder === recorder { self.finish() }
            }
        }
    }

    /// Cancels recording. With an undo window, the take is kept briefly and the pill offers Undo.
    func cancel() {
        levelTimer?.invalidate()
        gesture.reset(keyHeld: hotkeyHeld)
        processing?.cancel()
        guard let recorder else {
            if undoPending { discardUndo(); env.overlay.hide() } else if isProcessing { env.overlay.hide() }
            return
        }
        self.recorder = nil
        isRecording = false
        let startup = starting
        let window = env.preferences.dictationUndoWindow
        guard window != .off else {
            env.overlay.hide()
            Task {
                await startup?.value
                await recorder.cancel()
            }
            return
        }
        undoTarget = targetApp
        Task {
            await startup?.value
            guard let recording = try? await recorder.stop(), recording.durationMs >= 250 else {
                env.overlay.hide()
                return
            }
            let held = undo.hold(recording.url, durationMs: recording.durationMs, window: window)
            if let old = held.discard { try? FileManager.default.removeItem(at: old) }
            guard held.accepted, let pending = undo.pending else { try? FileManager.default.removeItem(at: recording.url); return }
            env.overlay.show(.undo(remaining: pending.remaining, total: pending.total))
            undoTimer?.invalidate()
            let generation = pending.generation
            undoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    if let expired = self.undo.tick(generation: generation) {
                        timer.invalidate()
                        try? FileManager.default.removeItem(at: expired)
                        if case .undo = self.env.overlay.model.phase { self.env.overlay.hide() }
                    } else if let pending = self.undo.pending {
                        self.env.overlay.show(.undo(remaining: pending.remaining, total: pending.total))
                    }
                }
            }
        }
    }

    /// Brings back the cancelled take: transcribe and paste as if it had been stopped.
    func undoCancel() {
        undoTimer?.invalidate()
        guard let pending = undo.undo(), !isProcessing, recorder == nil else { discardUndo(); return }
        isProcessing = true
        env.overlay.show(.processing("Transcribing…"))
        let target = undoTarget
        processing = Task {
            defer { isProcessing = false; processing = nil }
            do {
                try await transcribeAndPaste(url: pending.url, durationMs: pending.durationMs, warning: nil, target: target)
            } catch is CancellationError {
                env.overlay.hide()
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    /// Ends the undo window now and deletes the held take.
    private func discardUndo() {
        undoTimer?.invalidate()
        if let url = undo.discard() { try? FileManager.default.removeItem(at: url) }
    }

    func finish() {
        levelTimer?.invalidate()
        gesture.reset(keyHeld: hotkeyHeld)
        guard let recorder else { return }
        self.recorder = nil
        isRecording = false
        isProcessing = true
        env.overlay.show(.processing("Transcribing…"))
        let target = targetApp
        let startup = starting
        processing = Task {
            defer { isProcessing = false; processing = nil }
            do {
                await startup?.value
                let recording = try await recorder.stop()
                guard recording.durationMs >= 250 else {
                    try? FileManager.default.removeItem(at: recording.url)
                    env.overlay.hide()
                    return
                }
                try await transcribeAndPaste(url: recording.url, durationMs: recording.durationMs, warning: recording.warning, target: target)
            } catch is CancellationError {
                env.overlay.hide()
            } catch TBDSpeechError.audioUnreadable("not recording") {
                env.overlay.hide()   // The microphone never started; the start error is already shown.
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func transcribeAndPaste(url: URL, durationMs: Int, warning: String?, target: NSRunningApplication?) async throws {
        let prefs = env.preferences
        let transcript: TBDTranscript
        do {
            let samples = try TBDAudioDecoder.samples(from: url)
            transcript = try await env.speech.transcribe(samples: samples, kind: .dictation)
        } catch {
            // Keep the audio so nothing said is lost.
            _ = try? env.keep(url, in: TBDListeningPaths.dictations, name: "failed-\(tbdNewID()).wav")
            throw error
        }
        let raw = transcript.trimmedText
        guard !raw.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            show("No speech detected")
            return
        }
        let words = (try? env.database?.customWords()) ?? []
        let snippets = (try? env.database?.snippets()) ?? []
        let processed = TBDTextPipeline().process(raw, customWords: words, snippets: snippets, removeFillers: prefs.removeFillers)
        try? env.database?.incrementSnippetUse(ids: processed.expandedSnippetIDs)
        var text = processed.text
        if prefs.dictationCleanup {
            env.overlay.show(.processing("Cleaning up…"))
            let cleaned = try await TBDCleanup.apply(raw: text, enabled: true, formatter: TBDCleanup.modelFormatter(prompt: prefs.cleanupPrompt))
            text = cleaned.text
            if !cleaned.warning.isEmpty { lastMessage = cleaned.warning }
        }
        try Task.checkCancellation()
        var pasteError: Error?
        do { try TBDPasteService.paste(text) } catch { pasteError = error }
        let id = tbdNewID()
        let audio = prefs.keepsAudio(.dictations) ? try? env.keep(url, in: TBDListeningPaths.dictations, name: id + ".wav") : nil
        if audio == nil { try? FileManager.default.removeItem(at: url) }
        if prefs.keepHistory {
            try? env.database?.save(TBDDictation(id: id, durationMs: durationMs, rawText: raw, cleanText: text == raw ? nil : text,
                                                 targetApp: target?.localizedName, audioPath: audio?.path, engine: transcript.engine))
            env.changed()
        }
        if let pasteError { show(pasteError.localizedDescription) }
        else if let warning { show(warning) }
        else { env.overlay.hide() }
    }

    private func show(_ message: String) {
        lastMessage = message
        env.overlay.show(.message(message))
    }
}
