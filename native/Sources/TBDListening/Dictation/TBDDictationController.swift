import AppKit
import TBDSpeech

/// Hotkey dictation: record → transcribe (interactive lane) → text pipeline → optional cleanup →
/// paste into the frontmost app → history.
@MainActor
final class TBDDictationController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published var lastMessage = ""
    /// Display-only text while recording (engines with live preview); empty otherwise.
    @Published private(set) var livePartial = ""

    private let env: TBDListeningEnvironment
    private var recorder: TBDAudioRecorder?
    private var levelTimer: Timer?
    private var targetApp: NSRunningApplication?
    private var processing: Task<Void, Never>?
    private var starting: Task<Void, Never>?
    private var preview: TBDLivePreview?
    private var undo = TBDCancelUndo()
    private var undoTimer: Timer?
    private var undoTarget: NSRunningApplication?
    private let warm = TBDWarmCapture()
    private let media = TBDDictationMedia()
    private let streamer = TBDStreamingInserter()
    private var silence: TBDSilenceAutoStop?
    private var captureOpen = false
    private var cueOwed = false
    /// Set by the context: media is not paused while a meeting records.
    var isMeetingRecording: () -> Bool = { false }

    /// Set by the hotkey that started the take (clipboard-only, AI polish).
    private var takeOptions = TBDDictationTakeOptions()
    private var takeMode: TBDFnKeyStateMachine.RecordingMode?
    /// Final step seam (paste or copy, optional cleanup); tests replace it.
    var delivery: TBDDictationDelivery?

    // Hotkey coordinator hooks (v1 AppHotkeyCoordinator / DictationFlowCoordinator wiring).
    /// The take is over: every dictation hotkey returns to idle.
    var onHotkeysReset: (() -> Void)?
    /// Cancel came from the pill: dictation hotkeys stay blocked until the undo window ends.
    var onCancelledByUI: (() -> Void)?
    /// A take started from the menu: hotkeys that can stop it take it over.
    var onStartedOutsideHotkey: ((TBDFnKeyStateMachine.RecordingMode) -> Void)?

    init(env: TBDListeningEnvironment) {
        self.env = env
        env.overlay.model.onStop = { [weak self] in self?.finish() }
        env.overlay.model.onCancel = { [weak self] in self?.onCancelledByUI?(); self?.cancel() }
        env.overlay.model.onUndo = { [weak self] in self?.undoCancel() }
        env.overlay.onIdleClick = { [weak self] in self?.toggle() }
    }

    /// Applies the dictation behaviour settings that act outside a take: idle pill, placement, warm microphone.
    func settingsChanged() {
        env.overlay.settingsChanged()
        let prefs = env.preferences
        Task { await warm.configure(enabled: prefs.instantDictationEnabled, preferredUID: prefs.microphoneUID) }
    }

    func shutdown() {
        Task {
            await media.resume()
            await warm.release()
        }
    }

    /// A cancelled take that Undo can still bring back.
    var undoPending: Bool { undo.pending != nil }

    var isBusy: Bool { isRecording || isProcessing }

    // MARK: Hotkey

    /// Recording mode of the live take, for hotkey reloads (v1 `dictationRecordingModeProvider`).
    var recordingMode: TBDFnKeyStateMachine.RecordingMode? { isRecording ? takeMode : nil }

    /// A dictation hotkey asks to start. Refused while a take is recording or being processed.
    func hotkeyStart(mode: TBDFnKeyStateMachine.RecordingMode, options: TBDDictationTakeOptions) -> Bool {
        guard recorder == nil, !isProcessing else { return false }
        begin(mode: mode, options: options)
        return true
    }

    /// A provisional push-to-talk take ended as a quick tap: drop it without a trace.
    func hotkeyDiscard(showReadyPill: Bool) {
        levelTimer?.invalidate()
        let preview = takePreview()
        Task { await preview?.stop() }
        guard let recorder else { if showReadyPill { showReadyForSecondTap() }; return }
        self.recorder = nil
        isRecording = false
        takeMode = nil
        let startup = starting
        Task {
            await startup?.value
            await recorder.cancel()
        }
        if showReadyPill { showReadyForSecondTap() } else { env.overlay.hide() }
    }

    /// v1 "ready" pill after the first tap of a double-tap.
    func showReadyForSecondTap() {
        guard recorder == nil, !isProcessing else { return }
        env.overlay.show(.message("Tap again for hands-free"))
        env.overlay.hide(after: Double(TBDFnKeyStateMachine.defaultTapThresholdMs) / 1000)
    }

    /// Menu action: start hands-free, or stop and paste.
    func toggle() {
        if isRecording { finish() } else if !isProcessing && recorder == nil {
            begin(mode: .persistent, options: TBDDictationTakeOptions())
            onStartedOutsideHotkey?(.persistent)
        }
    }

    // MARK: Recording

    private func begin(mode: TBDFnKeyStateMachine.RecordingMode, options: TBDDictationTakeOptions) {
        guard recorder == nil, !isProcessing else { onHotkeysReset?(); return }
        let handsFree = mode == .persistent
        takeMode = mode
        takeOptions = options
        discardUndo(resetHotkeys: false)
        targetApp = NSWorkspace.shared.frontmostApplication
        let prefs = env.preferences
        let recorder = TBDAudioRecorder(microphone: env.microphone)
        self.recorder = recorder
        isRecording = true
        captureOpen = true
        // Pausing runs beside capture start. When media was playing, the pre-roll holds its sound and is cut.
        media.requestPause(enabled: prefs.pauseMediaDuringDictation, meetingActive: isMeetingRecording()) { [weak self] in
            self?.recorder?.discardPreRoll()
        }
        let preRoll = prefs.instantDictationEnabled ? warm.takePreRoll() : []
        // The preview buffers samples from the first one while the live engine attaches.
        let preview = env.preferences.dictationLivePreview ? TBDLivePreview { [weak self] text in self?.showPartial(text) } : nil
        if let preview { recorder.sampleSink = { preview.append($0) } }
        self.preview = preview
        livePartial = ""
        env.overlay.show(.recording(handsFree: handsFree))
        starting = Task {
            defer { starting = nil }
            do {
                try await recorder.start(preRoll: preRoll)
                // finish() and cancel() wait for this task, so only the live UI is started here.
                if self.recorder === recorder {
                    if prefs.playDictationCaptureSounds { cueOwed = true; TBDSounds.shared.play(.recordStart) }
                    silence = prefs.silenceAutoStop ? TBDSilenceAutoStop(delay: prefs.silenceDelay, start: ProcessInfo.processInfo.systemUptime) : nil
                    startLevelTimer(recorder)
                    if let preview { await env.speech.startLivePreview(preview) }
                }
            } catch {
                if self.recorder === recorder {
                    self.recorder = nil; isRecording = false
                    await takePreview()?.stop()
                }
                captureEnded()
                onHotkeysReset?()
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
                // Auto-stop after silence: the same path as pressing the stop button.
                if var quiet = self.silence, self.recorder === recorder {
                    let stop = quiet.feed(level: recorder.audioLevel, at: ProcessInfo.processInfo.systemUptime)
                    self.silence = quiet
                    if stop { self.finish() }
                }
            }
        }
    }

    /// Shows a partial while still recording.
    private func showPartial(_ text: String) {
        guard isRecording else { return }
        livePartial = text
        env.overlay.update(partial: text)
    }

    /// Detaches the live preview; the caller awaits the result before the final pass.
    private func takePreview() -> TBDLivePreview? {
        defer { preview = nil }
        livePartial = ""
        env.overlay.update(partial: "")
        return preview
    }

    /// The microphone is closed: stop cue, resume paused media, let the warm microphone collect again. Runs once per take.
    private func captureEnded() {
        silence = nil
        guard captureOpen else { return }
        captureOpen = false
        if cueOwed { cueOwed = false; TBDSounds.shared.play(.recordStop) }
        warm.resumeCollecting()
        Task { await media.resume() }
    }

    /// Cancels recording. With an undo window, the take is kept briefly and the pill offers Undo.
    func cancel() {
        levelTimer?.invalidate()
        processing?.cancel()
        let preview = takePreview()
        Task { await preview?.stop() }
        guard let recorder else {
            if undoPending { discardUndo(); env.overlay.hide() } else if isProcessing { env.overlay.hide() }
            onHotkeysReset?()
            return
        }
        self.recorder = nil
        isRecording = false
        takeMode = nil
        let startup = starting
        let window = env.preferences.dictationUndoWindow
        let target = targetApp
        let keepDiscarded = TBDDiscardedDictation.shouldKeep(preserve: env.preferences.preserveDiscardedDictations, keepHistory: env.preferences.keepHistory)
        guard window != .off else {
            onHotkeysReset?()
            env.overlay.hide()
            Task {
                await startup?.value
                if keepDiscarded, let recording = try? await recorder.stop() {
                    captureEnded()
                    dispose(recording.url, durationMs: recording.durationMs, target: target)
                } else {
                    await recorder.cancel()
                    captureEnded()
                }
            }
            return
        }
        undoTarget = targetApp
        Task {
            await startup?.value
            guard let recording = try? await recorder.stop() else { captureEnded(); env.overlay.hide(); onHotkeysReset?(); return }
            captureEnded()
            // Too short to matter, or a new dictation already started: nothing to bring back.
            guard recording.durationMs >= 250, self.recorder == nil, !isProcessing else {
                try? FileManager.default.removeItem(at: recording.url)
                if self.recorder == nil, !isProcessing { env.overlay.hide(); onHotkeysReset?() }
                return
            }
            let before = undo.pending
            let held = undo.hold(recording.url, durationMs: recording.durationMs, window: window)
            if let old = held.discard { dispose(old, durationMs: before?.durationMs ?? 0, target: undoTarget) }
            guard held.accepted, let pending = undo.pending else { try? FileManager.default.removeItem(at: recording.url); onHotkeysReset?(); return }
            env.overlay.show(.undo(remaining: pending.remaining, total: pending.total))
            undoTimer?.invalidate()
            let generation = pending.generation
            undoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    if let expired = self.undo.tick(generation: generation) {
                        timer.invalidate()
                        self.dispose(expired, durationMs: pending.durationMs, target: self.undoTarget)
                        self.onHotkeysReset?()
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
        onHotkeysReset?()
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
    private func discardUndo(resetHotkeys: Bool = true) {
        undoTimer?.invalidate()
        let ms = undo.pending?.durationMs ?? 0
        if let url = undo.discard() {
            dispose(url, durationMs: ms, target: undoTarget)
            if resetHotkeys { onHotkeysReset?() }
        }
    }

    /// A discarded take: deleted, or with "Preserve discarded dictations" transcribed into History (not pasted).
    private func dispose(_ url: URL, durationMs: Int, target: NSRunningApplication?) {
        let prefs = env.preferences
        guard TBDDiscardedDictation.shouldKeep(preserve: prefs.preserveDiscardedDictations, keepHistory: prefs.keepHistory) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        Task { await preserveDiscarded(url, durationMs: durationMs, target: target) }
    }

    private func preserveDiscarded(_ url: URL, durationMs: Int, target: NSRunningApplication?) async {
        let prefs = env.preferences
        do {
            let samples = try TBDAudioDecoder.samples(from: url)
            let transcript = try await env.speech.transcribe(samples: samples, kind: .dictation)
            let raw = transcript.trimmedText
            guard !raw.isEmpty else { try? FileManager.default.removeItem(at: url); return }
            let rendered = render(raw)
            let id = tbdNewID()
            let audio = prefs.keepsAudio(.dictations) ? try? env.keep(url, in: TBDListeningPaths.dictations, name: id + ".wav") : nil
            if audio == nil { try? FileManager.default.removeItem(at: url) }
            try env.database?.save(TBDDiscardedDictation.record(id: id, durationMs: durationMs, rawText: raw, cleanText: rendered.text == raw ? nil : rendered.text,
                                                                engine: transcript.engine, audioPath: audio?.path, targetApp: target?.localizedName))
            env.changed()
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func finish() {
        levelTimer?.invalidate()
        onHotkeysReset?()
        guard let recorder else { return }
        self.recorder = nil
        isRecording = false
        takeMode = nil
        isProcessing = true
        env.overlay.show(.processing("Transcribing…"))
        let target = targetApp
        let startup = starting
        let preview = takePreview()
        let options = takeOptions
        processing = Task {
            defer { isProcessing = false; processing = nil; captureEnded() }
            do {
                await startup?.value
                let recording = try await recorder.stop()
                captureEnded()
                // Free the live engine's interactive lane before the final pass.
                await preview?.stop()
                guard recording.durationMs >= 250 else {
                    try? FileManager.default.removeItem(at: recording.url)
                    env.overlay.hide()
                    return
                }
                try await transcribeAndPaste(url: recording.url, durationMs: recording.durationMs, warning: recording.warning, target: target, options: options)
            } catch is CancellationError {
                env.overlay.hide()
            } catch TBDSpeechError.audioUnreadable("not recording") {
                env.overlay.hide()   // The microphone never started; the start error is already shown.
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func transcribeAndPaste(url: URL, durationMs: Int, warning: String?, target: NSRunningApplication?,
                                    options: TBDDictationTakeOptions = TBDDictationTakeOptions()) async throws {
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
        let (processed, protected) = runPipeline(raw)
        try? env.database?.incrementSnippetUse(ids: processed.expandedSnippetIDs)
        if TBDDictationDelivery.usesCleanup(options, cleanupSetting: prefs.dictationCleanup) {
            env.overlay.show(.processing("Cleaning up…"))
        }
        try Task.checkCancellation()
        let delivery = self.delivery ?? TBDDictationDelivery(
            paste: { [weak self] in try await self?.insert($0, pressReturn: processed.pressReturn) },
            copy: { TBDPasteService.copy($0) },
            cleanup: TBDCleanup.modelFormatter(prompt: prefs.cleanupPrompt),
            finish: { prefs.dictationInsertionStyle.apply(to: $0, protectedLeadingTerms: protected) })
        let outcome = try await delivery.deliver(processed.text, options: options, cleanupSetting: prefs.dictationCleanup)
        let text = outcome.text
        if !outcome.cleanupWarning.isEmpty { lastMessage = outcome.cleanupWarning }
        let id = tbdNewID()
        let audio = prefs.keepsAudio(.dictations) ? try? env.keep(url, in: TBDListeningPaths.dictations, name: id + ".wav") : nil
        if audio == nil { try? FileManager.default.removeItem(at: url) }
        if prefs.keepHistory {
            try? env.database?.save(TBDDictation(id: id, durationMs: durationMs, rawText: raw, cleanText: text == raw ? nil : text,
                                                 targetApp: target?.localizedName, audioPath: audio?.path, engine: transcript.engine))
            env.changed()
        }
        if let pasteError = outcome.error { show(pasteError) }
        else if let warning { show(warning) }
        else if outcome.destination == .copied { show("Copied to the clipboard") }
        else { env.overlay.hide() }
    }

    /// Text pipeline with the voice-return phrases, plus the vocabulary terms whose capitals inline style must keep.
    private func runPipeline(_ raw: String) -> (TBDTextPipeline.Result, [String]) {
        let prefs = env.preferences
        let words = (try? env.database?.customWords()) ?? []
        let snippets = (try? env.database?.snippets()) ?? []
        let result = TBDTextPipeline().process(raw, customWords: words, snippets: snippets, removeFillers: prefs.removeFillers,
                                               mode: prefs.processingMode, spokenPunctuation: prefs.spokenPunctuation,
                                               voiceReturnTriggers: TBDTextPipeline.returnTriggers(voiceReturn: prefs.voiceReturnEnabled ? prefs.voiceReturnTriggers : [], snippets: snippets))
        let protected = TBDInsertionStyle.protectedLeadingTerms(customWords: words, snippets: snippets, expandedSnippetIDs: result.expandedSnippetIDs)
        return (result, protected)
    }

    /// Final text without cleanup or paste (a discarded take kept in History).
    private func render(_ raw: String) -> (text: String, pressReturn: Bool) {
        let (processed, protected) = runPipeline(raw)
        return (env.preferences.dictationInsertionStyle.apply(to: processed.text, protectedLeadingTerms: protected), processed.pressReturn)
    }

    /// Types or pastes the finished text. Streaming cursor types it when allowed; everything else pastes.
    /// Empty text with a voice-return phrase only presses Return.
    private func insert(_ text: String, pressReturn: Bool) async throws {
        let prefs = env.preferences
        let insertion = prefs.dictationInsertionStyle.insertionText(text, hasAction: pressReturn)
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText, prefs.dictationStreamingCursorEnabled, TBDStreamingInserter.allowed(), TBDStreamingCursor.isStreamable(insertion) {
            do {
                try await streamer.insert(insertion)
                if prefs.keepDictationOnClipboard { TBDPasteService.copy(insertion) }
                if pressReturn {
                    try? await Task.sleep(for: .milliseconds(200))
                    do { try await TBDClipboardPaster.system.insert("", keepOnClipboard: true, pressReturn: true) } catch { throw TBDStreamingError.partialInsert }
                }
                return
            } catch TBDStreamingError.unavailable {
                // Typing is not possible here; paste instead.
            } catch TBDStreamingError.partialInsert {
                TBDPasteService.copy(insertion)
                throw TBDStreamingPartialError()
            }
        }
        try await TBDClipboardPaster.system.insert(hasText ? insertion : "", keepOnClipboard: prefs.keepDictationOnClipboard, pressReturn: pressReturn)
    }

    private func show(_ message: String) {
        lastMessage = message
        env.overlay.show(.message(message))
    }
}

/// Streaming typed only part of the text; the whole text is on the clipboard.
struct TBDStreamingPartialError: LocalizedError {
    var errorDescription: String? { "Part of the text was typed, then typing stopped. The whole text is on the clipboard." }
}
