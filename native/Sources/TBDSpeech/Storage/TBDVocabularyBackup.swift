import Foundation
import GRDB

/// Portable vocabulary file (custom words and snippets). The field names, the schema name and the
/// version are v1's, so backups move both ways between v1 and this app.
/// Ids and local counters are left out and made new on import.
public struct TBDVocabularyBundle: Codable, Sendable, Equatable {
    /// v1's schema name. Kept on purpose: it is the file format, not a product name.
    public static let schemaIdentifier = "macparakeet.vocabulary"
    public static let currentVersion = 1

    public let schema: String
    public let version: Int
    public let exportedAt: Date
    public let appVersion: String?
    public let customWords: [Word]
    public let textSnippets: [Snippet]

    public init(exportedAt: Date, appVersion: String?, customWords: [Word], textSnippets: [Snippet]) {
        schema = Self.schemaIdentifier; version = Self.currentVersion
        self.exportedAt = exportedAt; self.appVersion = appVersion
        self.customWords = customWords; self.textSnippets = textSnippets
    }

    public struct Word: Codable, Sendable, Equatable {
        public let word: String
        public let replacement: String?
        public let isEnabled: Bool
        public let createdAt: Date?
        public init(word: String, replacement: String?, isEnabled: Bool, createdAt: Date?) {
            self.word = word; self.replacement = replacement; self.isEnabled = isEnabled; self.createdAt = createdAt
        }
    }

    public struct Snippet: Codable, Sendable, Equatable {
        public let trigger: String
        public let expansion: String
        public let isEnabled: Bool
        public let action: TBDKeyAction?
        public let createdAt: Date?
        public init(trigger: String, expansion: String, isEnabled: Bool, action: TBDKeyAction?, createdAt: Date?) {
            self.trigger = trigger; self.expansion = expansion; self.isEnabled = isEnabled
            self.action = action; self.createdAt = createdAt
        }
    }
}

/// Exports and imports vocabulary files against the Listening library (v1 `VocabularyImportExportService`).
public final class TBDVocabularyBackup: @unchecked Sendable {
    public enum ImportError: LocalizedError, Equatable {
        case invalidSchema
        case unsupportedVersion(found: Int, supported: Int)
        case decodingFailed(String)
        case invalidEntry(String)
        case emptyReplaceAll
        case stalePreview

        public var errorDescription: String? {
            switch self {
            case .invalidSchema: "This file is not a vocabulary backup."
            case let .unsupportedVersion(found, supported):
                "This file uses a newer format (v\(found)). This version understands v\(supported)."
            case let .decodingFailed(detail): "Could not read the backup file: \(detail)"
            case let .invalidEntry(detail): "The backup has an invalid entry: \(detail)"
            case .emptyReplaceAll: "This file has no words or snippets. Replace all needs a file with entries."
            case .stalePreview: "Your vocabulary changed since the preview. Choose the file again."
            }
        }
    }

    public enum ConflictPolicy: String, Sendable, CaseIterable, Equatable {
        /// Keep what is here; only add what is new.
        case skip
        /// Entries in the file replace entries with the same word or trigger.
        case replace
        /// As replace, and delete everything that is not in the file.
        case replaceAll = "replace-all"
    }

    public struct Preview: Sendable, Equatable {
        public let bundle: TBDVocabularyBundle
        public let wordsTotal: Int
        public let snippetsTotal: Int
        public let wordConflicts: [String]
        public let snippetConflicts: [String]
        /// Entries that repeat inside the file (case-insensitive); the first one wins.
        public let duplicateWords: [String]
        public let duplicateSnippets: [String]
        /// What Replace all would delete.
        public let wordsRemoved: [String]
        public let snippetsRemoved: [String]
        let existingWords: [TBDCustomWord]
        let existingSnippets: [TBDSnippet]

