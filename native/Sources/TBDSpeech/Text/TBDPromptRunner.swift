import Foundation
import TBDModels

/// One model call, described as data so tests can answer it with a fake.
public struct TBDCompletionRequest: Sendable, Equatable {
    public var task: TBDModelTask
    public var messages: [TBDChatMessage]
    public var maxTokens: Int
    public var temperature: Double?
    /// Model name instead of the route's model (per-prompt setting).
    public var modelOverride: String?
    public init(task: TBDModelTask, messages: [TBDChatMessage], maxTokens: Int = 4096, temperature: Double? = nil, modelOverride: String? = nil) {
        self.task = task; self.messages = messages; self.maxTokens = maxTokens; self.temperature = temperature; self.modelOverride = modelOverride
    }
}

/// Answers a completion request. The live one uses the model routes in Settings → Models.
public typealias TBDCompleter = @Sendable (TBDCompletionRequest) async throws -> String

public enum TBDCompleters {
    public static let live: TBDCompleter = { request in
        guard var config = try TBDModelRegistry().configuration(for: request.task) else {
            throw TBDChatClientError.notConfigured(request.task.rawValue)
        }
        if let model = request.modelOverride, !model.isEmpty {
            config = TBDModelConfig(kind: config.kind, baseURL: config.baseURL, apiKey: config.apiKey, model: model, isLocal: config.isLocal)
        }
        return try await TBDChatClient(config: config).complete(request.messages, maxTokens: request.maxTokens, temperature: request.temperature)
    }
}

/// Runs library prompts: transcript prompts make summaries, Transforms rewrite selected text.
/// Generation settings sent today: temperature, max tokens and model override (the chat client
/// has no top-p, top-k or thinking parameters yet; those are stored with the prompt).
public enum TBDPromptRunner {
    /// Messages for a transcript prompt: its instructions (plus one-off extra instructions and,
    /// when the prompt asks for it, the meeting notes) and the transcript.
    public static func summaryMessages(prompt: TBDPrompt, transcription: TBDTranscription, extraInstructions: String? = nil) -> [TBDChatMessage] {
        var system = prompt.content
        if let extra = extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            system += "\n\nAdditional instructions for this run:\n\(extra)"
        }
        if prompt.includeMeetingNotes, let notes = transcription.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            system += "\n\nThe user's notes from the meeting (what they think matters; the transcript is the source of truth):\n\(notes)"
        }
        return [
            TBDChatMessage(.system, system),
            TBDChatMessage(.user, "Title: \(transcription.title)\n\nTranscript:\n\(TBDListeningAI.context(transcription))"),
        ]
    }

    /// Runs `prompt` on a transcript and returns the summary to save (not yet saved).
    public static func summarize(_ transcription: TBDTranscription, with prompt: TBDPrompt, extraInstructions: String? = nil,
                                 complete: TBDCompleter = TBDCompleters.live) async throws -> TBDSummary {
        let request = TBDCompletionRequest(task: .analysis, messages: summaryMessages(prompt: prompt, transcription: transcription, extraInstructions: extraInstructions),
                                           maxTokens: prompt.inference?.maxTokens ?? 4096, temperature: prompt.inference?.temperature,
                                           modelOverride: prompt.modelOverride)
        let content = try await complete(request)
        let extra = extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TBDSummary(transcriptionId: transcription.id, kind: .summary, prompt: prompt.content, content: content,
                          promptId: prompt.id, promptVersionId: prompt.activeVersionId, promptName: prompt.name,
                          extraInstructions: extra?.isEmpty == false ? extra : nil)
    }

    /// Runs `prompt` and saves the summary; a transcript can hold any number of summaries.
    @discardableResult
    public static func summarize(_ transcription: TBDTranscription, with prompt: TBDPrompt, extraInstructions: String? = nil,
                                 into database: TBDListeningDatabase, complete: TBDCompleter = TBDCompleters.live) async throws -> TBDSummary {
        let summary = try await summarize(transcription, with: prompt, extraInstructions: extraInstructions, complete: complete)
        try database.save(summary)
        return summary
    }

    public static func transformMessages(_ transform: TBDPrompt, input: String) -> [TBDChatMessage] {
        [
            TBDChatMessage(.system, "\(transform.content)\nReturn only the resulting text, with no preamble, quotes or explanation."),
            TBDChatMessage(.user, input),
        ]
    }

    /// Runs a Transform on `input`, records the run in Transform history and returns the text to paste.
    public static func transform(_ input: String, with transform: TBDPrompt, sourceAppBundleID: String? = nil, sourceAppName: String? = nil,
                                 database: TBDListeningDatabase?, complete: TBDCompleter = TBDCompleters.live) async throws -> String {
        let start = ContinuousClock.now
        let request = TBDCompletionRequest(task: .general, messages: transformMessages(transform, input: input),
                                           maxTokens: transform.inference?.maxTokens ?? 4096, temperature: transform.inference?.temperature,
                                           modelOverride: transform.modelOverride)
        let raw = try await complete(request)
        let output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw TBDChatClientError.emptyResponse }
        let elapsed = Self.milliseconds(ContinuousClock.now - start)
        // History is secondary: the rewrite already succeeded, so a failed write is not an error.
        try? database?.saveTransformRun(TBDTransformRun(transformId: transform.id, transformName: transform.name, inputText: input,
                                                        outputText: output, sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
                                                        llmElapsedMs: elapsed, totalElapsedMs: elapsed))
        return output
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Hotkeys for Transforms: one binding per Transform with a valid hotkey.
public enum TBDTransformHotkeys {
    public struct Binding: Equatable, Sendable {
        public let hotkey: TBDHotkey
        public let transformID: String
        public init(hotkey: TBDHotkey, transformID: String) { self.hotkey = hotkey; self.transformID = transformID }
    }

    /// Transforms in library order. Deleted or non-Transform prompts, missing or unparsable hotkeys,
    /// hotkeys already used by `reserved` (for example the dictation hotkey) and later duplicates are skipped.
    public static func bindings(for prompts: [TBDPrompt], reserved: [TBDHotkey] = []) -> [Binding] {
        var used = Set(reserved)
        var result: [Binding] = []
        for prompt in prompts.sorted(by: { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) })
        where prompt.category == .transform && prompt.deletedAt == nil {
            guard let text = prompt.hotkey, let hotkey = try? TBDHotkey.parse(text), !used.contains(hotkey) else { continue }
            used.insert(hotkey)
            result.append(Binding(hotkey: hotkey, transformID: prompt.id))
        }
        return result
    }
}
