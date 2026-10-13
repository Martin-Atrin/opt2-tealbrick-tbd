import Foundation
import GRDB

/// One-time import of the earlier TBD Listening library (`macparakeet.db` in the Listening folder)
/// into `listening.sqlite`, so people who upgrade keep their history.
///
/// Safety: the earlier file is opened read-only (no migration, no write, no move, no delete; it uses a
/// rollback journal, so a read-only open creates no side files). A missing file is a no-op. An
/// unreadable or locked file throws, nothing is written, and the next start tries again.
///
/// Idempotence: everything is written in ONE write transaction that ends with the `legacyImport`
/// marker row, so a crash leaves nothing behind. Rows keep their earlier UUID (lowercased) as id, so
/// rows that already exist (same id, or same word / trigger for vocabulary and snippets) are left
/// as they are and counted in `alreadyPresent`.
///
/// Column mapping (earlier table.column → `listening.sqlite` table.column):
///
/// - `dictations` → `dictation`: id → id; createdAt → createdAt; durationMs → durationMs;
///   rawTranscript → rawText; cleanTranscript → cleanText (nil when displayRawTranscript = 1, so the
///   text shown stays the same); pastedToApp → targetApp (also infers `kind`); audioPath → audioPath
///   (path kept, audio not copied); engine → engine; wordCount is recomputed from the text.
///   Skipped rows: hidden = 1 (private dictations keep no text), status ≠ completed, empty text.
///   Fields with no place: processingMode, status, errorMessage, updatedAt, engineVariant, language,
///   aiFormatterProfileID/Name/MatchKind.
/// - `transcriptions` → `transcription`: id → id; createdAt / updatedAt → same; sourceType file →
///   `file`, youtube / podcast → `url`, meeting → `meeting`; title = the earlier display title
///   (meeting: fileName; else titleOverride, then fileName for files or derivedTitle for links);
///   filePath → sourcePath for files, → audioPaths for links and meetings (paths kept, audio not
///   copied); isFavorite → isFavorite; sourceURL → sourceURL; durationMs (NULL → 0); language; engine; status (error →
///   failed, processing → failed "Interrupted before it finished."); errorMessage; rawTranscript
///   (NULL → "") → rawText; cleanTranscript → cleanText; userNotes → userNotes; wordTimestamps
///   {word,startMs,endMs,confidence,speakerId} → words; speakers ([{id,label}] or the older
///   [String]) → speakers; transcriptSegments {startMs,endMs,speakerId,text} → segments (built from
///   the words when absent, as for new items). audioRetentionStartedAt = import time when audio is
///   attached (imports start the retention clock at import time).
///   Fields with no place: fileSizeBytes, speakerCount, diarizationSegments, exportPath,
///   thumbnailURL, channelName, videoDescription, meetingTypeId (the earlier version folded types into labels), recoveredFromCrash,
///   isTranscriptEdited, meetingStartContext, meetingCaptureReport, engineVariant,
///   calendarEventSnapshot, derivedSnippet, splitProvenance, audioTrackOrdinal,
///   meetingArtifactFolderPath.
/// - `summaries` → `summary` (kind `summary`): id; transcriptionId; promptContent (+ blank line +
///   extraInstructions) → prompt; content; createdAt. Skipped when its transcript is not in the
///   library. No place: promptName, prompt/version ids, snapshots, contentEditedAt.
/// - `chat_conversations` → `askConversation`: id; transcriptionId; title; messages
///   {role,content,modelPromptOverride} → {role,content,prompt} (system messages dropped);
///   createdAt; updatedAt. Empty conversations are skipped.
/// - `custom_words` → `customWord`: id; word; replacement; isEnabled; createdAt. No place: source.
/// - `text_snippets` → `snippet`: id; trigger; expansion; isEnabled; useCount; createdAt.
///   Keystroke-action snippets (action set) are skipped: Listening snippets only insert text.
///
/// - `meeting_labels` → `meetingLabel`: id; name; colorToken; sortOrder; isArchived; createdAt; updatedAt. A label whose
///   name (ignoring case) exists already is not added; its assignments go to the existing label.
///   `transcription_meeting_labels` → `transcriptionLabel` (rows whose transcript or label is not in the library are
///   skipped). `prompt_label_policies` → `promptLabelPolicy` (only for prompts that exist here: the built-in prompts
///   keep their earlier ids, custom earlier prompts are not imported). `meeting_types` and
///   `prompt_meeting_policies` are earlier-version leftovers that v1 itself folded into labels; they are not read.
///
/// Earlier tables with no place here are counted by name in `Report.notImported` (see
/// `notImportedTables`). Derived tables (segments, cards, stats) are rebuilt from the rows above.
public enum TBDLegacyImport {
    /// Marker key in `legacyImport`.
    public static let source = "macparakeet-v1"

