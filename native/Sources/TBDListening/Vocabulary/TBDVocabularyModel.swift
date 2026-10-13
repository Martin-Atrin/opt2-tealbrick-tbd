import Foundation
import TBDSpeech

/// State and rules behind the Vocabulary page: the custom words and snippets lists (v1
/// `CustomWordsViewModel`, `TextSnippetsViewModel`) and the backup flow (v1 `VocabularyBackupViewModel`).
@MainActor
final class TBDVocabularyModel: ObservableObject {
    enum BackupStatus: Equatable {
        case idle
        case exported(words: Int, snippets: Int, filename: String)
        case imported(TBDVocabularyBackup.Result)
        case failed(String)
    }

    @Published private(set) var words: [TBDCustomWord] = []
    @Published private(set) var snippets: [TBDSnippet] = []
    @Published var wordQuery = ""
    @Published var snippetQuery = ""
    @Published var wordError: String?
    @Published var snippetError: String?
    @Published var backupStatus: BackupStatus = .idle
    @Published var pendingImport: TBDVocabularyBackup.Preview?
    @Published var conflictPolicy: TBDVocabularyBackup.ConflictPolicy = .skip

    private let database: TBDListeningDatabase?
    private let backup: TBDVocabularyBackup?
    /// Called after every change so other views (and the library) refresh.
    var onChange: () -> Void = {}

    init(database: TBDListeningDatabase?) {
        self.database = database
        backup = database.map { TBDVocabularyBackup(database: $0) }
        reload()
    }

    func reload() {
        words = (try? database?.customWords()) ?? []
        snippets = (try? database?.snippets()) ?? []
    }

    var filteredWords: [TBDCustomWord] {
        guard !wordQuery.isEmpty else { return words }
        return words.filter { $0.word.localizedCaseInsensitiveContains(wordQuery) || ($0.replacement?.localizedCaseInsensitiveContains(wordQuery) ?? false) }
    }

    var filteredSnippets: [TBDSnippet] {
        guard !snippetQuery.isEmpty else { return snippets }
        return snippets.filter { $0.trigger.localizedCaseInsensitiveContains(snippetQuery) || $0.expansion.localizedCaseInsensitiveContains(snippetQuery) }
    }

    // MARK: Words

