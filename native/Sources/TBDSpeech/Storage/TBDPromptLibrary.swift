import Foundation
import GRDB

public enum TBDPromptLibraryError: Error, LocalizedError, Equatable {
    case emptyName
    case promptNotFound
    case promptDeleted
    case versionNotFound
    case versionBelongsToDifferentPrompt
    case invalidHotkey(String)
    case emptyCollectionName
    case duplicateCollectionName(String)
    case collectionNotFound(String)
    case invalidOrder

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Give the prompt a name."
        case .promptNotFound: "That prompt no longer exists."
        case .promptDeleted: "That prompt is in the trash. Restore it first."
        case .versionNotFound: "That version no longer exists."
        case .versionBelongsToDifferentPrompt: "That version belongs to a different prompt."
        case .invalidHotkey(let reason): "Hotkey not saved: \(reason)"
        case .emptyCollectionName: "Collection name can't be empty."
        case .duplicateCollectionName(let name): "A prompt collection named \(name) already exists."
        case .collectionNotFound(let id): "Prompt collection \(id) doesn't exist."
        case .invalidOrder: "The order must contain every item exactly once."
        }
    }
}

/// Schema and one-time setup for the prompt library.
public enum TBDPromptLibrary {
    /// Migration `v6-prompts-transforms`.
    static func migrate(_ db: Database) throws {
        try db.create(table: "promptCollection") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("colorToken", .text)
            t.column("sortOrder", .integer).notNull().defaults(to: 0)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(table: "prompt") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("content", .text).notNull()
            t.column("category", .text).notNull().indexed()
            t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
            t.column("isVisible", .boolean).notNull().defaults(to: true)
            t.column("isAutoRun", .boolean).notNull().defaults(to: false)
            t.column("appliesToSources", .jsonText)
            t.column("sortOrder", .integer).notNull().defaults(to: 0)
            t.column("hotkey", .text)
            t.column("runningLabel", .text)
            t.column("inference", .jsonText)
            t.column("modelOverride", .text)
            t.column("includeMeetingNotes", .boolean).notNull().defaults(to: false)
            t.column("collectionId", .text).indexed().references("promptCollection", onDelete: .setNull)
            t.column("activeVersionId", .text)
            t.column("userCustomizedAt", .datetime)
            t.column("deletedAt", .datetime)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(table: "promptVersion") { t in
            t.primaryKey("id", .text)
            t.column("promptId", .text).notNull().indexed().references("prompt", onDelete: .cascade)
            t.column("versionNumber", .integer).notNull()
            t.column("content", .text).notNull()
            t.column("inference", .jsonText)
            t.column("modelOverride", .text)
            t.column("origin", .text).notNull()
            t.column("changeNote", .text)
            t.column("createdAt", .datetime).notNull()
            t.uniqueKey(["promptId", "versionNumber"])
        }
        try db.create(table: "quickPrompt") { t in
            t.primaryKey("id", .text)
            t.column("label", .text).notNull()
            t.column("prompt", .text).notNull()
            t.column("groupLabel", .text)
            t.column("sortOrder", .integer).notNull().defaults(to: 0)
            t.column("isVisible", .boolean).notNull().defaults(to: true)
            t.column("isPinned", .boolean).notNull().defaults(to: false)
            t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(table: "transformRun") { t in
            t.primaryKey("id", .text)
            t.column("transformId", .text)
            t.column("transformName", .text).notNull()
            t.column("inputText", .text).notNull()
            t.column("outputText", .text).notNull()
            t.column("sourceAppBundleID", .text)
            t.column("sourceAppName", .text)
            t.column("capturePath", .text).notNull()
            t.column("replacementPath", .text).notNull()
            t.column("llmElapsedMs", .integer).notNull().defaults(to: 0)
            t.column("totalElapsedMs", .integer).notNull().defaults(to: 0)
            t.column("createdAt", .datetime).notNull().indexed()
        }
        // One-time steps (seeding, settings import) are recorded here so they never repeat.
        try db.create(table: "promptLibraryState") { t in
            t.primaryKey("key", .text)
            t.column("value", .text).notNull()
        }
        // Which library prompt (and version) made each summary; several per transcript.
        try db.alter(table: "summary") { t in
            t.add(column: "promptId", .text)
            t.add(column: "promptVersionId", .text)
            t.add(column: "promptName", .text)
            t.add(column: "extraInstructions", .text)
        }
    }

    enum Step: String { case seeded, importedSummaryPrompt, importedTransformPrompts }

    static func done(_ step: Step, _ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM promptLibraryState WHERE key = ?)", arguments: [step.rawValue]) ?? false
    }

