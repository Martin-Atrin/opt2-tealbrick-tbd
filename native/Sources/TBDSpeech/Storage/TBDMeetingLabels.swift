import Foundation
import GRDB

// Labels: the one user-defined classification of v1 (MeetingClassification.swift). A label has a name and an
// optional color; a transcript (meeting, file, link) can carry any number of labels; a transcript prompt can be
// aimed at labels. v1 also had "meeting types" (one per meeting); v1 folded them into labels in its migration
// v0.37 and no screen of v1 sets a type any more, so types are not part of this port.

/// A label. Archived labels are not offered for new assignments or filters; assignments and prompt rules stay.
public struct TBDMeetingLabel: Codable, Sendable, Equatable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meetingLabel"
    public var id: String
    public var name: String
    /// One of `TBDLabelColor` tokens, or nil for the automatic color.
    public var colorToken: String?
    public var sortOrder: Int
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = tbdNewID(), name: String, colorToken: String? = nil, sortOrder: Int = 0, isArchived: Bool = false,
                createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.name = name; self.colorToken = colorToken; self.sortOrder = sortOrder; self.isArchived = isArchived
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

/// One label on one transcript.
public struct TBDTranscriptionLabel: Codable, Sendable, Equatable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcriptionLabel"
    public var transcriptionId: String
    public var labelId: String
    public init(transcriptionId: String, labelId: String) { self.transcriptionId = transcriptionId; self.labelId = labelId }
}

/// Where a transcript prompt is offered. An `all` row is the fallback; `label` rows that match a transcript win.
/// (v1 `PromptLabelPolicy`.)
public struct TBDPromptLabelPolicy: Codable, Sendable, Equatable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public enum ScopeKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible { case all, label }
    public static let databaseTableName = "promptLabelPolicy"
    public var id: String
    public var promptId: String
    public var scopeKind: ScopeKind
    public var labelId: String?
    public var isAvailable: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: String = tbdNewID(), promptId: String, scopeKind: ScopeKind, labelId: String? = nil, isAvailable: Bool,
                createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.promptId = promptId; self.scopeKind = scopeKind; self.labelId = labelId; self.isAvailable = isAvailable
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

public enum TBDLabelError: Error, LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case missingLabel
    case unavailable(Set<String>)
    case inUse

    public var errorDescription: String? {
        switch self {
        case .emptyName: "A label name is required."
        case .duplicateName(let name): "A label named '\(name)' already exists."
        case .missingLabel: "This label no longer exists."
        case .unavailable: "One or more selected labels do not exist or are archived."
        case .inUse: "This label is on transcripts. Archive it instead."
        }
    }
}

