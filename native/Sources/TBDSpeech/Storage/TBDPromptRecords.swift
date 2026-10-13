import Foundation
import GRDB

// Prompt library records (migration `v6-prompts-transforms`). Ported from the earlier Listening
// app's Prompt, PromptVersion, PromptCollection, QuickPrompt and TransformHistoryEntry models:
// one prompt table holds transcript prompts ("result") and Transforms, every change to what is
// sent to the model makes an immutable version, and built-ins keep their original UUIDs so the
// two libraries line up.

/// Per-prompt generation settings. Stored as JSON; nil (or all defaults) means provider defaults.
public struct TBDPromptInference: Codable, Sendable, Equatable, Hashable {
    public enum ThinkingMode: String, Codable, Sendable, CaseIterable { case providerDefault, enabled, disabled }
    public enum ReasoningEffort: String, Codable, Sendable, CaseIterable { case low, medium, high, xhigh }

    public enum ValidationError: Error, LocalizedError, Sendable, Equatable {
        case outOfRange(field: String, minimum: Double, maximum: Double)
        case nonFinite(field: String)
        public var errorDescription: String? {
            switch self {
            case .outOfRange(let field, let minimum, let maximum):
                return "\(field) must be between \(TBDPromptInference.format(minimum)) and \(TBDPromptInference.format(maximum))."
            case .nonFinite(let field): return "\(field) must be a finite number."
            }
        }
    }

    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var maxTokens: Int?
    public var thinkingMode: ThinkingMode
    public var reasoningEffort: ReasoningEffort?

    public init(temperature: Double? = nil, topP: Double? = nil, topK: Int? = nil, maxTokens: Int? = nil,
                thinkingMode: ThinkingMode = .providerDefault, reasoningEffort: ReasoningEffort? = nil) {
        self.temperature = temperature; self.topP = topP; self.topK = topK; self.maxTokens = maxTokens
        self.thinkingMode = thinkingMode; self.reasoningEffort = reasoningEffort
    }

    public var isDefault: Bool {
        temperature == nil && topP == nil && topK == nil && maxTokens == nil && thinkingMode == .providerDefault && reasoningEffort == nil
    }

    /// Reasoning effort only applies with thinking on; all-default settings collapse to nil.
    public var normalized: TBDPromptInference? {
        var settings = self
        if settings.thinkingMode != .enabled { settings.reasoningEffort = nil }
        return settings.isDefault ? nil : settings
    }

    /// The same ranges the earlier app enforced before a prompt could be saved.
    public func validated() throws -> TBDPromptInference? {
        if let temperature {
            guard temperature.isFinite else { throw ValidationError.nonFinite(field: "temperature") }
            guard (0...2).contains(temperature) else { throw ValidationError.outOfRange(field: "temperature", minimum: 0, maximum: 2) }
        }
        if let topP {
            guard topP.isFinite else { throw ValidationError.nonFinite(field: "topP") }
            guard (0...1).contains(topP) else { throw ValidationError.outOfRange(field: "topP", minimum: 0, maximum: 1) }
        }
        if let topK, !(0...1000).contains(topK) { throw ValidationError.outOfRange(field: "topK", minimum: 0, maximum: 1000) }
        if let maxTokens, !(1...131_072).contains(maxTokens) { throw ValidationError.outOfRange(field: "maxTokens", minimum: 1, maximum: 131_072) }
        return normalized
    }

    static func format(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
}

/// A transcript prompt ("result": run on a transcript to make a summary) or a Transform (run on
/// selected text, optionally bound to its own hotkey).
public struct TBDPrompt: Codable, Sendable, Equatable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "prompt"
    public enum Category: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible { case result, transform }

