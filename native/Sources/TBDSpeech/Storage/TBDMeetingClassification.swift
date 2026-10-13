import Foundation
import GRDB

/// Schema and storage for labels (see `TBDMeetingLabels.swift`). Migration `v7-meeting-classification`.
public enum TBDMeetingClassification {
    static func migrate(_ db: Database) throws {
        try db.create(table: "meetingLabel") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("colorToken", .text)
            t.column("sortOrder", .integer).notNull().defaults(to: 0)
            t.column("isArchived", .boolean).notNull().defaults(to: false)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.execute(sql: "CREATE UNIQUE INDEX meetingLabel_name ON meetingLabel(name COLLATE NOCASE)")
        try db.create(table: "transcriptionLabel") { t in
            t.column("transcriptionId", .text).notNull().references("transcription", onDelete: .cascade)
            t.column("labelId", .text).notNull().references("meetingLabel", onDelete: .cascade)
            t.primaryKey(["transcriptionId", "labelId"])
        }
        try db.create(index: "transcriptionLabel_label", on: "transcriptionLabel", columns: ["labelId", "transcriptionId"])
        try db.create(table: "promptLabelPolicy") { t in
            t.primaryKey("id", .text)
            t.column("promptId", .text).notNull().references("prompt", onDelete: .cascade)
            t.column("scopeKind", .text).notNull()
            t.column("labelId", .text).references("meetingLabel", onDelete: .cascade)
            t.column("isAvailable", .boolean).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.check(sql: "(scopeKind = 'all' AND labelId IS NULL) OR (scopeKind = 'label' AND labelId IS NOT NULL)")
        }
        try db.execute(sql: "CREATE UNIQUE INDEX promptLabelPolicy_all ON promptLabelPolicy(promptId) WHERE scopeKind = 'all'")
        try db.execute(sql: "CREATE UNIQUE INDEX promptLabelPolicy_label ON promptLabelPolicy(promptId, labelId) WHERE scopeKind = 'label'")
        try db.create(index: "promptLabelPolicy_lookup", on: "promptLabelPolicy", columns: ["labelId", "promptId"])
    }
}

extension TBDListeningDatabase {
    // MARK: - Labels

    /// Labels in display order. Archived ones only when asked for.
    public func meetingLabels(includeArchived: Bool = false) throws -> [TBDMeetingLabel] {
        try writer.read { db in
            var request = TBDMeetingLabel.all()
            if !includeArchived { request = request.filter(Column("isArchived") == false) }
            return try request.order(Column("sortOrder"), Column("name").collating(.nocase)).fetchAll(db)
        }
    }

    public func meetingLabel(id: String) throws -> TBDMeetingLabel? { try writer.read { try TBDMeetingLabel.fetchOne($0, key: id) } }

    /// Creates a label after the existing ones. The name is trimmed and must be new (ignoring case and accents).
    @discardableResult
    public func createMeetingLabel(name: String, colorToken: String? = nil) throws -> TBDMeetingLabel {
        let trimmed = try TBDLabelRules.normalizedName(name)
        return try writer.write { db in
            guard !TBDLabelRules.isDuplicate(trimmed, among: try TBDMeetingLabel.fetchAll(db)) else { throw TBDLabelError.duplicateName(trimmed) }
            let visible = try TBDMeetingLabel.filter(Column("isArchived") == false).fetchCount(db)
            let label = TBDMeetingLabel(name: trimmed, colorToken: colorToken, sortOrder: visible)
            try label.insert(db)
            return label
        }
    }

    public func renameMeetingLabel(id: String, to name: String) throws {
        let trimmed = try TBDLabelRules.normalizedName(name)
        try writer.write { db in
            guard var label = try TBDMeetingLabel.fetchOne(db, key: id) else { throw TBDLabelError.missingLabel }
            guard !TBDLabelRules.isDuplicate(trimmed, among: try TBDMeetingLabel.fetchAll(db), excluding: id) else { throw TBDLabelError.duplicateName(trimmed) }
            label.name = trimmed
            label.updatedAt = Date()
            try label.update(db)
        }
    }

    /// Sets the color (`TBDLabelColor` token); nil means automatic.
    public func setMeetingLabelColor(id: String, token: String?) throws {
        try writer.write { db in
            guard var label = try TBDMeetingLabel.fetchOne(db, key: id) else { throw TBDLabelError.missingLabel }
            label.colorToken = token
            label.updatedAt = Date()
            try label.update(db)
        }
    }

    /// Archives or restores a label. Assignments and prompt rules stay either way.
    public func setMeetingLabelArchived(id: String, isArchived: Bool) throws {
        try writer.write { db in
            guard var label = try TBDMeetingLabel.fetchOne(db, key: id) else { throw TBDLabelError.missingLabel }
            label.isArchived = isArchived
            label.updatedAt = Date()
            try label.update(db)
        }
    }

    /// Deletes a label that is on no transcript (v1 rule); a label in use throws `inUse`. Prompt rules for it go too.
    public func deleteMeetingLabel(id: String) throws {
        try writer.write { db in
            let used = try TBDTranscriptionLabel.filter(Column("labelId") == id).fetchCount(db) > 0
            guard !used else { throw TBDLabelError.inUse }
            _ = try TBDMeetingLabel.deleteOne(db, key: id)
        }
    }