/// Pure rules for label names.
public enum TBDLabelRules {
    /// The trimmed name, or `emptyName`.
    public static func normalizedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TBDLabelError.emptyName }
        return trimmed
    }

    /// Names are unique ignoring case and accents (v1 compared with `.caseInsensitive, .diacriticInsensitive`),
    /// archived labels included. `excluding` is the label being renamed.
    public static func isDuplicate(_ name: String, among labels: [TBDMeetingLabel], excluding id: String? = nil) -> Bool {
        labels.contains {
            $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// Label order everywhere: sort order, then name ignoring case.
    public static func ordered(_ labels: [TBDMeetingLabel]) -> [TBDMeetingLabel] {
        labels.sorted {
            $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Labels whose name contains `query` (ignoring case); everything for an empty query.
    public static func matching(_ query: String, in labels: [TBDMeetingLabel]) -> [TBDMeetingLabel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? labels : labels.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }
}

/// The label colors of v1. Orange reads as coral and yellow as amber; anything else is automatic.
public enum TBDLabelColor: String, CaseIterable, Sendable, Identifiable {
    case automatic, coral, green, amber, red, purple, blue
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    /// The token stored on the label; nil for automatic.
    public var token: String? { self == .automatic ? nil : rawValue }

    public init(token: String?) {
        switch token?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "coral", "orange": self = .coral
        case "green": self = .green
        case "amber", "yellow": self = .amber
        case "red": self = .red
        case "purple": self = .purple
        case "blue": self = .blue
        default: self = .automatic
        }
    }

    /// Palette slot of an automatic color: FNV-1a (64 bit) over the label id, so a label keeps its color.
    /// v1 hashed the 16 UUID bytes; ids that are not UUIDs hash their UTF-8 bytes.
    public static func automaticSlot(for id: String, paletteCount: Int) -> Int {
        guard paletteCount > 0 else { return 0 }
        var hash: UInt64 = 1_469_598_103_934_665_603
        let bytes: [UInt8]
        if let uuid = UUID(uuidString: id) {
            bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        } else {
            bytes = Array(id.utf8)
        }
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(paletteCount))
    }
}

/// Which prompts a labelled transcript is offered, and which run by themselves (v1 `PromptLabelApplicabilityResolver`).
public enum TBDPromptLabelResolver {
    public enum Reason: String, Sendable, Equatable {
        case hidden, notResultPrompt, noLabelTargeting, matchingLabelPolicy, allLabelsPolicy, noMatchingLabelPolicy
    }

    public struct Resolution: Sendable, Equatable {
        public var isAvailable: Bool
        public var isAutoRun: Bool
        public var reason: Reason
        public init(isAvailable: Bool, isAutoRun: Bool, reason: Reason) {
            self.isAvailable = isAvailable; self.isAutoRun = isAvailable && isAutoRun; self.reason = reason
        }
    }

    /// No rules: offered everywhere. Otherwise a matching label rule decides (any available match offers it);
    /// without a match the `all` rule decides; with neither it is not offered. Hidden prompts and Transforms are
    /// never offered. Auto-run also needs the prompt's own auto-run setting for the source.
    public static func resolve(prompt: TBDPrompt, source: TBDSourceKind, labelIDs: Set<String>, policies: [TBDPromptLabelPolicy]) -> Resolution {
        guard prompt.isVisible else { return Resolution(isAvailable: false, isAutoRun: false, reason: .hidden) }
        guard prompt.category == .result else { return Resolution(isAvailable: false, isAutoRun: false, reason: .notResultPrompt) }
        guard !policies.isEmpty else {
            return Resolution(isAvailable: true, isAutoRun: prompt.autoRuns(for: source), reason: .noLabelTargeting)
        }
        let matching = policies.filter { $0.scopeKind == .label && $0.labelId.map(labelIDs.contains) == true }
        if !matching.isEmpty {
            let available = matching.contains(where: \.isAvailable)
            return Resolution(isAvailable: available, isAutoRun: available && prompt.autoRuns(for: source), reason: .matchingLabelPolicy)
        }
        if let fallback = policies.first(where: { $0.scopeKind == .all && $0.labelId == nil }) {
            return Resolution(isAvailable: fallback.isAvailable, isAutoRun: fallback.isAvailable && prompt.autoRuns(for: source), reason: .allLabelsPolicy)
        }
        return Resolution(isAvailable: false, isAutoRun: false, reason: .noMatchingLabelPolicy)
    }

    /// The labels a prompt is aimed at: empty when it is offered everywhere (no rules, or an available `all` rule
    /// only), otherwise the labels with an available rule next to an unavailable `all` rule.
    public static func targetLabelIDs(policies: [TBDPromptLabelPolicy]) -> Set<String> {
        guard policies.contains(where: { $0.scopeKind == .all && !$0.isAvailable }) else { return [] }
        return Set(policies.compactMap { $0.scopeKind == .label && $0.isAvailable ? $0.labelId : nil })
    }

    /// The rules for "aim this prompt at these labels": none for an empty selection (offered everywhere), else an
    /// unavailable `all` rule plus one available rule per label (v1 `replaceTargetLabels`).
    public static func policies(promptId: String, targeting labelIDs: Set<String>, now: Date = Date()) -> [TBDPromptLabelPolicy] {
        guard !labelIDs.isEmpty else { return [] }
        return [TBDPromptLabelPolicy(promptId: promptId, scopeKind: .all, isAvailable: false, createdAt: now)]
            + labelIDs.sorted().map { TBDPromptLabelPolicy(promptId: promptId, scopeKind: .label, labelId: $0, isAvailable: true, createdAt: now) }
    }
}