    public var id: String
    public var name: String
    /// Instructions sent to the model (copy of the active version).
    public var content: String
    public var category: Category
    public var isBuiltIn: Bool
    /// Results: offered in the summary picker. Transforms: listed in the menu-bar Transform chooser.
    public var isVisible: Bool
    /// Results only: run automatically after a transcription finishes.
    public var isAutoRun: Bool
    /// Sources auto-run applies to; nil means every source.
    public var appliesToSources: [TBDSourceKind]?
    public var sortOrder: Int
    /// Transforms only: hotkey in `TBDHotkey` text form, or nil.
    public var hotkey: String?
    /// Transforms only: pill label while running (nil derives one from the name).
    public var runningLabel: String?
    public var inference: TBDPromptInference?
    /// Model name for this prompt instead of the route's model; nil uses the route's model.
    public var modelOverride: String?
    /// Results only: send the meeting notes as extra context.
    public var includeMeetingNotes: Bool
    public var collectionId: String?
    public var activeVersionId: String?
    /// Set when a built-in's name or request values were changed by the person.
    public var userCustomizedAt: Date?
    /// Soft delete: deleted prompts keep their history and can be restored from the trash.
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = tbdNewID(), name: String, content: String, category: Category = .result, isBuiltIn: Bool = false,
                isVisible: Bool = true, isAutoRun: Bool = false, appliesToSources: [TBDSourceKind]? = nil, sortOrder: Int = 0,
                hotkey: String? = nil, runningLabel: String? = nil, inference: TBDPromptInference? = nil, modelOverride: String? = nil,
                includeMeetingNotes: Bool = false, collectionId: String? = nil, activeVersionId: String? = nil,
                userCustomizedAt: Date? = nil, deletedAt: Date? = nil, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.name = name; self.content = content; self.category = category; self.isBuiltIn = isBuiltIn
        self.isVisible = isVisible; self.isAutoRun = category == .result ? isAutoRun : false
        self.appliesToSources = appliesToSources; self.sortOrder = sortOrder; self.hotkey = hotkey; self.runningLabel = runningLabel
        self.inference = inference?.normalized; self.modelOverride = modelOverride
        self.includeMeetingNotes = category == .result ? includeMeetingNotes : false
        self.collectionId = collectionId; self.activeVersionId = activeVersionId; self.userCustomizedAt = userCustomizedAt
        self.deletedAt = deletedAt; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    /// Whether this prompt auto-runs after a transcription of `source` finishes.
    public func autoRuns(for source: TBDSourceKind) -> Bool {
        guard category == .result, isAutoRun else { return false }
        guard let appliesToSources else { return true }
        return appliesToSources.contains(source)
    }

    /// Pill label while a Transform runs: the saved label, or "<Name>ing…" when that reads well.
    public var derivedRunningLabel: String {
        if let runningLabel, !runningLabel.isEmpty { return runningLabel }
        return Self.defaultRunningLabel(forName: name)
    }

    public static func defaultRunningLabel(forName name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return "Transforming…" }
        let lower = trimmed.lowercased()
        for suffix in ["ing", "tion", "ment", "ness", "ed", "er"] where lower.hasSuffix(suffix) { return "Transforming…" }
        let stem = lower.hasSuffix("e") && !lower.hasSuffix("ee") ? String(trimmed.dropLast()) : trimmed
        return "\(stem)ing…"
    }
}

/// One immutable set of values that affects a prompt's model request.
public struct TBDPromptVersion: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "promptVersion"
    public enum Origin: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
        case user, restore, systemUpdate, `import`
        public var title: String {
            switch self {
            case .user: "Edited"
            case .restore: "Restored"
            case .systemUpdate: "Built-in"
            case .import: "Imported"
            }
        }
    }
    public var id: String
    public var promptId: String
    public var versionNumber: Int
    public var content: String
    public var inference: TBDPromptInference?
    public var modelOverride: String?
    public var origin: Origin
    public var changeNote: String?
    public var createdAt: Date

    public init(id: String = tbdNewID(), promptId: String, versionNumber: Int, content: String, inference: TBDPromptInference? = nil,
                modelOverride: String? = nil, origin: Origin = .user, changeNote: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.promptId = promptId; self.versionNumber = versionNumber; self.content = content
        self.inference = inference?.normalized; self.modelOverride = modelOverride; self.origin = origin
        self.changeNote = changeNote; self.createdAt = createdAt
    }
}

/// User-defined organisation for prompts. Membership is `prompt.collectionId`; never sent to a model.
public struct TBDPromptCollection: Codable, Sendable, Equatable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "promptCollection"
    public var id: String
    public var name: String
    public var colorToken: String?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: String = tbdNewID(), name: String, colorToken: String? = nil, sortOrder: Int = 0, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.colorToken = colorToken; self.sortOrder = sortOrder
        self.createdAt = createdAt; updatedAt = createdAt
    }
}