    /// Where the earlier version kept its library.
    public static var defaultLegacyURL: URL { TBDListeningPaths.root.appendingPathComponent("macparakeet.db") }

    /// Earlier tables that hold data this library has no place for.
    static let notImportedTables = [
        "prompts", "prompt_collections", "quick_prompts", "speaker_profiles", "speaker_corrections",
        "meeting_types", "transform_history", "ai_formatter_profiles", "share_publications", "llm_runs",
    ]

    public enum Kind: String, CaseIterable, Sendable {
        case dictations, transcripts, meetings, summaries, conversations, customWords, snippets
        case labels, labelAssignments, labelPolicies

        /// Kinds always named in the stored summary line; the label kinds only appear when something was imported.
        static let core: [Kind] = [.dictations, .transcripts, .meetings, .summaries, .conversations, .customWords, .snippets]
    }

    public struct Report: Sendable, Equatable {
        public enum Status: String, Sendable { case noLegacyLibrary, alreadyImported, imported }
        public var status: Status
        public var imported: [Kind: Int] = [:]
        /// Rows already in the library (same id, or same word / trigger). Left as they are.
        public var alreadyPresent: [Kind: Int] = [:]
        /// Rows or values not imported, by reason.
        public var skipped: [String: Int] = [:]
        /// Earlier tables with rows that have no place here: table name → row count.
        public var notImported: [String: Int] = [:]
        /// Imported or updated transcripts that are starred.
        public var favorites = 0
        /// Rows that could not be written (not retried).
        public var errors: [String] = []

        public init(status: Status) { self.status = status }

        public func count(_ kind: Kind) -> Int { imported[kind] ?? 0 }
        public var totalImported: Int { imported.values.reduce(0, +) }

        /// One line for the person, or nil when there is nothing to say.
        public var message: String? {
            guard status == .imported else { return nil }
            let nouns: [(Kind, String)] = [(.dictations, "dictation"), (.transcripts, "transcript"), (.meetings, "meeting"),
                                           (.customWords, "custom word"), (.snippets, "snippet")]
            let parts = nouns.compactMap { kind, noun -> String? in
                let n = count(kind)
                return n > 0 ? "\(n) \(noun)\(n == 1 ? "" : "s")" : nil
            }
            var lines: [String] = []
            if !parts.isEmpty {
                let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
                lines.append("Imported \(list) from the earlier TBD version.")
            }
            if !errors.isEmpty {
                lines.append("\(errors.count) item\(errors.count == 1 ? "" : "s") from the earlier TBD version could not be imported.")
            }
            return lines.isEmpty ? nil : lines.joined(separator: " ")
        }

        /// Compact record stored with the marker.
        var summaryLine: String {
            let counts = Kind.allCases.filter { Kind.core.contains($0) || count($0) > 0 }.map { "\($0.rawValue)=\(count($0))" }.joined(separator: " ")
            return counts + " alreadyPresent=\(alreadyPresent.values.reduce(0, +)) skipped=\(skipped.values.reduce(0, +)) errors=\(errors.count) favorites=\(favorites)"
        }

        mutating func skip(_ reason: String) { skipped[reason, default: 0] += 1 }
    }

    /// Result of the start-up run: a line to show (success with rows, or failure) and whether data changed.
    public struct StartOutcome: Sendable, Equatable {
        public var message: String?
        public var changed: Bool
    }

