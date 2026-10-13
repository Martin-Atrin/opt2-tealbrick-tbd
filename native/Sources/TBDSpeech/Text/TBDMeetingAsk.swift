import Foundation
import TBDModels

/// A ready-made Ask question: the label is shown, the prompt is sent.
public struct TBDQuickPrompt: Sendable, Equatable, Identifiable, Hashable {
    public let label: String
    public let group: String?
    public let prompt: String
    /// Library row id when the prompt comes from the quick prompt library (labels may repeat).
    public var key: String?
    public var id: String { key ?? label }

    public init(label: String, group: String?, prompt: String, key: String? = nil) {
        self.label = label; self.group = group; self.prompt = prompt; self.key = key
    }

    /// Starters for an empty conversation.
    public static let starters: [TBDQuickPrompt] = [
        .init(label: "Summarize so far", group: "Catch up", prompt: "Give a concise summary of the meeting so far. Focus on the main topics, decisions made, and any clear conclusions. Skip verbal filler."),
        .init(label: "What did I miss?", group: "Catch up", prompt: "Catch me up on the most recent shifts in the meeting — the latest decisions, new arguments, or topic changes. Skip what was clearly settled earlier. Be terse, signal-rich."),
        .init(label: "Decisions made", group: "Capture", prompt: "List the decisions reached in the meeting so far. For each, note what was decided and the brief context that explains why. Skip topics that were only discussed without a decision."),
        .init(label: "Action items", group: "Capture", prompt: "List concrete action items from the meeting so far — what needs to happen next, by whom, and by when if mentioned. Be specific. Skip vague intentions."),
        .init(label: "Who owns what?", group: "Capture", prompt: "Map who owns what from the meeting so far — assignments, commitments, areas of responsibility. If ownership for an item is unclear or unstated, flag that explicitly."),
        .init(label: "What's unresolved?", group: "Challenge", prompt: "List the open questions, unmade decisions, or topics still hanging from the meeting so far. Be specific."),
        .init(label: "What question is worth asking?", group: "Challenge", prompt: "Based on the meeting so far, suggest one sharp, useful question I could ask next that would advance the discussion or surface something important that hasn't been addressed."),
        .init(label: "What's worth pushing back on?", group: "Challenge", prompt: "Identify any claims, assumptions, or decisions in the meeting so far that deserve scrutiny. What might be wrong, weak, or worth challenging?"),
        .init(label: "Where are we going in circles?", group: "Challenge", prompt: "Have we revisited the same topic or argument without making progress? If so, point out where we're looping and what would actually move things forward."),
    ]

    /// Follow-ups shown after the first answer.
    public static let followUps: [TBDQuickPrompt] = [
        .init(label: "Tell me more", group: nil, prompt: "Expand on your previous response with more concrete detail from the meeting itself — quotes, specifics, who said what. Surface nuances or caveats you compressed out the first time."),
        .init(label: "Why?", group: nil, prompt: "Explain the reasoning behind your previous answer. What from the meeting transcript supports it?"),
        .init(label: "Give an example", group: nil, prompt: "Give one specific, concrete example that illustrates your previous response. Pull it from the meeting itself — a moment, exchange, or quote. If the meeting doesn't contain a clean example, say so plainly and offer the closest analogue."),
        .init(label: "Counter-argument?", group: nil, prompt: "What's the strongest counter-argument to your previous response? Steelman the opposing view, and use anything in the meeting that supports it."),
        .init(label: "TL;DR", group: nil, prompt: "Give the punchy, no-fluff TL;DR of your previous response — one or two sentences. No headers, no list, no preamble."),
    ]

    /// Starters for transcripts that are not meetings.
    public static let transcriptStarters: [TBDQuickPrompt] = [
        .init(label: "Summarize the key points", group: nil, prompt: "Summarize the key points"),
        .init(label: "What are the main takeaways?", group: nil, prompt: "What are the main takeaways?"),
        .init(label: "List any action items mentioned", group: nil, prompt: "List any action items mentioned"),
    ]
}

/// Builds Ask requests over a transcript and the person's notes (route "analysis").
public enum TBDMeetingAsk {
    public static let systemPrompt = "You are a helpful assistant. The user will ask questions about the following transcript. Answer based on the transcript content. If the answer isn't in the transcript, say so."
    static let notesHeader = "\n\n---\nUser's notes from the meeting (treat these as what the user thinks matters; the transcript is the source of truth for facts):\n"
    static let transcriptHeader = "\n\n---\nTranscript:\n"
    static let truncationMarker = "\n\n[... content truncated ...]\n\n"
    /// Character budget for one request.
    public static let budget = 120_000