/// A meeting Ask quick prompt. Visible prompts fill the empty Ask state (grouped by
/// `groupLabel`); visible pinned prompts form the strip shown after each answer.
public struct TBDQuickPromptItem: Codable, Sendable, Equatable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "quickPrompt"
    public var id: String
    /// Shown on the chip and in the person's own message.
    public var label: String
    /// Sent to the model.
    public var prompt: String
    public var groupLabel: String?
    public var sortOrder: Int
    public var isVisible: Bool
    public var isPinned: Bool
    public var isBuiltIn: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = tbdNewID(), label: String, prompt: String, groupLabel: String? = nil, sortOrder: Int = 0,
                isVisible: Bool = true, isPinned: Bool = false, isBuiltIn: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.label = label; self.prompt = prompt; self.groupLabel = groupLabel; self.sortOrder = sortOrder
        self.isVisible = isVisible; self.isPinned = isPinned; self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt; updatedAt = createdAt
    }

    /// The Ask pane's value type.
    public var asQuickPrompt: TBDQuickPrompt { TBDQuickPrompt(label: label, group: groupLabel, prompt: prompt, key: id) }
}

/// One saved Transform run: what was selected, what replaced it, and which Transform did it.
public struct TBDTransformRun: Codable, Sendable, Equatable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transformRun"
    public var id: String
    public var transformId: String?
    public var transformName: String
    public var inputText: String
    public var outputText: String
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    public var capturePath: String
    public var replacementPath: String
    public var llmElapsedMs: Int
    public var totalElapsedMs: Int
    public var createdAt: Date

    public init(id: String = tbdNewID(), transformId: String?, transformName: String, inputText: String, outputText: String,
                sourceAppBundleID: String? = nil, sourceAppName: String? = nil, capturePath: String = "selection",
                replacementPath: String = "paste", llmElapsedMs: Int = 0, totalElapsedMs: Int = 0, createdAt: Date = Date()) {
        self.id = id; self.transformId = transformId; self.transformName = transformName; self.inputText = inputText
        self.outputText = outputText; self.sourceAppBundleID = sourceAppBundleID; self.sourceAppName = sourceAppName
        self.capturePath = capturePath; self.replacementPath = replacementPath; self.llmElapsedMs = llmElapsedMs
        self.totalElapsedMs = totalElapsedMs; self.createdAt = createdAt
    }

    public var sourceAppDisplayName: String {
        if let sourceAppName, !sourceAppName.isEmpty { return sourceAppName }
        if let sourceAppBundleID, !sourceAppBundleID.isEmpty { return sourceAppBundleID }
        return "Unknown app"
    }
}

// MARK: - Built-ins (text copied from the earlier app; UUIDs reserved there, never reuse)

extension TBDPrompt {
    /// ID of the built-in "Summary" prompt, which also carries the old `summaryPrompt` setting.
    public static let summaryID = "a4882688-e72c-415a-9a5e-1f6ac82df0d0"

    public static func builtIns(now: Date = Date()) -> [TBDPrompt] { builtInResults(now: now) + builtInTransforms(now: now) }

    public static func builtIn(id: String) -> TBDPrompt? { builtIns().first { $0.id == id } }

    private static func result(_ id: String, _ name: String, _ content: String, autoRun: Bool = false, order: Int, now: Date) -> TBDPrompt {
        TBDPrompt(id: id.lowercased(), name: name, content: content, category: .result, isBuiltIn: true, isAutoRun: autoRun,
                  sortOrder: order, createdAt: now)
    }

    private static func transform(_ id: String, _ name: String, _ content: String, order: Int, hotkey: String, label: String, now: Date) -> TBDPrompt {
        TBDPrompt(id: id.lowercased(), name: name, content: content, category: .transform, isBuiltIn: true, sortOrder: order,
                  hotkey: hotkey, runningLabel: label, createdAt: now)
    }