    /// Runs the import once at Listening start. Never throws: a failure becomes a plain message and
    /// the next start tries again. Call off the main thread.
    public static func runAtStart(into database: TBDListeningDatabase, legacyURL: URL = defaultLegacyURL) -> StartOutcome {
        do {
            let report = try run(legacyURL: legacyURL, into: database)
            var changed = report.totalImported > 0
            // An import from before favorites existed has no stars: copy them once.
            if report.status == .alreadyImported { changed = try backfillFavorites(legacyURL: legacyURL, into: database) > 0 }
            return StartOutcome(message: report.message, changed: changed)
        } catch {
            let message = "Could not import Listening data from the earlier TBD version: \(error.localizedDescription) TBD tries again at next start."
            return StartOutcome(message: message, changed: false)
        }
    }

    /// Imports `legacyURL` into `database` unless done before. Throws when the earlier file cannot be read.
    @discardableResult
    public static func run(legacyURL: URL = defaultLegacyURL, into database: TBDListeningDatabase, now: Date = Date()) throws -> Report {
        if try database.writer.read({ try isCompleted($0) }) { return Report(status: .alreadyImported) }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return Report(status: .noLegacyLibrary) }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(2)
        let legacy = try DatabaseQueue(path: legacyURL.path, configuration: configuration)
        defer { try? legacy.close() }
        return try legacy.read { old in
            try database.writer.write { db in
                if try isCompleted(db) { return Report(status: .alreadyImported) }
                var report = Report(status: .imported)
                try importDictations(old, db, &report)
                try importTranscriptions(old, db, now: now, &report)
                try importLabels(old, db, &report)
                try importSummaries(old, db, &report)
                try importConversations(old, db, &report)
                try importCustomWords(old, db, &report)
                try importSnippets(old, db, &report)
                for table in notImportedTables where try old.tableExists(table) {
                    let rows = try Int.fetchOne(old, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                    if rows > 0 { report.notImported[table] = rows }
                }
                // One state change = one write: the marker commits with the rows.
                try db.execute(sql: "INSERT INTO legacyImport (source, sourcePath, completedAt, summary) VALUES (?, ?, ?, ?)",
                               arguments: [source, legacyURL.path, now, report.summaryLine])
                return report
            }
        }
    }

    /// Copies the stars of an earlier import made before favorites were imported, once: the marker's summary
    /// gains `favorites=N`, which new imports write from the start. Returns the number of items starred.
    @discardableResult
    public static func backfillFavorites(legacyURL: URL = defaultLegacyURL, into database: TBDListeningDatabase) throws -> Int {
        let summary = try database.writer.read { try String.fetchOne($0, sql: "SELECT summary FROM legacyImport WHERE source = ?", arguments: [source]) }
        guard let summary, !summary.contains(" favorites="), FileManager.default.fileExists(atPath: legacyURL.path) else { return 0 }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(2)
        let legacy = try DatabaseQueue(path: legacyURL.path, configuration: configuration)
        defer { try? legacy.close() }
        let ids: [String] = try legacy.read { old in
            guard try old.tableExists("transcriptions"), try old.columns(in: "transcriptions").contains(where: { $0.name == "isFavorite" }) else { return [] }
            return try Row.fetchAll(old, sql: "SELECT id FROM transcriptions WHERE isFavorite = 1").compactMap { uuid($0, "id") }
        }
        return try database.writer.write { db in
            var starred = 0
            for id in ids {
                try db.execute(sql: "UPDATE transcription SET isFavorite = 1 WHERE id = ? AND isFavorite = 0", arguments: [id])
                starred += db.changesCount
            }
            try db.execute(sql: "UPDATE legacyImport SET summary = summary || ? WHERE source = ?", arguments: [" favorites=\(starred)", source])
            return starred
        }
    }