    /// Messages for the model: system prompt with notes and transcript, trimmed history, the question.
    public static func messages(question: String, transcript: String, notes: String?, history: [TBDAskMessage],
                                budget: Int = TBDMeetingAsk.budget) -> [TBDChatMessage] {
        let historyReserve = min(8_000, budget / 10)
        let contextBudget = max(0, budget - systemPrompt.count - question.count - historyReserve)
        var system = systemPrompt
        var remaining = contextBudget
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            let kept = truncateMiddle(notes, limit: min(notes.count, contextBudget / 4))
            system += notesHeader + kept
            remaining -= kept.count
        }
        system += transcriptHeader + truncateMiddle(transcript, limit: max(0, remaining))

        // Whole turns, oldest dropped first.
        var turns = history
        let available = max(0, budget - system.count - question.count)
        while !turns.isEmpty, turns.reduce(0, { $0 + $1.modelContent.count }) > available {
            turns.removeFirst(min(2, turns.count))
        }
        return [TBDChatMessage(.system, system)]
            + turns.map { TBDChatMessage($0.role == .user ? .user : .assistant, $0.modelContent) }
            + [TBDChatMessage(.user, question)]
    }

    /// Keeps the head and tail at word boundaries with a marker in between.
    public static func truncateMiddle(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > truncationMarker.count + 20 else { return String(text.prefix(max(0, limit))) }
        let half = (limit - truncationMarker.count) / 2
        var head = String(text.prefix(half))
        var tail = String(text.suffix(half))
        if let space = head.lastIndex(where: \.isWhitespace) { head = String(head[..<space]) }
        if let space = tail.firstIndex(where: \.isWhitespace) { tail = String(tail[tail.index(after: space)...]) }
        return head + truncationMarker + tail
    }

    /// `[M:SS] Speaker: text` lines for a stored transcript.
    public static func transcript(_ item: TBDTranscription) -> String {
        let segments = TBDExport.displaySegments(item)
        guard !segments.isEmpty else { return item.text }
        return segments.map { segment in
            "[\(TBDExport.clock(segment.start))] " + (item.speakerLabel(segment.speaker).map { "\($0): " } ?? "") + segment.text
        }.joined(separator: "\n")
    }

    /// Streams the answer from the "analysis" route.
    public static func stream(question: String, transcript: String, notes: String?, history: [TBDAskMessage]) throws -> AsyncThrowingStream<String, Error> {
        let client = try TBDChatClient.forTask(.analysis)
        return client.stream(messages(question: question, transcript: transcript, notes: notes, history: history))
    }

    /// True when a model is assigned to the "analysis" route. Reads route metadata only (no Keychain access).
    public static var available: Bool {
        guard let state = try? TBDModelRegistry().load(), let route = state.routes[TBDModelTask.analysis.rawValue] else { return false }
        return state.connections.contains { $0.id == route.connectionID }
    }
}

/// Slash commands of the notes editor: `/action`, `/decision`, `/now`.
public enum TBDNotesCommands {
    public enum Command: String, CaseIterable, Sendable, Identifiable {
        case action, decision, now
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .action: "Action"
            case .decision: "Decision"
            case .now: "Timestamp"
            }
        }
        public var help: String {
            switch self {
            case .action: "Insert an action item"
            case .decision: "Insert a decision"
            case .now: "Insert the current recording time"
            }
        }
    }

    /// The partial command typed at the end of the text ("/" at the start or after whitespace).
    public static func pendingQuery(in text: String) -> String? {
        guard let slash = text.lastIndex(of: "/") else { return nil }
        if slash > text.startIndex, !text[text.index(before: slash)].isWhitespace { return nil }
        let token = text[text.index(after: slash)...]
        guard token.allSatisfy({ $0.isLetter }) else { return nil }
        return String(token).lowercased()
    }

    /// Commands matching the pending query, or none when nothing is pending.
    public static func suggestions(for text: String) -> [Command] {
        guard let query = pendingQuery(in: text) else { return [] }
        return Command.allCases.filter { query.isEmpty || $0.rawValue.hasPrefix(query) }
    }

    /// Replaces the pending `/token` with the command's insertion.
    public static func apply(_ command: Command, to text: String, elapsedMs: Int) -> String {
        guard let slash = text.lastIndex(of: "/"), pendingQuery(in: text) != nil else { return text }
        let insertion: String = switch command {
        case .action: "**Action:** "
        case .decision: "**Decision:** "
        case .now: "[\(TBDExport.clock(elapsedMs))] "
        }
        return String(text[..<slash]) + insertion
    }

    /// Notes past this many words are trimmed by prompts (storage keeps everything).
    public static let softCapWords = 7_500
}