    static func mark(_ step: Step, _ db: Database, now: Date) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO promptLibraryState (key, value) VALUES (?, ?)",
                       arguments: [step.rawValue, ISO8601DateFormatter().string(from: now)])
    }
}

extension TBDListeningDatabase {
    // MARK: - Setup

    /// Seeds the built-in prompts, Transforms and quick prompts, then imports the old
    /// `summaryPrompt` and `transformPrompts` settings. Each step runs once per library.
    /// After the import the old single transform hotkey lives on its Transform, so the setting is cleared.
    public func preparePromptLibrary(preferences: TBDListeningPreferences, now: Date = Date()) throws {
        let carriedHotkey = try writer.write { db -> Bool in
            if try !TBDPromptLibrary.done(.seeded, db) {
                for prompt in TBDPrompt.builtIns(now: now) where try TBDPrompt.fetchOne(db, key: prompt.id) == nil {
                    _ = try Self.insertPrompt(prompt, origin: .systemUpdate, changeNote: nil, db: db)
                }
                for item in TBDQuickPromptItem.builtIns(now: now) where try TBDQuickPromptItem.fetchOne(db, key: item.id) == nil {
                    try item.insert(db)
                }
                try TBDPromptLibrary.mark(.seeded, db, now: now)
            }
            if try !TBDPromptLibrary.done(.importedSummaryPrompt, db) {
                try Self.importSummaryPrompt(preferences, db: db, now: now)
                try TBDPromptLibrary.mark(.importedSummaryPrompt, db, now: now)
            }
            var carried = false
            if try !TBDPromptLibrary.done(.importedTransformPrompts, db) {
                carried = try Self.importTransformPrompts(preferences, db: db, now: now)
                try TBDPromptLibrary.mark(.importedTransformPrompts, db, now: now)
            }
            return carried
        }
        if carriedHotkey { preferences.transformHotkey = "" }
    }

    /// A customised summary prompt becomes the next version of the built-in Summary prompt
    /// (the default and auto-run prompt), so summaries keep using the person's text.
    static func importSummaryPrompt(_ preferences: TBDListeningPreferences, db: Database, now: Date) throws {
        guard let stored = preferences.defaults.string(forKey: TBDListeningPreferences.Key.summaryPrompt) else { return }
        let text = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != TBDListeningPreferences.defaultSummaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
              var summary = try TBDPrompt.fetchOne(db, key: TBDPrompt.summaryID), summary.deletedAt == nil else { return }
        summary.content = stored
        summary.updatedAt = now
        _ = try updatePrompt(summary, origin: .import, changeNote: "Imported from the summary prompt setting", db: db)
    }

