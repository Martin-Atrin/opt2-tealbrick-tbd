import Foundation
import TBDSpeech

/// The one place that announces "a transcript was saved to the library" (a finished file, link or meeting).
/// Features that react to it add a handler instead of being called from the queue or the meeting controller:
/// auto-save to a folder, the meeting-ready notice, and any later rule such as saving to Knowledge.
@MainActor
final class TBDTranscriptSavedHub {
    typealias Handler = @MainActor (TBDTranscription) -> Void
    struct Token: Hashable { fileprivate let id = UUID() }

    private var handlers: [(token: Token, run: Handler)] = []

    @discardableResult
    func add(_ handler: @escaping Handler) -> Token {
        let token = Token()
        handlers.append((token, handler))
        return token
    }

    func remove(_ token: Token) { handlers.removeAll { $0.token == token } }

    /// Calls every handler in the order they were added. A slow or failing handler must handle its own errors.
    func publish(_ item: TBDTranscription) { for entry in handlers { entry.run(item) } }
}

/// The built-in reactions: write the transcript to the auto-save folder, tell the person a meeting is ready.
@MainActor
final class TBDTranscriptSavedEffects {
    private let env: TBDListeningEnvironment
    private let notifier: TBDNotifier
    private let report: (String) -> Void
    private var token: TBDTranscriptSavedHub.Token?

    init(env: TBDListeningEnvironment, notifier: TBDNotifier, report: @escaping (String) -> Void) {
        self.env = env; self.notifier = notifier; self.report = report
        token = env.transcriptSaved.add { [weak self] item in self?.handle(item) }
    }

    private func handle(_ item: TBDTranscription) {
        let isMeeting = item.sourceKind == .meeting
        let summaries = (try? env.database?.summaries(for: item.id)) ?? []
        // A failed auto-save is shown, never silent, and does not undo the save that triggered it.
        if case .failed(let message) = TBDAutoSaver(preferences: env.preferences).saveIfEnabled(item, summaries: summaries, scope: isMeeting ? .meeting : .transcription) {
            report(message)
        }
        if isMeeting,
           let notice = TBDCompletionNotice.meetingReady(enabled: env.preferences.notifyOnMeetingEnd, title: item.title, wordCount: item.text.split(whereSeparator: \.isWhitespace).count) {
            notifier.present(notice)
        }
    }
}
