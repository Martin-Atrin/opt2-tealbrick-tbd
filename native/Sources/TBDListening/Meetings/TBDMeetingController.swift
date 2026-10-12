import AppKit
import TBDSpeech

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
    var onMessage: ((String) -> Void)?

    private let env: TBDListeningEnvironment
    private let recorder: TBDMeetingRecorder
    private let calendar = TBDCalendarMonitor()
    private var ticker: Timer?
    private var finalizing: Set<String> = []
    private var currentTitle = "Meeting"

    init(env: TBDListeningEnvironment) {
        self.env = env
        recorder = TBDMeetingRecorder(speech: env.speech, microphone: env.microphone)
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
        Task {
            do {
                let (_, folder) = try await recorder.stop()
                phase = .idle
                micLevel = 0; systemLevel = 0
                await finalize(folder)
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

    private func finalize(_ folder: URL) async {
        guard let database = env.database, finalizing.insert(folder.path).inserted else { return }
        defer {
            finalizing.remove(folder.path)
            if finalizing.isEmpty { finalizingStage = nil }
        }
        finalizingStage = "Preparing transcript…"
        do {
            let item = try await recorder.finalize(folder: folder, database: database, keepAudio: env.preferences.keepsAudio(.meetingAudio)) { stage in
                Task { @MainActor [weak self] in if self?.finalizingStage != nil { self?.finalizingStage = stage } }
            }
            env.selectedTranscriptionID = item.id
            onMessage?("Meeting transcript saved")
        } catch is CancellationError {
        } catch {
            onMessage?("Meeting transcription failed: \(error.localizedDescription). The audio is kept; use Transcribe again.")
        }
        env.changed()
    }

    /// Re-runs the final transcription of a stored meeting.
    func retranscribe(_ id: String) {
        guard let item = try? env.database?.transcription(id: id), let path = item.audioPaths.first else {
            onMessage?("The meeting audio is no longer available.")
            return
        }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        Task { await finalize(folder) }
    }

    /// Finishes meetings interrupted by a crash or quit.
    private func recoverInterrupted() {
        let folders = TBDMeetingRecorder.pendingRecoveries()
        guard !folders.isEmpty else { return }
        Task {
            for folder in folders { await finalize(folder) }
        }
    }

    // MARK: Calendar

    func configureCalendar() {
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
            guard env.preferences.calendarAutoStart, !isRecording else { return }
            begin(title: meeting.title)
            env.overlay.show(.message("Recording “\(meeting.title)”"))
        }
    }
}