    static func builtInResults(now: Date) -> [TBDPrompt] {
        [
            result("A4882688-E72C-415A-9A5E-1F6AC82DF0D0", "Summary", """
                Analyze this transcript and produce a structured summary.

                Open with a single sentence that captures what this is about and why it matters. Then organize the rest under clear headings:

                **Key Points** — The 3–7 most important ideas, findings, or arguments. Each should be a complete thought, not a fragment. If speakers are identified, attribute claims to them.

                **Decisions & Outcomes** — Anything that was agreed upon, concluded, or resolved. If nothing was decided, omit this section entirely — don't fabricate consensus.

                **Open Questions** — Unresolved threads, disagreements, or topics raised but not settled. Only include these if they're genuinely unresolved in the transcript.

                Be direct. Prefer specifics over generalizations — names, numbers, and concrete details beat vague summaries. If the transcript is short or straightforward, keep the output proportionally brief. Don't pad.
                """, autoRun: true, order: 0, now: now),
            result("65A093C3-2732-4628-8A5C-1F722BCBE736", "Action Items & Decisions", """
                Extract every concrete commitment, task, and decision from this transcript.

                **Decisions Made**
                List each decision as a single clear statement. Include who made or endorsed it if identifiable. Only list things that were actually decided — not proposals that were merely floated.

                **Action Items**
                For each task or commitment:
                - What needs to happen (specific enough to act on)
                - Who owns it (if stated or clearly implied)
                - When it's due (if any timeline was mentioned — use exact wording as spoken, don't convert or guess)

                **Needs Follow-Up**
                Anything flagged as needing attention but with no clear owner or next step yet.

                If the transcript contains no clear actions or decisions, say so plainly — don't invent structure where none exists. Order items by the sequence they appeared.
                """, order: 1, now: now),
            result("FF4C9E18-0E21-4F58-82B2-EA5A3177908D", "Chapter Breakdown", """
                Break this transcript into logical chapters or segments.

                For each chapter:
                - **Title** — A concise, descriptive name (not generic labels like "Discussion 1" or "Part 2")
                - **Summary** — 2–4 sentences capturing what happened in this segment
                - **Notable Moments** — Any standout quotes, turning points, or key data points (attribute to the speaker if identifiable)

                Chapters should reflect natural topic shifts, not arbitrary time splits. A short transcript might have 2–3 chapters; a long one might have 8–12. Let the content dictate the structure.

                If the transcript is a monologue (lecture, presentation, solo recording), organize by topic or argument progression instead of conversational turns.
                """, order: 2, now: now),
            result("A97D4655-241A-421E-A967-CF2951B67B17", "Study Guide", """
                Transform this transcript into a learning resource.

                **Overview** — One paragraph: what is being taught or discussed, and who would benefit from understanding it.

                **Key Concepts** — Each concept gets:
                - A clear, jargon-free explanation
                - An example or analogy from the transcript (quote directly when useful)
                - Why it matters or how it connects to the bigger picture

                **Common Misconceptions** — If the speaker corrects misunderstandings, challenges assumptions, or contrasts their view with a popular one, capture those moments. Omit this section if none exist.

                **Review Questions** — 3–5 questions to test understanding. Favor questions that require thinking over recall — "Why does X matter?" over "What is X?"

                **Key Terms** — Specialized vocabulary worth remembering, with concise definitions drawn from context.

                Write for someone encountering this material for the first time. Prioritize understanding over completeness.
                """, order: 3, now: now),
            result("00C9B6AE-540D-418E-B55F-9AB4C31C5B38", "Blog Post", """
                Rewrite this transcript as a well-crafted blog post that stands entirely on its own — a reader who never heard the original should find it clear, engaging, and complete. Never reference "the transcript" or "the recording."

                **Title** — Specific and compelling. Not clickbait, not boring.

                **Opening** — Hook the reader with the most interesting or surprising point. No throat-clearing or background preamble.

                **Body** — Develop the key ideas in a logical flow. Use direct quotes from speakers to add texture and credibility (attribute them by name). Break up dense sections with subheadings.

                **Closing** — End with a takeaway, provocation, or call to reflection — not a generic "In conclusion."

                Write in a clear, conversational tone. Vary sentence length. Cut filler. If the original conversation wandered or repeated itself, reorganize for the reader's benefit — the post should be tighter than the transcript, not a 1:1 rewrite.
                """, order: 4, now: now),
            result("F87B8B91-6EAD-4E48-B9D3-4D56E0FAE679", "What Stood Out", """
                Read this transcript closely and surface what's easy to miss. Don't summarize — the reader already knows what was discussed. Instead, focus on:

                **Underlying Tensions** — Where did people talk past each other, avoid a topic, or agree too quickly? What wasn't said that probably should have been?

                **Surprising Moments** — Anything unexpected: a reversal of position, an offhand remark that revealed more than intended, a data point that contradicts the prevailing narrative.

                **Patterns** — Recurring themes, repeated concerns, or ideas that surfaced in different forms across the conversation. What's the through-line the participants themselves might not have named?

                **Strongest Claim, Weakest Evidence** — Identify the most confidently stated position that had the least support. Not adversarial — just flagging where the group might be over-indexing on confidence.

                Be specific and grounded in the text. Every observation should point to a concrete moment in the transcript. If you're speculating, say so.
                """, order: 5, now: now),
        ]
    }