    /// How many transcripts carry each label.
    public func meetingLabelUseCounts() throws -> [String: Int] {
        try writer.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT labelId, COUNT(*) AS n FROM transcriptionLabel GROUP BY labelId")
                .map { ($0["labelId"] as String, $0["n"] as Int) })
        }
    }

    // MARK: - Assignment

    /// A transcript's labels in display order, archived ones included (they stay on it).
    public func labels(for transcriptionId: String) throws -> [TBDMeetingLabel] {
        try writer.read { db in
            try TBDMeetingLabel.fetchAll(db, sql: """
                SELECT meetingLabel.* FROM meetingLabel JOIN transcriptionLabel ON transcriptionLabel.labelId = meetingLabel.id
                WHERE transcriptionLabel.transcriptionId = ?
                ORDER BY meetingLabel.sortOrder ASC, meetingLabel.name COLLATE NOCASE ASC
                """, arguments: [transcriptionId])
        }
    }

    public func labelIDs(for transcriptionId: String) throws -> Set<String> {
        try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT labelId FROM transcriptionLabel WHERE transcriptionId = ?", arguments: [transcriptionId]))
        }
    }

    /// Replaces a transcript's labels. Labels it already has are kept even when archived; any other label must
    /// exist and not be archived (v1 rule). One transaction.
    public func setLabels(_ labelIDs: Set<String>, for transcriptionId: String) throws {
        try writer.write { db in
            guard try TBDTranscription.exists(db, key: transcriptionId) else { return }
            let current = Set(try String.fetchAll(db, sql: "SELECT labelId FROM transcriptionLabel WHERE transcriptionId = ?", arguments: [transcriptionId]))
            let added = labelIDs.subtracting(current)
            if !added.isEmpty {
                let usable = Set(try TBDMeetingLabel.filter(added.contains(Column("id"))).filter(Column("isArchived") == false).fetchAll(db).map(\.id))
                let unavailable = added.subtracting(usable)
                guard unavailable.isEmpty else { throw TBDLabelError.unavailable(unavailable) }
            }
            try db.execute(sql: "DELETE FROM transcriptionLabel WHERE transcriptionId = ?", arguments: [transcriptionId])
            for id in labelIDs.sorted() { try TBDTranscriptionLabel(transcriptionId: transcriptionId, labelId: id).insert(db) }
            try db.execute(sql: "UPDATE transcription SET updatedAt = ? WHERE id = ?", arguments: [Date(), transcriptionId])
        }
    }

    /// Adds the label when the transcript lacks it, removes it when it has it.
    public func toggleLabel(_ labelId: String, for transcriptionId: String) throws {
        var ids = try labelIDs(for: transcriptionId)
        if !ids.insert(labelId).inserted { ids.remove(labelId) }
        try setLabels(ids, for: transcriptionId)
    }

    /// Ids of the transcripts that carry ANY of the labels (the list filter). Empty input means no filter: nil.
    public func transcriptionIDs(withAnyLabel labelIDs: Set<String>) throws -> Set<String>? {
        guard !labelIDs.isEmpty else { return nil }
        return try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT transcriptionId FROM transcriptionLabel WHERE labelId IN (\(labelIDs.map { _ in "?" }.joined(separator: ",")))",
                                    arguments: StatementArguments(labelIDs.sorted())))
        }
    }

    // MARK: - Prompts aimed at labels

    public func promptLabelPolicies(promptIds: Set<String>) throws -> [TBDPromptLabelPolicy] {
        guard !promptIds.isEmpty else { return [] }
        return try writer.read { db in
            try TBDPromptLabelPolicy.filter(promptIds.contains(Column("promptId"))).order(Column("promptId"), Column("scopeKind"), Column("createdAt")).fetchAll(db)
        }
    }

    /// Labels a prompt is aimed at; empty when it is offered for every transcript.
    public func targetLabelIDs(promptId: String) throws -> Set<String> {
        TBDPromptLabelResolver.targetLabelIDs(policies: try promptLabelPolicies(promptIds: [promptId]))
    }

    /// Aims a prompt at labels, or at every transcript again when `labelIDs` is empty. One transaction.
    public func setTargetLabels(_ labelIDs: Set<String>, promptId: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM promptLabelPolicy WHERE promptId = ?", arguments: [promptId])
            for policy in TBDPromptLabelResolver.policies(promptId: promptId, targeting: labelIDs) { try policy.insert(db) }
        }
    }

    /// Visible transcript prompts with what the label rules say for a transcript of `source` carrying `labelIDs`.
    public func resolvedResultPrompts(source: TBDSourceKind, labelIDs: Set<String>) throws -> [(prompt: TBDPrompt, resolution: TBDPromptLabelResolver.Resolution)] {
        let prompts = try prompts(category: .result, visibleOnly: true)
        let policies = Dictionary(grouping: try promptLabelPolicies(promptIds: Set(prompts.map(\.id))), by: \.promptId)
        return prompts.map { ($0, TBDPromptLabelResolver.resolve(prompt: $0, source: source, labelIDs: labelIDs, policies: policies[$0.id] ?? [])) }
    }

    /// Prompts that run by themselves after a transcription of `source` with `labelIDs` finishes.
    public func autoRunPrompts(for source: TBDSourceKind, labelIDs: Set<String>) throws -> [TBDPrompt] {
        try resolvedResultPrompts(source: source, labelIDs: labelIDs).filter(\.resolution.isAutoRun).map(\.prompt)
    }

    /// The transcript prompts offered for one transcript (its source and labels), in library order.
    public func availableResultPrompts(for transcriptionId: String) throws -> [TBDPrompt] {
        guard let item = try transcription(id: transcriptionId) else { return [] }
        return try resolvedResultPrompts(source: item.sourceKind, labelIDs: try labelIDs(for: item.id)).filter(\.resolution.isAvailable).map(\.prompt)
    }
}