    /// Adds a word. A blank replacement fixes capitalisation only. Returns false (with `wordError`) when refused.
    @discardableResult
    func addWord(_ word: String, replacement: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if words.contains(where: { $0.word.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            wordError = "'\(trimmed)' already exists"
            return false
        }
        let fix = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit(into: \.wordError) { try database?.save(TBDCustomWord(word: trimmed, replacement: fix.isEmpty ? nil : fix)) }
    }

    func toggle(_ word: TBDCustomWord) {
        var updated = word
        updated.isEnabled.toggle()
        commit(into: \.wordError) { try database?.save(updated) }
    }

    func delete(_ word: TBDCustomWord) { commit(into: \.wordError) { try database?.deleteCustomWord(id: word.id) } }

    // MARK: Snippets

    /// A typed "\n" becomes a line break, as in v1.
    static func expansion(from typed: String) -> String {
        typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\n", with: "\n")
    }

    static func editable(_ expansion: String) -> String { expansion.replacingOccurrences(of: "\n", with: "\\n") }

    @discardableResult
    func addSnippet(trigger: String, expansion typed: String) -> Bool {
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansion = Self.expansion(from: typed)
        guard !trimmed.isEmpty, !expansion.isEmpty else { return false }
        if snippets.contains(where: { $0.trigger.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            snippetError = "'\(trimmed)' already exists"
            return false
        }
        return commit(into: \.snippetError) { try database?.save(TBDSnippet(trigger: trimmed, expansion: expansion)) }
    }

    /// Edits trigger and text. Key-action snippets keep their action.
    @discardableResult
    func updateSnippet(id: String, trigger: String, expansion typed: String) -> Bool {
        guard var snippet = snippets.first(where: { $0.id == id }) else { return false }
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansion = Self.expansion(from: typed)
        guard !trimmed.isEmpty else { snippetError = "Trigger phrase is required"; return false }
        guard !expansion.isEmpty else { snippetError = "Expansion is required"; return false }
        if snippets.contains(where: { $0.id != id && $0.trigger.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            snippetError = "'\(trimmed)' already exists"
            return false
        }
        snippet.trigger = trimmed
        snippet.expansion = expansion
        return commit(into: \.snippetError) { try database?.save(snippet) }
    }

    func toggle(_ snippet: TBDSnippet) {
        var updated = snippet
        updated.isEnabled.toggle()
        commit(into: \.snippetError) { try database?.save(updated) }
    }

    func delete(_ snippet: TBDSnippet) { commit(into: \.snippetError) { try database?.deleteSnippet(id: snippet.id) } }

    @discardableResult
    private func commit(into field: ReferenceWritableKeyPath<TBDVocabularyModel, String?>, _ change: () throws -> Void) -> Bool {
        do {
            try change()
            self[keyPath: field] = nil
            reload()
            onChange()
            return true
        } catch let failure {
            self[keyPath: field] = failure.localizedDescription
            return false
        }
    }

    // MARK: Backup

    var canExport: Bool { !words.isEmpty || !snippets.isEmpty }
    var suggestedFilename: String { backup?.suggestedFilename() ?? "TBD-Vocabulary.json" }

    /// File bytes for the save panel.
    func exportPayload() -> (data: Data, words: Int, snippets: Int)? {
        guard let backup else { backupStatus = .failed("The Listening library is not available."); return nil }
        do {
            let export = try backup.exportData()
            return (export.data, export.bundle.customWords.count, export.bundle.textSnippets.count)
        } catch {
            backupStatus = .failed("Could not create the backup: \(error.localizedDescription)")
            return nil
        }
    }

    func loadPreview(from url: URL) {
        guard let backup else { backupStatus = .failed("The Listening library is not available."); return }
        do {
            pendingImport = try backup.preview(from: try Data(contentsOf: url))
            conflictPolicy = .skip
            backupStatus = .idle
        } catch let error as TBDVocabularyBackup.ImportError {
            backupStatus = .failed(error.errorDescription ?? "Could not read the file.")
        } catch {
            backupStatus = .failed("Could not read the file: \(error.localizedDescription)")
        }
    }

    func cancelImport() { pendingImport = nil }

    @discardableResult
    func applyImport() -> Bool {
        guard let backup, let preview = pendingImport else { return false }
        do {
            let result = try backup.apply(preview, policy: conflictPolicy)
            pendingImport = nil
            backupStatus = .imported(result)
            reload()
            onChange()
            return true
        } catch let error as TBDVocabularyBackup.ImportError {
            if error == .stalePreview { pendingImport = nil }
            backupStatus = .failed(error.errorDescription ?? "Could not apply the import.")
            return false
        } catch {
            backupStatus = .failed("Could not apply the import: \(error.localizedDescription)")
            return false
        }
    }

    /// One line for the status row after an import (v1 wording).
    static func summary(of result: TBDVocabularyBackup.Result) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var parts: [String] = []
        if result.wordsAdded + result.snippetsAdded > 0 {
            parts.append("Added \(count(result.wordsAdded, "word", "words")) and \(count(result.snippetsAdded, "snippet", "snippets"))")
        }
        let replaced = result.wordsReplaced + result.snippetsReplaced
        if replaced > 0 { parts.append("replaced \(replaced)") }
        let skipped = result.wordsSkipped + result.snippetsSkipped
        if skipped > 0 { parts.append("skipped \(skipped) duplicate\(skipped == 1 ? "" : "s")") }
        if result.wordsRemoved + result.snippetsRemoved > 0 {
            parts.append("removed \(count(result.wordsRemoved, "word", "words")) and \(count(result.snippetsRemoved, "snippet", "snippets"))")
        }
        return parts.isEmpty ? "Nothing to import. The file matched your vocabulary." : parts.joined(separator: ", ") + "."
    }
}