    /// Polish, Distill and Decide on Control-Option-1/2/3 (bare Option digits type symbols on some layouts).
    static func builtInTransforms(now: Date) -> [TBDPrompt] {
        [
            transform("0FCE9DDB-7E2D-4B1A-AE3E-6F7C9B2A4D11", "Polish", """
                Rewrite the selected text so it reads like the best version of itself: clear, specific, finished. Preserve the author's intent, factual claims, structure, and level of formality.

                Remove hedging, filler, repetition, throat-clearing, and vague intensifiers. Prefer plain words over performative polish. Keep technical terms, names, code identifiers, URLs, numbers, and quoted text exactly intact.

                Do not change the register. If the input is casual, keep it casual; if formal, keep it formal. Do not add new ideas, examples, claims, apologies, or enthusiasm. Do not make it sound like marketing copy. Do not introduce AI tells ("delve," "comprehensive," "navigate the landscape of," "in today's fast-paced world"). If the input is a single short fragment (a label, a search query, a name), return it unchanged or with the smallest correction necessary.

                Return ONLY the rewritten text. No preamble, no quoting, no commentary, no headings.
                """, order: 100, hotkey: "ctrl+opt+1", label: "Polishing…", now: now),
            transform("1AD7C2B0-9C6F-4F0E-9C39-5E4D1F1D2A55", "Distill", """
                Compress the selected text to its signal. Reduce volume by 40–60% while keeping 100% of the actionable meaning.

                Identify the core point, the primary insight, or the bottom line. Discard the preamble, the connective tissue, and the throat-clearing. Replace passive voice and weak phrasing with active, precise verbs. Replace vague hedges with the specific claim underneath them.

                Architecture: use bullets when the input is a list of points or a sequence of ideas; use compact prose when it's a single argument. Don't lose the "why" — the reasoning behind a decision belongs in the distillation. Don't lose the "who" — if the input names people, parties, or systems, keep them.

                Match output shape to context: a Slack message becomes a tight paragraph, an email becomes a short list, a long doc becomes a few crisp bullets. The result should be readable in three seconds and lose nothing important.

                Return ONLY the distilled text. No preamble, no "Here is the condensed version," no meta-commentary.
                """, order: 101, hotkey: "ctrl+opt+2", label: "Distilling…", now: now),
            transform("2BE8D3C1-4A7F-4EBD-8F12-7C9A1E0B3D44", "Decide", """
                Rewrite the selected text as a decision-ready note. The reader is busy and needs to understand what is being decided and what should happen next.

                Separate signal from noise. Surface:
                - **The question** — what's actually being decided. State it explicitly, even if the input only implied it.
                - **The options** — the live choices, named clearly. Drop dead options unless their absence would surprise the reader.
                - **The tradeoffs** — what each option costs and what it buys. One clean line each, no padding.
                - **The recommendation** — your suggested next move, with a single-sentence reason. If the input already chose, make the choice explicit.
                - **The block** — if there isn't enough information to decide yet, name the smallest concrete question that must be answered next.

                Honor unresolved disagreement when it's there — don't flatten it into false consensus. Don't manufacture pros-and-cons that the input doesn't support. Don't invent data. Don't write a strategy memo unless the input warrants one — most decisions earn a paragraph, not a page.

                Return ONLY the rewritten note. No preamble, no "Here is the decision-ready version," no headings beyond what the structure above requires.
                """, order: 102, hotkey: "ctrl+opt+3", label: "Deciding…", now: now),
        ]
    }
}

