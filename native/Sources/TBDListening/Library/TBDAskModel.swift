import Foundation
import TBDSpeech

/// Ask: questions over a transcript and the person's notes, streamed from the "analysis" route.
/// Live meetings keep the conversation in memory; stored transcripts save it after each answer.
@MainActor
final class TBDAskModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var role: TBDAskMessage.Role
        var text: String
        var prompt: String?
        var streaming = false
    }

    @Published private(set) var lines: [Line] = []
    @Published var input = ""
    @Published private(set) var streaming = false
    @Published var error: String?
    @Published private(set) var conversations: [TBDAskConversation] = []

    private(set) var transcriptionID: String?
    private var conversation: TBDAskConversation?
    private var task: Task<Void, Never>?
    private let database: TBDListeningDatabase?
    /// Current transcript and notes, read when a question is sent (so the newest keystroke counts).
    var context: () -> (transcript: String, notes: String?) = { ("", nil) }

    init(database: TBDListeningDatabase?, transcriptionID: String? = nil) {
        self.database = database
        self.transcriptionID = transcriptionID
    }

    var available: Bool { TBDMeetingAsk.available }

    /// Finished messages, oldest first.
    var history: [TBDAskMessage] {
        lines.filter { !$0.streaming }.map { TBDAskMessage($0.role, $0.text, prompt: $0.prompt) }
    }

    /// Loads the most recent saved conversation.
    func load() {
        guard let transcriptionID, let database else { return }
        conversations = (try? database.askConversations(for: transcriptionID)) ?? []
        guard !streaming else { return }
        show(conversations.first)
    }

    func select(_ conversation: TBDAskConversation) {
        stop()
        show(conversation)
    }

    private func show(_ conversation: TBDAskConversation?) {
        self.conversation = conversation
        lines = conversation?.messages.map { Line(role: $0.role, text: $0.content, prompt: $0.prompt) } ?? []
    }

    func send(_ quick: TBDQuickPrompt? = nil) {
        let question = (quick?.label ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !streaming else { return }
        let prior = history
        let modelQuestion = quick?.prompt ?? question
        error = nil
        input = ""
        lines.append(Line(role: .user, text: question, prompt: quick?.prompt))
        persist()
        lines.append(Line(role: .assistant, text: "", streaming: true))
        let streamID = lines[lines.count - 1].id
        streaming = true
        let (transcript, notes) = context()
        task = Task { [weak self] in
            do {
                let stream = try TBDMeetingAsk.stream(question: modelQuestion, transcript: transcript, notes: notes, history: prior)
                for try await delta in stream {
                    guard let self, let index = self.lines.firstIndex(where: { $0.id == streamID }) else { return }
                    self.lines[index].text += delta
                }
                guard let self, let index = self.lines.firstIndex(where: { $0.id == streamID }) else { return }
                self.lines[index].streaming = false
                self.streaming = false
                self.persist()
            } catch {
                guard let self else { return }
                self.lines.removeAll { $0.id == streamID }
                self.streaming = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    /// Stops the answer in progress; a partial answer is discarded.
    func stop() {
        task?.cancel()
        task = nil
        lines.removeAll(where: \.streaming)
        streaming = false
    }

    func newChat() {
        stop()
        conversation = nil
        lines = []
        error = nil
    }

    func deleteConversation(_ item: TBDAskConversation) {
        try? database?.deleteAskConversation(id: item.id)
        if conversation?.id == item.id { newChat() }
        load()
    }

    /// Clears everything (a new live meeting).
    func reset(transcriptionID: String? = nil) {
        newChat()
        self.transcriptionID = transcriptionID
        conversations = []
    }

    /// Saves a conversation held in memory (a live meeting) once its transcript exists.
    static func save(_ messages: [TBDAskMessage], to transcriptionID: String, database: TBDListeningDatabase?) {
        guard !messages.isEmpty, let database else { return }
        let title = messages.first { $0.role == .user }.map { String($0.content.prefix(50)) } ?? "Meeting chat"
        try? database.save(TBDAskConversation(transcriptionId: transcriptionID, title: title, messages: messages))
    }

    private func persist() {
        guard let transcriptionID, let database else { return }
        var item = conversation ?? TBDAskConversation(transcriptionId: transcriptionID,
                                                      title: String((lines.first { $0.role == .user }?.text ?? "Chat").prefix(50)))
        item.messages = history
        do {
            try database.save(item)
            conversation = item
            if !conversations.contains(where: { $0.id == item.id }) { conversations.insert(item, at: 0) }
        } catch {
            self.error = "Could not save the conversation."
        }
    }
}