    /// Saved transform prompts become user Transforms. The old transform hotkey moves onto the
    /// Transform it used to run (importing that default if the list was never saved).
    /// Returns true when the hotkey was carried over.
    static func importTransformPrompts(_ preferences: TBDListeningPreferences, db: Database, now: Date) throws -> Bool {
        let storedList = preferences.defaults.data(forKey: TBDListeningPreferences.Key.transformPrompts)
            .flatMap { try? JSONDecoder().decode([TBDTransformPrompt].self, from: $0) } ?? []
        let hotkey = (try? TBDHotkey.parse(preferences.transformHotkey))?.serialized
        let currentID = preferences.transformPromptID
        var toImport = storedList
        if hotkey != nil, !toImport.contains(where: { $0.id == currentID }) {
            if let fallback = TBDTransformPrompt.defaults.first(where: { $0.id == currentID }) ?? (toImport.isEmpty ? TBDTransformPrompt.defaults.first : nil) {
                toImport.append(fallback)
            }
        }
        let base = (try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM prompt WHERE category = 'transform'") ?? 199) + 1
        var carried = false
        let hotkeyTarget = toImport.first(where: { $0.id == currentID })?.id ?? toImport.first?.id
        for (index, old) in toImport.enumerated() {
            let name = old.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = old.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !content.isEmpty else { continue }
            let assign = hotkey != nil && old.id == hotkeyTarget
            let prompt = TBDPrompt(name: name, content: content, category: .transform, sortOrder: max(base, 200) + index,
                                   hotkey: assign ? hotkey : nil, createdAt: now)
            _ = try insertPrompt(prompt, origin: .import, changeNote: "Imported from the transform prompts setting", db: db)
            if assign {
                carried = true
                preferences.transformPromptID = prompt.id
            }
        }
        return carried
    }

    // MARK: - Prompts

    /// Prompts not in the trash, in library order.
    public func prompts(category: TBDPrompt.Category? = nil, visibleOnly: Bool = false) throws -> [TBDPrompt] {
        try writer.read { db in
            var request = TBDPrompt.filter(Column("deletedAt") == nil)
            if let category { request = request.filter(Column("category") == category.rawValue) }
            if visibleOnly { request = request.filter(Column("isVisible") == true) }
            return try request.order(Column("sortOrder"), Column("name").collating(.nocase)).fetchAll(db)
        }
    }

    public func prompt(id: String) throws -> TBDPrompt? {
        try writer.read { db in try TBDPrompt.filter(key: id).filter(Column("deletedAt") == nil).fetchOne(db) }
    }

    /// Prompts in the trash, most recently deleted first.
    public func deletedPrompts() throws -> [TBDPrompt] {
        try writer.read { db in try TBDPrompt.filter(Column("deletedAt") != nil).order(Column("deletedAt").desc).fetchAll(db) }
    }

    /// The prompt preselected for summaries: the first visible auto-run prompt, else the first visible one.
    public func defaultSummaryPrompt() throws -> TBDPrompt? {
        let visible = try prompts(category: .result, visibleOnly: true)
        return visible.first(where: \.isAutoRun) ?? visible.first
    }

    /// Prompts that run automatically after a transcription of `source` finishes.
    public func autoRunPrompts(for source: TBDSourceKind) throws -> [TBDPrompt] {
        try prompts(category: .result, visibleOnly: true).filter { $0.autoRuns(for: source) }
    }

    /// Creates or updates a prompt. A change to the instructions, generation settings or model
    /// override makes a new version; name and other metadata do not.
    @discardableResult
    public func savePrompt(_ prompt: TBDPrompt, origin: TBDPromptVersion.Origin = .user, changeNote: String? = nil) throws -> TBDPrompt {
        var candidate = prompt
        candidate.name = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.name.isEmpty else { throw TBDPromptLibraryError.emptyName }
        candidate.inference = try prompt.inference?.validated()
        candidate.hotkey = try Self.normalizedHotkey(prompt.hotkey)
        candidate.modelOverride = prompt.modelOverride.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        candidate.runningLabel = prompt.runningLabel.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        if candidate.category == .transform { candidate.isAutoRun = false; candidate.includeMeetingNotes = false; candidate.appliesToSources = nil }
        candidate.updatedAt = Date()
        return try writer.write { db in
            if try TBDPrompt.fetchOne(db, key: candidate.id) == nil {
                // New prompts go after the last prompt of their kind (built-ins stay first).
                let last = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM prompt WHERE category = ?", arguments: [candidate.category.rawValue]) ?? -1
                candidate.sortOrder = max(candidate.sortOrder, last + 1)
                return try Self.insertPrompt(candidate, origin: origin, changeNote: changeNote, db: db)
            }
            return try Self.updatePrompt(candidate, origin: origin, changeNote: changeNote, db: db)
        }
    }

    static func normalizedHotkey(_ value: String?) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let hotkey: TBDHotkey
        do { hotkey = try TBDHotkey.parse(value) } catch { throw TBDPromptLibraryError.invalidHotkey(error.localizedDescription) }
        // v1 rules: warned keys (a bare letter) are allowed, blocked ones are refused.
        if case .blocked(let reason) = hotkey.validation { throw TBDPromptLibraryError.invalidHotkey(reason) }
        return hotkey.serialized
    }

    static func insertPrompt(_ prompt: TBDPrompt, origin: TBDPromptVersion.Origin, changeNote: String?, db: Database) throws -> TBDPrompt {
        let version = TBDPromptVersion(promptId: prompt.id, versionNumber: 1, content: prompt.content, inference: prompt.inference,
                                       modelOverride: prompt.modelOverride, origin: origin, changeNote: changeNote, createdAt: prompt.createdAt)
        var stored = prompt
        stored.activeVersionId = version.id
        try stored.insert(db)
        try version.insert(db)
        return stored
    }