        public var hasConflicts: Bool {
            !wordConflicts.isEmpty || !snippetConflicts.isEmpty || !duplicateWords.isEmpty || !duplicateSnippets.isEmpty
        }
        public var hasRemovals: Bool { !wordsRemoved.isEmpty || !snippetsRemoved.isEmpty }
    }

    public struct Result: Sendable, Equatable {
        public var wordsAdded = 0, wordsReplaced = 0, wordsSkipped = 0, wordsRemoved = 0
        public var snippetsAdded = 0, snippetsReplaced = 0, snippetsSkipped = 0, snippetsRemoved = 0
        public init() {}
    }

    private let database: TBDListeningDatabase
    private let appVersion: String?
    private let clock: @Sendable () -> Date

    public init(database: TBDListeningDatabase, appVersion: String? = TBDSpeechVersion.string,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database; self.appVersion = appVersion; self.clock = clock
    }

    // MARK: Export

    public func makeBundle() throws -> TBDVocabularyBundle {
        TBDVocabularyBundle(
            exportedAt: clock(), appVersion: appVersion,
            customWords: try database.customWords().map {
                .init(word: $0.word, replacement: $0.replacement, isEnabled: $0.isEnabled, createdAt: $0.createdAt)
            },
            textSnippets: try database.snippets().map {
                .init(trigger: $0.trigger, expansion: $0.expansion, isEnabled: $0.isEnabled, action: $0.action, createdAt: $0.createdAt)
            })
    }

    public func exportData() throws -> (bundle: TBDVocabularyBundle, data: Data) {
        let bundle = try makeBundle()
        return (bundle, try Self.encoder.encode(bundle))
    }

    /// `TBD-Vocabulary-YYYY-MM-DD.json` (UTC date).
    public func suggestedFilename(now: Date? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "TBD-Vocabulary-\(formatter.string(from: now ?? clock())).json"
    }

    // MARK: Import

    public func preview(from data: Data) throws -> Preview {
        let decoded: TBDVocabularyBundle
        do { decoded = try Self.decoder.decode(TBDVocabularyBundle.self, from: data) }
        catch { throw ImportError.decodingFailed(error.localizedDescription) }
        guard decoded.schema == TBDVocabularyBundle.schemaIdentifier else { throw ImportError.invalidSchema }
        guard decoded.version <= TBDVocabularyBundle.currentVersion else {
            throw ImportError.unsupportedVersion(found: decoded.version, supported: TBDVocabularyBundle.currentVersion)
        }
        let bundle = try Self.validated(decoded)
        let words = try database.customWords()
        let snippets = try database.snippets()
        let incomingWords = Set(bundle.customWords.map { $0.word.lowercased() })
        let incomingTriggers = Set(bundle.textSnippets.map { $0.trigger.lowercased() })
        let existingWords = Set(words.map { $0.word.lowercased() })
        let existingTriggers = Set(snippets.map { $0.trigger.lowercased() })
        return Preview(
            bundle: bundle, wordsTotal: bundle.customWords.count, snippetsTotal: bundle.textSnippets.count,
            wordConflicts: bundle.customWords.map(\.word).filter { existingWords.contains($0.lowercased()) },
            snippetConflicts: bundle.textSnippets.map(\.trigger).filter { existingTriggers.contains($0.lowercased()) },
            duplicateWords: Self.duplicates(bundle.customWords.map(\.word)),
            duplicateSnippets: Self.duplicates(bundle.textSnippets.map(\.trigger)),
            wordsRemoved: words.filter { !incomingWords.contains($0.word.lowercased()) }.map(\.word),
            snippetsRemoved: snippets.filter { !incomingTriggers.contains($0.trigger.lowercased()) }.map(\.trigger),
            existingWords: words, existingSnippets: snippets)
    }