extension TBDQuickPromptItem {
    public static func builtIns(now: Date = Date()) -> [TBDQuickPromptItem] {
        func item(_ id: String, _ label: String, _ group: String?, _ order: Int, pinned: Bool, _ prompt: String) -> TBDQuickPromptItem {
            TBDQuickPromptItem(id: id.lowercased(), label: label, prompt: prompt, groupLabel: group, sortOrder: order,
                               isPinned: pinned, isBuiltIn: true, createdAt: now)
        }
        return [
            item("242D9804-A7C5-4C0A-8A7A-B075957BC1E5", "Summarize so far", "CATCH UP", 0, pinned: false,
                 "Give a concise summary of the meeting so far. Focus on the main topics, decisions made, and any clear conclusions. Skip verbal filler."),
            item("7218D518-9B15-41C1-B5A9-060FD1BB5554", "What did I miss?", "CATCH UP", 1, pinned: false,
                 "Catch me up on the most recent shifts in the meeting — the latest decisions, new arguments, or topic changes. Skip what was clearly settled earlier. Be terse, signal-rich."),
            item("6D0E7D82-50C1-48A3-B485-6616DC273D18", "Decisions made", "CAPTURE", 2, pinned: false,
                 "List the decisions reached in the meeting so far. For each, note what was decided and the brief context that explains why. Skip topics that were only discussed without a decision."),
            item("F678E4F0-4128-4FD5-80FC-96D6EDC330BF", "Action items", "CAPTURE", 3, pinned: false,
                 "List concrete action items from the meeting so far — what needs to happen next, by whom, and by when if mentioned. Be specific. Skip vague intentions."),
            item("FEEDC4DD-D9B3-4AB0-BCCA-709A1517E23F", "Who owns what?", "CAPTURE", 4, pinned: false,
                 "Map who owns what from the meeting so far — assignments, commitments, areas of responsibility. If ownership for an item is unclear or unstated, flag that explicitly."),
            item("AE32274B-E3E7-4950-A16E-F1DF64660FB2", "What's unresolved?", "CHALLENGE", 5, pinned: false,
                 "List the open questions, unmade decisions, or topics still hanging from the meeting so far. Be specific."),
            item("7107DFB7-F2F0-44E6-864A-5FFD3BC45798", "What question is worth asking?", "CHALLENGE", 6, pinned: false,
                 "Based on the meeting so far, suggest one sharp, useful question I could ask next that would advance the discussion or surface something important that hasn't been addressed."),
            item("9A80A522-A54C-4A57-BA71-43F5F054714F", "What's worth pushing back on?", "CHALLENGE", 7, pinned: false,
                 "Identify any claims, assumptions, or decisions in the meeting so far that deserve scrutiny. What might be wrong, weak, or worth challenging?"),
            item("AFC8F517-E186-41C7-A39F-0BE0FAF4E9EA", "Where are we going in circles?", "CHALLENGE", 8, pinned: false,
                 "Have we revisited the same topic or argument without making progress? If so, point out where we're looping and what would actually move things forward."),
            item("9EC1C9BC-92BC-417E-ACC4-7F7633102DB1", "Tell me more", nil, 0, pinned: true,
                 "Expand on your previous response with more concrete detail from the meeting itself — quotes, specifics, who said what. Surface nuances or caveats you compressed out the first time."),
            item("DE860BF2-E6B2-4E05-9A77-D678F68FA86D", "Why?", nil, 1, pinned: true,
                 "Explain the reasoning behind your previous answer. What from the meeting transcript supports it?"),
            item("EB113B55-D5EE-44C1-A208-D5D5474CF4E2", "Give an example", nil, 2, pinned: true,
                 "Give one specific, concrete example that illustrates your previous response. Pull it from the meeting itself — a moment, exchange, or quote. If the meeting doesn't contain a clean example, say so plainly and offer the closest analogue."),
            item("3256EB3B-7436-4019-9367-7AAB5698B3EC", "Counter-argument?", nil, 3, pinned: true,
                 "What's the strongest counter-argument to your previous response? Steelman the opposing view, and use anything in the meeting that supports it."),
            item("D7216011-7568-4B1E-87E0-F32A5EF0EAA3", "TL;DR", nil, 4, pinned: true,
                 "Give the punchy, no-fluff TL;DR of your previous response — one or two sentences. No headers, no list, no preamble."),
        ]
    }

    public static func builtIn(id: String) -> TBDQuickPromptItem? { builtIns().first { $0.id == id } }
}
