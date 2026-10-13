import AppKit
import TBDSpeech
import UniformTypeIdentifiers

/// Meeting recording for the UI: start, pause, stop, live preview, final transcript,
/// crash recovery and calendar reminders.
@MainActor
final class TBDMeetingController: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, paused, processing(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsedMs = 0
    @Published private(set) var preview: [TBDPreviewLine] = []
    @Published private(set) var warning: String?
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var upcoming: [TBDCalendarMonitor.Meeting] = []
    /// Stage of a final transcription running in the background (a new meeting can start meanwhile).
    @Published private(set) var finalizingStage: String?
    /// The person's notes for the meeting being recorded.
    @Published private(set) var notes = ""
    @Published var liveTab: LiveTab = .notes
    /// Ask during the meeting; saved with the transcript afterwards.
    let liveAsk: TBDAskModel
    var onMessage: ((String) -> Void)?

    enum LiveTab: String, CaseIterable, Identifiable {
        case notes, transcript, ask
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    private let env: TBDListeningEnvironment
    private let recorder: TBDMeetingRecorder
    private let calendar = TBDCalendarMonitor()
    let countdown = TBDMeetingCountdown()
    private var ticker: Timer?
    private var finalizing: Set<String> = []
    private var currentTitle = "Meeting"
    private var notesSave: Task<Void, Never>?

    init(env: TBDListeningEnvironment) {
        self.env = env
        recorder = TBDMeetingRecorder(speech: env.speech, microphone: env.microphone)
        liveAsk = TBDAskModel(database: env.database)
        recorder.onPreview = { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                self.preview.append(line)
                self.preview.sort { $0.startMs < $1.startMs }
                if self.preview.count > 300 { self.preview.removeFirst(self.preview.count - 300) }
            }
        }
        recorder.onWarning = { [weak self] message in Task { @MainActor in self?.warning = message } }
        calendar.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        liveAsk.context = { [weak self] in (self?.liveTranscript ?? "", self?.notes) }
    }

    /// Live preview as `[M:SS] Me/Others: text` lines for Ask.
    var liveTranscript: String {
        preview.map { "[\(TBDExport.clock($0.startMs))] \($0.source == .me ? "Me" : "Others"): \($0.text)" }.joined(separator: "\n")
    }

    /// Edits the live notes; saved into the recording (crash-safe) after a short pause in typing.
    func editNotes(_ text: String) {
        notes = text
        notesSave?.cancel()
        notesSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.recorder.updateNotes(self.notes)
        }
    }

    var isRecording: Bool { phase == .recording || phase == .paused || phase == .starting }

    var statusText: String {
        switch phase {
        case .idle: finalizingStage == nil ? "Idle" : "Processing"
        case .starting: "Starting"
        case .recording: "Recording · " + TBDPillClock.text(elapsedMs)
        case .paused: "Paused · " + TBDPillClock.text(elapsedMs)
        case .processing: "Processing"
        }
    }

    func start() {
        recoverInterrupted()
        configureCalendar()
    }

    func shutdown() {
        calendar.stop()
        if isRecording {
            // The tracks are crash-safe; the next launch finishes the transcript.
            Task { _ = try? await recorder.stop() }
        }
    }

    // MARK: Recording

    func toggle() { isRecording ? stop() : begin(title: nil) }

    func begin(title: String?) {
        guard phase == .idle else { return }
        phase = .starting
        warning = nil
        preview = []
        notes = ""
        liveTab = .notes
        liveAsk.reset()
        currentTitle = title ?? "Meeting " + Date().formatted(date: .abbreviated, time: .shortened)
        Task {
            do {
                _ = try await recorder.start(title: currentTitle)
                phase = .recording
                startTicker()
            } catch {
                phase = .idle
                onMessage?(error.localizedDescription)
            }
        }
    }

    func pause() { recorder.pause(); phase = .paused }
    func resume() { recorder.resume(); phase = .recording }

    func stop() {
        guard phase == .recording || phase == .paused else { return }
        ticker?.invalidate()
        phase = .processing("Saving…")
        notesSave?.cancel()
        recorder.updateNotes(notes)
        liveAsk.stop()
        let askHistory = liveAsk.history
        Task {
            do {
                let (manifest, folder) = try await recorder.stop()
                phase = .idle
                micLevel = 0; systemLevel = 0
                await finalize(folder, askHistory: askHistory, transcriptionID: manifest.transcriptionID)
            } catch {
                phase = .idle
                onMessage?(error.localizedDescription)
            }
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsedMs = self.recorder.elapsedMs
                let levels = self.recorder.levels
                self.micLevel = levels.mic; self.systemLevel = levels.system
            }
        }
    }

    private func finalize(_ folder: URL, askHistory: [TBDAskMessage] = [], transcriptionID: String? = nil, select: Bool = true,
                          currentFinalEngine: Bool = false) async {
        guard let database = env.database, finalizing.insert(folder.path).inserted else { return }
        defer {
            finalizing.remove(folder.path)
            if finalizing.isEmpty { finalizingStage = nil }
            // Ask from the live meeting is kept even when transcription failed (the record exists).
            if let transcriptionID, (try? database.transcription(id: transcriptionID)) != nil {
                TBDAskModel.save(askHistory, to: transcriptionID, database: database)
            }
        }
        finalizingStage = "Preparing transcript…"
        do {
            let item = try await recorder.finalize(folder: folder, database: database, keepAudio: env.preferences.keepsAudio(.meetingAudio),
                                                currentFinalEngine: currentFinalEngine) { stage in
                Task { @MainActor [weak self] in if self?.finalizingStage != nil { self?.finalizingStage = stage } }
            }
            if select { env.selectedTranscriptionID = item.id }
            onMessage?("Meeting transcript saved")
            env.transcriptSaved.publish(item)
            summarizeAutomatically(item)
        } catch is CancellationError {
        } catch {
            onMessage?("Meeting transcription failed: \(error.localizedDescription). The audio is kept; use Transcribe again.")
        }
        env.changed()
    }

    /// Summarises a finished meeting with the saved summary prompt when a model is assigned.
    private func summarizeAutomatically(_ item: TBDTranscription) {
        let prefs = env.preferences
        guard prefs.autoSummarizeMeetings, TBDMeetingAsk.available, !item.text.isEmpty, let database = env.database,
              ((try? database.summaries(for: item.id)) ?? []).isEmpty else { return }
        let prompt = prefs.summaryPrompt
        Task {
            do {
                let content = try await TBDListeningAI.summarize(item, prompt: prompt)
                try database.save(TBDSummary(transcriptionId: item.id, kind: .summary, prompt: prompt, content: content))
                env.changed()
            } catch is CancellationError {
            } catch {
                onMessage?("Meeting summary failed: \(error.localizedDescription)")
            }
        }
    }

    /// Re-runs the final transcription of a stored meeting with the final engine chosen now.
    func retranscribe(_ id: String) {
        guard let item = try? env.database?.transcription(id: id), let path = item.audioPaths.first else {
            onMessage?("The meeting audio is no longer available.")
            return
        }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        Task { await finalize(folder, currentFinalEngine: true) }
    }

    // MARK: Import and split

    /// Imports an audio or video file as a meeting and transcribes it.
    func importMeeting() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.message = "Choose a recording to import as a meeting"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importMeeting(url)
    }

    func importMeeting(_ url: URL) {
        guard let database = env.database else { onMessage?(env.databaseError ?? "Library unavailable"); return }
        finalizingStage = "Importing \(url.lastPathComponent)…"
        Task {
            do {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let (item, folder) = try await TBDMeetingImporter.prepare(file: url, database: database)
                env.selectedTab = .meetings
                env.selectedTranscriptionID = item.id
                env.changed()
                await finalize(folder)
            } catch {
                if finalizing.isEmpty { finalizingStage = nil }
                onMessage?("Import failed: \(error.localizedDescription)")
            }
        }
    }

    /// Splits a stored meeting into parts and transcribes each part. The source stays as it is.
    func split(_ id: String, cutsMs: [Int], titles: [String]) throws {
        guard let database = env.database, let item = try database.transcription(id: id) else { return }
        let parts = try TBDMeetingSplitter.prepare(item, cutsMs: cutsMs, titles: titles, database: database)
        env.changed()
        env.selectedTranscriptionID = parts.first?.item.id
        Task {
            for part in parts { await finalize(part.folder, select: false) }
            onMessage?("Split into \(parts.count) meetings")
        }
    }

    /// Offers to finish meetings interrupted by a crash or quit: Recover, Later or Discard.
    private func recoverInterrupted() {
        let (offer, empty) = TBDMeetingRecovery.scan(database: env.database)
        // A recording that died within its first moment has nothing to recover.
        for folder in empty { try? FileManager.default.removeItem(at: folder) }
        guard !offer.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.askToRecover(offer)
        }
    }

    private func askToRecover(_ offer: [TBDMeetingRecovery.Candidate]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = offer.count == 1 ? "We found 1 interrupted recording" : "We found \(offer.count) interrupted recordings"
        var lines = offer.prefix(5).map { candidate in
            candidate.manifest.startedAt.formatted(date: .abbreviated, time: .shortened)
                + (candidate.manifest.title.hasPrefix("Meeting ") ? "" : " — " + candidate.manifest.title)
        }
        if offer.count > 5 { lines.append("and \(offer.count - 5) more") }
        alert.informativeText = lines.joined(separator: "\n") + "\n\nRecovery transcribes the saved audio and keeps your notes."
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Discard")
        alert.buttons.last?.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                for candidate in offer { await finalize(candidate.folder, select: candidate == offer.first) }
            }
        case .alertThirdButtonReturn:
            for candidate in offer {
                if let id = candidate.manifest.transcriptionID, let item = try? env.database?.transcription(id: id), item.status != .completed {
                    try? env.database?.deleteTranscription(id: id)
                }
                try? FileManager.default.removeItem(at: candidate.folder)
            }
            env.changed()
        default:
            break
        }
    }

    // MARK: Calendar

    func configureCalendar() {
        var skips = env.preferences.calendarSkips
        skips.prune()
        env.preferences.calendarSkips = skips
        guard env.preferences.calendarReminders || env.preferences.calendarAutoStart else { calendar.stop(); upcoming = []; return }
        Task {
            let granted = TBDCalendarMonitor.authorized ? true : await calendar.requestAccess()
            guard granted else {
                warning = "Allow calendar access in System Settings → Privacy & Security → Calendars for meeting reminders."
                return
            }
            calendar.start()
            upcoming = calendar.upcoming()
        }
    }

    private func handle(_ event: TBDCalendarMonitor.Event) {
        upcoming = calendar.upcoming()
        switch event {
        case .upcoming(let meeting):
            guard env.preferences.calendarReminders, !isRecording else { return }
            env.overlay.model.onAccept = { [weak self] in
                self?.env.overlay.hide()
                self?.begin(title: meeting.title)
            }
            env.overlay.show(.prompt("\(meeting.title) starts in a minute", action: "Record"))
        case .started(let meeting):
            guard env.preferences.calendarAutoStart, !isRecording, !isSkipped(meeting) else { return }
            countdown.show(meeting) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .completed, .startNow:
                    guard !self.isRecording, !self.isSkipped(meeting) else { return }
                    self.begin(title: meeting.title)
                    self.env.overlay.show(.message("Recording “\(meeting.title)”"))
                case .dismissed:
                    self.skip(meeting, series: false)
                case .replaced:
                    break
                }
            }
        }
    }

    // MARK: Skips

    func isSkipped(_ meeting: TBDCalendarMonitor.Meeting) -> Bool {
        env.preferences.calendarSkips.skips(id: meeting.id, seriesID: meeting.seriesID, start: meeting.start)
    }

    /// Don't auto-record this occurrence, or the whole repeating series.
    func skip(_ meeting: TBDCalendarMonitor.Meeting, series: Bool) {
        var skips = env.preferences.calendarSkips
        if series { skips.series.insert(meeting.seriesID) }
        else { skips.occurrences.insert(TBDCalendarSkips.occurrenceKey(id: meeting.id, start: meeting.start)) }
        env.preferences.calendarSkips = skips
        objectWillChange.send()
    }

    func unskip(_ meeting: TBDCalendarMonitor.Meeting) {
        var skips = env.preferences.calendarSkips
        skips.series.remove(meeting.seriesID)
        skips.occurrences.remove(TBDCalendarSkips.occurrenceKey(id: meeting.id, start: meeting.start))
        env.preferences.calendarSkips = skips
        objectWillChange.send()
    }
}