    public func apply(_ preview: Preview, policy: ConflictPolicy) throws -> Result {
        if policy == .replaceAll, preview.wordsTotal == 0, preview.snippetsTotal == 0 { throw ImportError.emptyReplaceAll }
        let now = clock()
        return try database.writer.write { db in
            var result = Result()
            if policy == .replaceAll {
                let currentWords = try TBDCustomWord.fetchAll(db), currentSnippets = try TBDSnippet.fetchAll(db)
                guard Dictionary(uniqueKeysWithValues: currentWords.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: preview.existingWords.map { ($0.id, $0) }),
                      Dictionary(uniqueKeysWithValues: currentSnippets.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: preview.existingSnippets.map { ($0.id, $0) })
                else { throw ImportError.stalePreview }
                let wordKeys = Set(preview.bundle.customWords.map { $0.word.lowercased() })
                let triggerKeys = Set(preview.bundle.textSnippets.map { $0.trigger.lowercased() })
                for word in preview.existingWords where !wordKeys.contains(word.word.lowercased()) {
                    _ = try TBDCustomWord.deleteOne(db, key: word.id); result.wordsRemoved += 1
                }
                for snippet in preview.existingSnippets where !triggerKeys.contains(snippet.trigger.lowercased()) {
                    _ = try TBDSnippet.deleteOne(db, key: snippet.id); result.snippetsRemoved += 1
                }
            }

            var words = Dictionary(try TBDCustomWord.fetchAll(db).map { ($0.word.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            for incoming in preview.bundle.customWords {
                let key = incoming.word.lowercased()
                if let match = words[key] {
                    if policy == .skip { result.wordsSkipped += 1; continue }
                    _ = try TBDCustomWord.deleteOne(db, key: match.id)
                    result.wordsReplaced += 1
                } else {
                    result.wordsAdded += 1
                }
                var word = TBDCustomWord(word: incoming.word, replacement: incoming.replacement, isEnabled: incoming.isEnabled)
                word.createdAt = incoming.createdAt ?? now
                try word.save(db)
                words[key] = word
            }

            var snippets = Dictionary(try TBDSnippet.fetchAll(db).map { ($0.trigger.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            for incoming in preview.bundle.textSnippets {
                let key = incoming.trigger.lowercased()
                if let match = snippets[key] {
                    if policy == .skip { result.snippetsSkipped += 1; continue }
                    _ = try TBDSnippet.deleteOne(db, key: match.id)
                    result.snippetsReplaced += 1
                } else {
                    result.snippetsAdded += 1
                }
                var snippet = TBDSnippet(trigger: incoming.trigger, expansion: incoming.expansion, isEnabled: incoming.isEnabled, action: incoming.action)
                snippet.createdAt = incoming.createdAt ?? now
                try snippet.save(db)
                snippets[key] = snippet
            }
            return result
        }
    }

    // MARK: Codec

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func duplicates(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !seen.insert($0.lowercased()).inserted }
    }

    /// Trims, rejects empty entries, and turns a typed "\n" in an expansion into a line break (as v1 did).
    static func validated(_ bundle: TBDVocabularyBundle) throws -> TBDVocabularyBundle {
        let words = try bundle.customWords.enumerated().map { index, item in
            let word = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { throw ImportError.invalidEntry("customWords[\(index)].word must not be empty.") }
            let replacement = item.replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
            return TBDVocabularyBundle.Word(word: word, replacement: replacement?.isEmpty == false ? replacement : nil,
                                            isEnabled: item.isEnabled, createdAt: item.createdAt)
        }
        let snippets = try bundle.textSnippets.enumerated().map { index, item in
            let trigger = item.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { throw ImportError.invalidEntry("textSnippets[\(index)].trigger must not be empty.") }
            let expansion = item.expansion.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\n", with: "\n")
            guard !expansion.isEmpty else { throw ImportError.invalidEntry("textSnippets[\(index)].expansion must not be empty.") }
            return TBDVocabularyBundle.Snippet(trigger: trigger, expansion: expansion, isEnabled: item.isEnabled,
                                               action: item.action, createdAt: item.createdAt)
        }
        return TBDVocabularyBundle(exportedAt: bundle.exportedAt, appVersion: bundle.appVersion, customWords: words, textSnippets: snippets)
    }
}