    static func updatePrompt(_ candidate: TBDPrompt, origin: TBDPromptVersion.Origin, changeNote: String?,
                             forceVersion: Bool = false, db: Database) throws -> TBDPrompt {
        guard let existing = try TBDPrompt.fetchOne(db, key: candidate.id) else { throw TBDPromptLibraryError.promptNotFound }
        guard existing.deletedAt == nil else { throw TBDPromptLibraryError.promptDeleted }
        let versionChanged = forceVersion || candidate.content != existing.content || candidate.inference != existing.inference
            || candidate.modelOverride != existing.modelOverride
        var stored = candidate
        stored.isBuiltIn = existing.isBuiltIn
        stored.createdAt = existing.createdAt
        stored.deletedAt = nil
        stored.activeVersionId = existing.activeVersionId
        stored.userCustomizedAt = existing.userCustomizedAt
        if versionChanged {
            let next = (try Int.fetchOne(db, sql: "SELECT MAX(versionNumber) FROM promptVersion WHERE promptId = ?", arguments: [candidate.id]) ?? 0) + 1
            let version = TBDPromptVersion(promptId: candidate.id, versionNumber: next, content: candidate.content, inference: candidate.inference,
                                           modelOverride: candidate.modelOverride, origin: origin, changeNote: changeNote, createdAt: candidate.updatedAt)
            try version.insert(db)
            stored.activeVersionId = version.id
        }
        // Only the person's own edits customise a built-in; shipped updates and settings imports do not.
        if existing.isBuiltIn, origin == .user || origin == .restore, versionChanged || candidate.name != existing.name {
            stored.userCustomizedAt = existing.userCustomizedAt ?? candidate.updatedAt
        }
        try stored.update(db)
        return stored
    }

    /// Every version of a prompt, newest first.
    public func promptVersions(promptId: String) throws -> [TBDPromptVersion] {
        try writer.read { db in
            try TBDPromptVersion.filter(Column("promptId") == promptId).order(Column("versionNumber").desc).fetchAll(db)
        }
    }

    /// Makes an earlier version current again, as a new version (history is never rewritten).
    @discardableResult
    public func restorePromptVersion(promptId: String, versionId: String, changeNote: String? = nil) throws -> TBDPrompt {
        try writer.write { db in
            guard let prompt = try TBDPrompt.fetchOne(db, key: promptId) else { throw TBDPromptLibraryError.promptNotFound }
            guard prompt.deletedAt == nil else { throw TBDPromptLibraryError.promptDeleted }
            guard let source = try TBDPromptVersion.fetchOne(db, key: versionId) else { throw TBDPromptLibraryError.versionNotFound }
            guard source.promptId == promptId else { throw TBDPromptLibraryError.versionBelongsToDifferentPrompt }
            var restored = prompt
            restored.content = source.content
            restored.inference = source.inference
            restored.modelOverride = source.modelOverride
            restored.updatedAt = Date()
            return try Self.updatePrompt(restored, origin: .restore, changeNote: changeNote ?? "Restored version \(source.versionNumber)",
                                         forceVersion: true, db: db)
        }
    }

    /// Puts the built-in's shipped text, name and hotkey back as a new version.
    @discardableResult
    public func resetBuiltInPrompt(id: String) throws -> TBDPrompt {
        guard let canonical = TBDPrompt.builtIn(id: id) else { throw TBDPromptLibraryError.promptNotFound }
        return try writer.write { db in
            guard var prompt = try TBDPrompt.fetchOne(db, key: id) else { throw TBDPromptLibraryError.promptNotFound }
            if prompt.deletedAt != nil {
                prompt.deletedAt = nil
                try prompt.update(db)
            }
            prompt.name = canonical.name
            prompt.content = canonical.content
            prompt.inference = nil
            prompt.modelOverride = nil
            prompt.hotkey = canonical.hotkey
            prompt.runningLabel = canonical.runningLabel
            prompt.updatedAt = Date()
            var stored = try Self.updatePrompt(prompt, origin: .systemUpdate, changeNote: "Reset to the built-in text", db: db)
            stored.userCustomizedAt = nil
            try stored.update(db)
            return stored
        }
    }