    static func isCompleted(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM legacyImport WHERE source = ?)", arguments: [source]) ?? false
    }

    // MARK: - Kinds

    private static func importDictations(_ old: Database, _ db: Database, _ report: inout Report) throws {
        guard try old.tableExists("dictations") else { return }
        let rows = try Row.fetchCursor(old, sql: "SELECT * FROM dictations ORDER BY createdAt")
        while let row = try rows.next() {
            guard let id = uuid(row, "id"), let createdAt = date(row, "createdAt") else { report.skip("unreadable dictation"); continue }
            if bool(row, "hidden") == true { report.skip("private dictation"); continue }
            let raw = string(row, "rawTranscript") ?? ""
            var clean = string(row, "cleanTranscript")
            guard (string(row, "status") ?? "completed") == "completed", !isBlank(raw) || !isBlank(clean ?? "") else {
                report.skip("unfinished or empty dictation"); continue
            }
            if try TBDDictation.exists(db, key: id) { report.alreadyPresent[.dictations, default: 0] += 1; continue }
            if bool(row, "displayRawTranscript") == true { clean = nil }
            let item = TBDDictation(id: id, createdAt: createdAt, durationMs: int(row, "durationMs") ?? 0, rawText: raw,
                                    cleanText: clean, targetApp: string(row, "pastedToApp"), audioPath: string(row, "audioPath"),
                                    engine: string(row, "engine"))
            insert(item, as: .dictations, id: id, db, &report)
        }
    }

    private static func importTranscriptions(_ old: Database, _ db: Database, now: Date, _ report: inout Report) throws {
        guard try old.tableExists("transcriptions") else { return }
        let rows = try Row.fetchCursor(old, sql: "SELECT * FROM transcriptions ORDER BY createdAt")
        while let row = try rows.next() {
            guard let id = uuid(row, "id"), let createdAt = date(row, "createdAt") else { report.skip("unreadable transcript"); continue }
            let sourceURL = string(row, "sourceURL")
            let sourceType = string(row, "sourceType") ?? (sourceURL == nil ? "file" : "youtube")
            let kind: TBDSourceKind = switch sourceType {
            case "meeting": .meeting
            case "youtube", "podcast": .url
            default: .file
            }
            let counted: Kind = kind == .meeting ? .meetings : .transcripts
            if try TBDTranscription.exists(db, key: id) { report.alreadyPresent[counted, default: 0] += 1; continue }

            let filePath = string(row, "filePath").flatMap { isBlank($0) ? nil : $0 }
            var item = TBDTranscription(id: id, title: title(row, kind: kind), sourceKind: kind,
                                        sourcePath: kind == .file ? filePath : nil, sourceURL: sourceURL,
                                        status: status(string(row, "status")))
            if string(row, "status") == "processing" { item.errorMessage = "Interrupted before it finished." }
            if let message = string(row, "errorMessage") { item.errorMessage = message }
            item.createdAt = createdAt
            item.updatedAt = date(row, "updatedAt") ?? createdAt
            item.durationMs = int(row, "durationMs") ?? 0
            item.language = string(row, "language")
            item.engine = string(row, "engine")
            item.rawText = string(row, "rawTranscript") ?? ""
            item.cleanText = string(row, "cleanTranscript")
            item.userNotes = string(row, "userNotes")
            item.words = (decode([LegacyWord].self, row, "wordTimestamps", &report) ?? []).map {
                TBDWord(text: $0.word, start: $0.startMs, end: $0.endMs, confidence: $0.confidence ?? 1, speaker: $0.speakerId)
            }
            item.speakers = speakers(row, &report) ?? TBDTranscriptAssembler.speakers(in: item.words)
            let segments = (decode([LegacySegment].self, row, "transcriptSegments", &report) ?? []).map {
                TBDSegment(start: $0.startMs, end: $0.endMs, text: $0.text, speaker: $0.speakerId)
            }
            item.segments = segments.isEmpty
                ? TBDTranscriptAssembler.segments(words: item.words, fallbackText: item.text, durationMs: item.durationMs)
                : segments
            item.audioPaths = kind == .file ? [] : filePath.map { [$0] } ?? []
            item.audioRetentionStartedAt = item.audioPaths.isEmpty ? nil : now
            item.isFavorite = bool(row, "isFavorite") ?? false
            if insert(item, as: counted, id: id, db, &report), item.isFavorite { report.favorites += 1 }
        }
    }

    /// Labels, the labels on transcripts and the prompts aimed at labels. Needs the transcripts imported first.
    private static func importLabels(_ old: Database, _ db: Database, _ report: inout Report) throws {
        guard try old.tableExists("meeting_labels") else { return }
        var mapped: [String: String] = [:]  // earlier label id → id here (itself, or the label with the same name)
        let labels = try Row.fetchCursor(old, sql: "SELECT * FROM meeting_labels ORDER BY sortOrder, createdAt")
        while let row = try labels.next() {
            guard let id = uuid(row, "id"), let name = string(row, "name"), !isBlank(name) else { report.skip("unreadable label"); continue }
            if try TBDMeetingLabel.exists(db, key: id) { mapped[id] = id; report.alreadyPresent[.labels, default: 0] += 1; continue }
            if let same = try TBDMeetingLabel.filter(sql: "name = ? COLLATE NOCASE", arguments: [name.trimmingCharacters(in: .whitespacesAndNewlines)]).fetchOne(db) {
                mapped[id] = same.id; report.alreadyPresent[.labels, default: 0] += 1; continue
            }
            let createdAt = date(row, "createdAt") ?? Date()
            let label = TBDMeetingLabel(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), colorToken: string(row, "colorToken"),
                                        sortOrder: int(row, "sortOrder") ?? 0, isArchived: bool(row, "isArchived") ?? false,
                                        createdAt: createdAt, updatedAt: date(row, "updatedAt") ?? createdAt)
            if insert(label, as: .labels, id: id, db, &report) { mapped[id] = id }
        }
        if try old.tableExists("transcription_meeting_labels") {
            let rows = try Row.fetchCursor(old, sql: "SELECT * FROM transcription_meeting_labels")
            while let row = try rows.next() {
                guard let transcriptionId = uuid(row, "transcriptionId"), let earlierLabel = uuid(row, "labelId") else {
                    report.skip("unreadable label assignment"); continue
                }
                guard let labelId = mapped[earlierLabel] else { report.skip("label assignment of a label not imported"); continue }
                guard try TBDTranscription.exists(db, key: transcriptionId) else { report.skip("label assignment of a transcript not imported"); continue }
                let key = ["transcriptionId": transcriptionId, "labelId": labelId]
                if try TBDTranscriptionLabel.exists(db, key: key) { report.alreadyPresent[.labelAssignments, default: 0] += 1; continue }
                insert(TBDTranscriptionLabel(transcriptionId: transcriptionId, labelId: labelId), as: .labelAssignments, id: transcriptionId + "/" + labelId, db, &report)
            }
        }
        if try old.tableExists("prompt_label_policies") {
            let rows = try Row.fetchCursor(old, sql: "SELECT * FROM prompt_label_policies ORDER BY createdAt")
            while let row = try rows.next() {
                guard let id = uuid(row, "id"), let promptId = uuid(row, "promptId"),
                      let scope = string(row, "scopeKind").flatMap(TBDPromptLabelPolicy.ScopeKind.init(rawValue:)) else {
                    report.skip("unreadable prompt label rule"); continue
                }
                guard try TBDPrompt.exists(db, key: promptId) else { report.skip("label rule of a prompt not imported"); continue }
                var labelId: String?
                if scope == .label {
                    guard let earlier = uuid(row, "labelId"), let known = mapped[earlier] else { report.skip("label rule of a label not imported"); continue }
                    labelId = known
                }
                let duplicate = try TBDPromptLabelPolicy.exists(db, key: id)
                    || TBDPromptLabelPolicy.filter(Column("promptId") == promptId && Column("scopeKind") == scope.rawValue && Column("labelId") == labelId).fetchCount(db) > 0
                if duplicate { report.alreadyPresent[.labelPolicies, default: 0] += 1; continue }
                let createdAt = date(row, "createdAt") ?? Date()
                let rule = TBDPromptLabelPolicy(id: id, promptId: promptId, scopeKind: scope, labelId: labelId, isAvailable: bool(row, "isAvailable") ?? true,
                                                createdAt: createdAt, updatedAt: date(row, "updatedAt") ?? createdAt)
                insert(rule, as: .labelPolicies, id: id, db, &report)
            }
        }
    }

    private static func importSummaries(_ old: Database, _ db: Database, _ report: inout Report) throws {
        guard try old.tableExists("summaries") else { return }
        let rows = try Row.fetchCursor(old, sql: "SELECT * FROM summaries ORDER BY createdAt")
        while let row = try rows.next() {
            guard let id = uuid(row, "id"), let transcriptionId = uuid(row, "transcriptionId"),
                  let createdAt = date(row, "createdAt") else { report.skip("unreadable summary"); continue }
            guard let content = string(row, "content"), !isBlank(content) else { report.skip("empty summary"); continue }
            guard try TBDTranscription.exists(db, key: transcriptionId) else { report.skip("summary of a transcript not imported"); continue }
            if try TBDSummary.exists(db, key: id) { report.alreadyPresent[.summaries, default: 0] += 1; continue }
            var prompt = string(row, "promptContent") ?? ""
            if let extra = string(row, "extraInstructions"), !isBlank(extra) { prompt += "\n\n" + extra }
            var item = TBDSummary(id: id, transcriptionId: transcriptionId, kind: .summary, prompt: prompt, content: content)
            item.createdAt = createdAt
            insert(item, as: .summaries, id: id, db, &report)
        }
    }

    private static func importConversations(_ old: Database, _ db: Database, _ report: inout Report) throws {
        guard try old.tableExists("chat_conversations") else { return }
        let rows = try Row.fetchCursor(old, sql: "SELECT * FROM chat_conversations ORDER BY createdAt")
        while let row = try rows.next() {
            guard let id = uuid(row, "id"), let transcriptionId = uuid(row, "transcriptionId"),
                  let createdAt = date(row, "createdAt") else { report.skip("unreadable Ask conversation"); continue }
            let messages = (decode([LegacyChatMessage].self, row, "messages", &report) ?? []).compactMap { message -> TBDAskMessage? in
                guard let role = TBDAskMessage.Role(rawValue: message.role) else { return nil }
                return TBDAskMessage(role, message.content, prompt: message.modelPromptOverride)
            }
            guard !messages.isEmpty else { report.skip("empty Ask conversation"); continue }
            guard try TBDTranscription.exists(db, key: transcriptionId) else { report.skip("Ask conversation of a transcript not imported"); continue }
            if try TBDAskConversation.exists(db, key: id) { report.alreadyPresent[.conversations, default: 0] += 1; continue }
            var item = TBDAskConversation(id: id, transcriptionId: transcriptionId, title: string(row, "title") ?? "", messages: messages)
            item.createdAt = createdAt
            item.updatedAt = date(row, "updatedAt") ?? createdAt
            insert(item, as: .conversations, id: id, db, &report)
        }
    }

    private static func importCustomWords(_ old: Database, _ db: Database, _ report: inout Report) throws {
        guard try old.tableExists("custom_words") else { return }
        let rows = try Row.fetchCursor(old, sql: "SELECT * FROM custom_words ORDER BY createdAt")
        while let row = try rows.next() {
            guard let id = uuid(row, "id"), let word = string(row, "word"), !isBlank(word) else { report.skip("unreadable custom word"); continue }
            let duplicate = try TBDCustomWord.filter(sql: "word = ? COLLATE NOCASE", arguments: [word]).fetchCount(db) > 0
            if try duplicate || TBDCustomWord.exists(db, key: id) { report.alreadyPresent[.customWords, default: 0] += 1; continue }
            var item = TBDCustomWord(id: id, word: word, replacement: string(row, "replacement"), isEnabled: bool(row, "isEnabled") ?? true)
            if let createdAt = date(row, "createdAt") { item.createdAt = createdAt }
            insert(item, as: .customWords, id: id, db, &report)
        }
    }

    private static func importSnippets(_ old: Database, _ db: Database, _ report: inout Report) throws {
        guard try old.tableExists("text_snippets") else { return }
        let rows = try Row.fetchCursor(old, sql: "SELECT * FROM text_snippets ORDER BY createdAt")
        while let row = try rows.next() {
            guard let id = uuid(row, "id"), let trigger = string(row, "trigger"), !isBlank(trigger) else {
                report.skip("unreadable snippet"); continue
            }
            if let action = string(row, "action"), !isBlank(action) { report.skip("keystroke-action snippet"); continue }
            guard let expansion = string(row, "expansion"), !isBlank(expansion) else { report.skip("empty snippet"); continue }
            let duplicate = try TBDSnippet.filter(sql: "\"trigger\" = ? COLLATE NOCASE", arguments: [trigger]).fetchCount(db) > 0
            if try duplicate || TBDSnippet.exists(db, key: id) { report.alreadyPresent[.snippets, default: 0] += 1; continue }
            var item = TBDSnippet(id: id, trigger: trigger, expansion: expansion, isEnabled: bool(row, "isEnabled") ?? true)
            item.useCount = int(row, "useCount") ?? 0
            if let createdAt = date(row, "createdAt") { item.createdAt = createdAt }
            insert(item, as: .snippets, id: id, db, &report)
        }
    }

    // MARK: - Writing

    /// Inserts one row in its own savepoint, so a bad row is reported without losing the others.
    @discardableResult
    private static func insert(_ record: some PersistableRecord, as kind: Kind, id: String, _ db: Database, _ report: inout Report) -> Bool {
        do {
            try db.inSavepoint {
                try record.insert(db)
                return .commit
            }
            report.imported[kind, default: 0] += 1
            return true
        } catch {
            report.errors.append("\(kind.rawValue) \(id): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Reading earlier rows

    private struct LegacyWord: Decodable {
        var word: String
        var startMs: Int
        var endMs: Int
        var confidence: Double?
        var speakerId: String?
    }

    private struct LegacySpeaker: Decodable {
        var id: String
        var label: String
    }

    private struct LegacySegment: Decodable {
        var startMs: Int
        var endMs: Int
        var speakerId: String?
        var text: String
    }

    private struct LegacyChatMessage: Decodable {
        var role: String
        var content: String
        var modelPromptOverride: String?
    }

    private static func value(_ row: Row, _ column: String) -> DatabaseValue {
        row.hasColumn(column) ? row[column] : .null
    }

    private static func string(_ row: Row, _ column: String) -> String? { String.fromDatabaseValue(value(row, column)) }
    private static func int(_ row: Row, _ column: String) -> Int? { Int.fromDatabaseValue(value(row, column)) }
    private static func bool(_ row: Row, _ column: String) -> Bool? { Bool.fromDatabaseValue(value(row, column)) }
    private static func date(_ row: Row, _ column: String) -> Date? { Date.fromDatabaseValue(value(row, column)) }

    /// Earlier ids are UUIDs stored as 16-byte blobs or as text; both become lowercase UUID strings.
    private static func uuid(_ row: Row, _ column: String) -> String? {
        UUID.fromDatabaseValue(value(row, column))?.uuidString.lowercased()
    }

    private static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Decodes a JSON column. NULL gives nil; unreadable JSON gives nil and is counted.
    private static func decode<T: Decodable>(_ type: T.Type, _ row: Row, _ column: String, _ report: inout Report) -> T? {
        guard let data = Data.fromDatabaseValue(value(row, column)) ?? string(row, column).map({ Data($0.utf8) }) else { return nil }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { report.skip("unreadable \(column)"); return nil }
        return decoded
    }

    /// Speakers as `[{id, label}]`, or the older `[String]` (ids S1, S2, …).
    private static func speakers(_ row: Row, _ report: inout Report) -> [TBDSpeaker]? {
        guard let data = Data.fromDatabaseValue(value(row, "speakers")) ?? string(row, "speakers").map({ Data($0.utf8) }) else { return nil }
        if let list = try? JSONDecoder().decode([LegacySpeaker].self, from: data) {
            return list.map { TBDSpeaker(id: $0.id, label: $0.label) }
        }
        if let names = try? JSONDecoder().decode([String].self, from: data) {
            return names.enumerated().map { TBDSpeaker(id: "S\($0.offset + 1)", label: $0.element) }
        }
        report.skip("unreadable speakers")
        return nil
    }

    private static func status(_ raw: String?) -> TBDTranscriptionStatus {
        switch raw {
        case "completed": .completed
        case "cancelled": .cancelled
        default: .failed
        }
    }

    /// The title the earlier version showed.
    private static func title(_ row: Row, kind: TBDSourceKind) -> String {
        let fileName = string(row, "fileName") ?? ""
        let override = string(row, "titleOverride").flatMap { isBlank($0) ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let derived = string(row, "derivedTitle").flatMap { isBlank($0) ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String = switch kind {
        case .meeting: name
        case .file: override ?? name
        default: override ?? derived ?? name
        }
        return title.isEmpty ? kind.label : title
    }
}