    /// Moves a prompt to the trash. Its version history stays.
    @discardableResult
    public func deletePrompt(id: String) throws -> Bool {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: """
                UPDATE prompt SET deletedAt = ?, updatedAt = ?,
                    userCustomizedAt = CASE WHEN isBuiltIn = 1 THEN COALESCE(userCustomizedAt, ?) ELSE userCustomizedAt END
                WHERE id = ? AND deletedAt IS NULL
                """, arguments: [now, now, now, id])
            return db.changesCount > 0
        }
    }

    /// Brings a prompt back from the trash, renamed "(Restored)" if its name is taken meanwhile.
    @discardableResult
    public func restoreDeletedPrompt(id: String) throws -> Bool {
        try writer.write { db in
            guard let prompt = try TBDPrompt.fetchOne(db, key: id), prompt.deletedAt != nil else { return false }
            func taken(_ name: String) throws -> Bool {
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM prompt WHERE name = ? COLLATE NOCASE AND deletedAt IS NULL AND id != ?)",
                                  arguments: [name, id]) ?? false
            }
            var name = prompt.name
            var suffix = 1
            while try taken(name) {
                name = suffix == 1 ? "\(prompt.name) (Restored)" : "\(prompt.name) (Restored \(suffix))"
                suffix += 1
            }
            try db.execute(sql: "UPDATE prompt SET name = ?, deletedAt = NULL, updatedAt = ? WHERE id = ?", arguments: [name, Date(), id])
            return db.changesCount > 0
        }
    }

    /// Restores every built-in of a category that is in the trash ("Restore missing defaults").
    public func restoreMissingBuiltIns(category: TBDPrompt.Category) throws {
        for prompt in try deletedPrompts() where prompt.isBuiltIn && prompt.category == category {
            try restoreDeletedPrompt(id: prompt.id)
        }
    }

    /// Shows hidden built-ins again; built-in transcript prompts go back to every source.
    public func restorePromptDefaults() throws {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: "UPDATE prompt SET isVisible = 1, appliesToSources = NULL, updatedAt = ? WHERE isBuiltIn = 1 AND category = 'result' AND deletedAt IS NULL", arguments: [now])
            try db.execute(sql: "UPDATE prompt SET isVisible = 1, updatedAt = ? WHERE isBuiltIn = 1 AND category = 'transform' AND deletedAt IS NULL", arguments: [now])
        }
    }

    /// Hiding a transcript prompt also stops it auto-running.
    public func togglePromptVisibility(id: String) throws {
        try mutatePrompt(id) { prompt in
            prompt.isVisible.toggle()
            if !prompt.isVisible { prompt.isAutoRun = false }
        }
    }

    /// The global auto-run switch. Turning it on shows the prompt and applies it to every source.
    public func setPromptAutoRun(id: String, enabled: Bool) throws {
        try mutatePrompt(id) { prompt in
            guard prompt.category == .result else { return }
            prompt.isAutoRun = enabled
            if enabled { prompt.isVisible = true; prompt.appliesToSources = nil }
        }
    }

    /// Per-source auto-run: enabling from "off" scopes to that source only; a full set collapses to "all".
    public func setPromptAutoRun(id: String, source: TBDSourceKind, enabled: Bool) throws {
        try mutatePrompt(id) { prompt in
            guard prompt.category == .result else { return }
            let all = Set(TBDSourceKind.allCases)
            var sources: Set<TBDSourceKind>? = prompt.appliesToSources.map(Set.init)
            if enabled {
                prompt.isVisible = true
                if !prompt.isAutoRun { prompt.isAutoRun = true; sources = [source] } else if sources != nil { sources?.insert(source) }
                if sources == all { sources = nil }
            } else {
                guard prompt.isAutoRun else { return }
                if sources == nil { sources = all.subtracting([source]) } else { sources?.remove(source) }
                if sources?.isEmpty == true { prompt.isAutoRun = false; sources = nil }
            }
            prompt.appliesToSources = sources.map { set in TBDSourceKind.allCases.filter(set.contains) }
        }
    }

    public func setIncludeMeetingNotes(id: String, enabled: Bool) throws {
        try mutatePrompt(id) { prompt in if prompt.category == .result { prompt.includeMeetingNotes = enabled } }
    }

    /// Metadata-only change (never a new version).
    private func mutatePrompt(_ id: String, _ change: (inout TBDPrompt) -> Void) throws {
        try writer.write { db in
            guard var prompt = try TBDPrompt.fetchOne(db, key: id), prompt.deletedAt == nil else { return }
            change(&prompt)
            prompt.updatedAt = Date()
            try prompt.update(db)
        }
    }

    // MARK: - Collections

    public func promptCollections() throws -> [TBDPromptCollection] {
        try writer.read { db in try TBDPromptCollection.order(Column("sortOrder"), Column("name").collating(.nocase)).fetchAll(db) }
    }

    /// Creates or renames a collection. Names are unique ignoring case.
    @discardableResult
    public func savePromptCollection(_ collection: TBDPromptCollection) throws -> TBDPromptCollection {
        var item = collection
        item.name = collection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.name.isEmpty else { throw TBDPromptLibraryError.emptyCollectionName }
        item.colorToken = collection.colorToken.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        item.updatedAt = Date()
        return try writer.write { db in
            let duplicate = try TBDPromptCollection.filter(sql: "name = ? COLLATE NOCASE", arguments: [item.name])
                .filter(Column("id") != item.id).fetchCount(db)
            guard duplicate == 0 else { throw TBDPromptLibraryError.duplicateCollectionName(item.name) }
            if try TBDPromptCollection.fetchOne(db, key: item.id) == nil, collection.sortOrder == 0 {
                item.sortOrder = (try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM promptCollection") ?? -1) + 1
            }
            try item.save(db)
            return item
        }
    }

    /// Deletes a collection; its prompts become unfiled (never deleted).
    @discardableResult
    public func deletePromptCollection(id: String) throws -> Bool {
        try writer.write { db in try TBDPromptCollection.deleteOne(db, key: id) }
    }

    public func reorderPromptCollections(ids: [String]) throws {
        try writer.write { db in
            let existing = try String.fetchAll(db, sql: "SELECT id FROM promptCollection")
            guard ids.count == Set(ids).count, Set(ids) == Set(existing) else { throw TBDPromptLibraryError.invalidOrder }
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE promptCollection SET sortOrder = ?, updatedAt = ? WHERE id = ?", arguments: [index, Date(), id])
            }
        }
    }

    /// Files a prompt in a collection, or unfiles it with nil. Returns false for an unknown prompt.
    @discardableResult
    public func assignPrompt(id: String, toCollection collectionId: String?) throws -> Bool {
        try writer.write { db in
            if let collectionId, try TBDPromptCollection.fetchOne(db, key: collectionId) == nil {
                throw TBDPromptLibraryError.collectionNotFound(collectionId)
            }
            try db.execute(sql: "UPDATE prompt SET collectionId = ?, updatedAt = ? WHERE id = ? AND deletedAt IS NULL",
                           arguments: [collectionId, Date(), id])
            return db.changesCount > 0
        }
    }

    // MARK: - Quick prompts (meeting Ask)

    /// Unpinned first, then pinned, each in its own order.
    public func quickPrompts() throws -> [TBDQuickPromptItem] {
        try writer.read { db in try TBDQuickPromptItem.order(Column("isPinned"), Column("sortOrder")).fetchAll(db) }
    }

    /// Everything shown in the empty Ask state.
    public func visibleQuickPrompts() throws -> [TBDQuickPromptItem] { try quickPrompts().filter(\.isVisible) }

    /// The strip shown after each answer.
    public func pinnedQuickPrompts() throws -> [TBDQuickPromptItem] { try quickPrompts().filter { $0.isVisible && $0.isPinned } }

    /// Creates or edits a quick prompt. Group names adopt the casing already in use; hiding unpins.
    @discardableResult
    public func saveQuickPrompt(_ prompt: TBDQuickPromptItem) throws -> TBDQuickPromptItem {
        try writer.write { db in
            var item = prompt
            item.label = prompt.label.trimmingCharacters(in: .whitespacesAndNewlines)
            item.prompt = prompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.label.isEmpty, !item.prompt.isEmpty else { throw TBDPromptLibraryError.emptyName }
            item.isBuiltIn = TBDQuickPromptItem.builtIn(id: prompt.id) != nil
            if let raw = prompt.groupLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                item.groupLabel = try String.fetchOne(db, sql: """
                    SELECT groupLabel FROM quickPrompt WHERE id <> ? AND groupLabel IS NOT NULL AND LOWER(groupLabel) = LOWER(?) ORDER BY rowid LIMIT 1
                    """, arguments: [prompt.id, raw]) ?? raw
            } else {
                item.groupLabel = nil
            }
            let existing = try TBDQuickPromptItem.fetchOne(db, key: item.id)
            if !item.isVisible, item.isPinned { item.isPinned = false }
            if existing == nil || existing?.isPinned != item.isPinned {
                item.sortOrder = try Self.nextQuickPromptOrder(db, pinned: item.isPinned)
            }
            if let existing { item.createdAt = existing.createdAt }
            item.updatedAt = Date()
            try item.save(db)
            return item
        }
    }

    /// Deletes a custom quick prompt. Built-ins can only be hidden.
    @discardableResult
    public func deleteQuickPrompt(id: String) throws -> Bool {
        try writer.write { db in
            guard let item = try TBDQuickPromptItem.fetchOne(db, key: id), !item.isBuiltIn else { return false }
            return try TBDQuickPromptItem.deleteOne(db, key: id)
        }
    }

    /// Hiding a pinned prompt unpins it; showing never re-pins.
    public func toggleQuickPromptVisibility(id: String) throws {
        try writer.write { db in
            guard var item = try TBDQuickPromptItem.fetchOne(db, key: id) else { return }
            item.isVisible.toggle()
            if !item.isVisible, item.isPinned {
                item.isPinned = false
                item.sortOrder = try Self.nextQuickPromptOrder(db, pinned: false)
            }
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    /// Pinning shows a hidden prompt and puts it last in the strip. Returns false for an unknown id.
    @discardableResult
    public func setQuickPromptPinned(id: String, pinned: Bool) throws -> Bool {
        try writer.write { db in
            guard var item = try TBDQuickPromptItem.fetchOne(db, key: id) else { return false }
            if pinned { item.isVisible = true }
            if pinned != item.isPinned { item.sortOrder = try Self.nextQuickPromptOrder(db, pinned: pinned) }
            item.isPinned = pinned
            item.updatedAt = Date()
            try item.update(db)
            return true
        }
    }

    /// New order within the pinned or unpinned bucket.
    public func reorderQuickPrompts(ids: [String], pinned: Bool) throws {
        try writer.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE quickPrompt SET sortOrder = ?, updatedAt = ? WHERE id = ? AND isPinned = ?",
                               arguments: [index, Date(), id, pinned])
            }
        }
    }

    /// Puts every built-in quick prompt's text, group and pin back; custom prompts stay.
    public func restoreQuickPromptDefaults() throws {
        for seed in TBDQuickPromptItem.builtIns() { try restoreQuickPromptDefault(id: seed.id) }
    }

    public func restoreQuickPromptDefault(id: String) throws {
        guard let seed = TBDQuickPromptItem.builtIn(id: id) else { return }
        try writer.write { db in
            guard let existing = try TBDQuickPromptItem.fetchOne(db, key: id) else { try seed.insert(db); return }
            let pinned = existing.isVisible ? seed.isPinned : false
            let order = pinned == seed.isPinned ? seed.sortOrder : try Self.nextQuickPromptOrder(db, pinned: false)
            try db.execute(sql: """
                UPDATE quickPrompt SET label = ?, prompt = ?, groupLabel = ?, sortOrder = ?, isPinned = ?, isBuiltIn = 1, updatedAt = ? WHERE id = ?
                """, arguments: [seed.label, seed.prompt, seed.groupLabel, order, pinned, Date(), id])
        }
    }

    static func nextQuickPromptOrder(_ db: Database, pinned: Bool) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM quickPrompt WHERE isPinned = ?", arguments: [pinned]) ?? -1) + 1
    }

    // MARK: - Transform history

    public func saveTransformRun(_ run: TBDTransformRun) throws { try writer.write { try run.save($0) } }

    /// Newest first, capped (the page says how many exist in total).
    public func transformRuns(limit: Int = 200) throws -> [TBDTransformRun] {
        try writer.read { db in try TBDTransformRun.order(Column("createdAt").desc).limit(max(0, limit)).fetchAll(db) }
    }

    public func transformRunCount() throws -> Int { try writer.read { try TBDTransformRun.fetchCount($0) } }

    @discardableResult
    public func deleteTransformRun(id: String) throws -> Bool { try writer.write { try TBDTransformRun.deleteOne($0, key: id) } }

    public func clearTransformRuns() throws { _ = try writer.write { try TBDTransformRun.deleteAll($0) } }
}
