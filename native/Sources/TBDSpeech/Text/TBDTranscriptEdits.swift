import CryptoKit
import Foundation
import GRDB

/// Half-open range of word indices into a transcript's recognised words.
public struct TBDWordRange: Codable, Sendable, Hashable, Comparable {
    public var start: Int
    public var end: Int
    public init(_ start: Int, _ end: Int) { self.start = start; self.end = end }
    public var isEmpty: Bool { end <= start }
    public func contains(_ other: TBDWordRange) -> Bool { other.start >= start && other.end <= end }
    public func overlaps(_ other: TBDWordRange) -> Bool { other.start < end && start < other.end }
    public static func < (lhs: TBDWordRange, rhs: TBDWordRange) -> Bool { (lhs.start, lhs.end) < (rhs.start, rhs.end) }
}

/// One manual change to a transcript. Edits never rewrite the recognised words: they are replayed
/// over them, so they can be undone, and they stop applying when the transcript is retranscribed.
public enum TBDTranscriptEdit: Codable, Sendable, Equatable {
    case renameSpeaker(id: String, label: String)
    /// Adds a speaker the recogniser did not find (id `user:<uuid>`).
    case addSpeaker(id: String, label: String)
    case assignSpeaker(range: TBDWordRange, speaker: String)
    /// Replaces the text of a passage; its word timing is no longer claimed.
    case editText(range: TBDWordRange, text: String)
}

/// A stored edit. `fingerprint` ties it to the recognised words it was made against.
public struct TBDTranscriptCorrection: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcriptCorrection"
    public var id: String
    public var transcriptionId: String
    public var sequence: Int
    public var fingerprint: String
    public var edit: TBDTranscriptEdit
    public var createdAt: Date
    public init(id: String = tbdNewID(), transcriptionId: String, sequence: Int, fingerprint: String, edit: TBDTranscriptEdit) {
        self.id = id; self.transcriptionId = transcriptionId; self.sequence = sequence; self.fingerprint = fingerprint
        self.edit = edit; createdAt = Date()
    }
}

/// A displayed passage and the word indices it covers.
public struct TBDEditableSegment: Sendable, Equatable, Identifiable {
    public var range: TBDWordRange
    public var segment: TBDSegment
    public var edited: Bool
    public var id: TBDWordRange { range }
}

public enum TBDTranscriptEditor {
    public enum EditError: Error, LocalizedError, Equatable {
        case stale, untimed, invalid(String)
        public var errorDescription: String? {
            switch self {
            case .stale: "The transcript changed since it was loaded. Reload and try again."
            case .untimed: "This transcript has no word timing; edit it as a whole."
            case .invalid(let reason): reason
            }
        }
    }

    /// Identity of the recognised words (text, timing, speaker).
    public static func fingerprint(_ item: TBDTranscription) -> String {
        var hasher = SHA256()
        for word in item.words {
            hasher.update(data: Data("\(word.text)\u{1F}\(word.start)\u{1F}\(word.end)\u{1F}\(word.speaker ?? "")\u{1E}".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public struct Projection: Sendable, Equatable {
        public var item: TBDTranscription
        public var segments: [TBDEditableSegment]
        public var hasTextEdits: Bool
        public var editCount: Int
    }

    /// The transcript with the edits that match its words applied. Transient: never save `item`.
    public static func project(_ base: TBDTranscription, corrections: [TBDTranscriptCorrection]) -> Projection {
        let print = fingerprint(base)
        let active = corrections.filter { $0.fingerprint == print }.sorted { $0.sequence < $1.sequence }
        var words = base.words
        var speakers = base.speakers
        var overrides: [TBDWordRange: String] = [:]
        for correction in active {
            switch correction.edit {
            case .renameSpeaker(let id, let label):
                if let index = speakers.firstIndex(where: { $0.id == id }) { speakers[index].label = label }
                else { speakers.append(TBDSpeaker(id: id, label: label)) }
            case .addSpeaker(let id, let label):
                if !speakers.contains(where: { $0.id == id }) { speakers.append(TBDSpeaker(id: id, label: label)) }
            case .assignSpeaker(let range, let speaker):
                for index in max(0, range.start)..<min(words.count, max(range.start, range.end)) { words[index].speaker = speaker }
            case .editText(let range, let text):
                overrides = overrides.filter { !range.contains($0.key) }
                overrides[range] = text
            }
        }
        // Speakers present in the words keep their (possibly edited) labels, in order of appearance.
        var ordered = TBDTranscriptAssembler.speakers(in: words, fixed: speakers)
        for speaker in speakers where !ordered.contains(where: { $0.id == speaker.id }) && speaker.id.hasPrefix("user:") {
            ordered.append(speaker)
        }

        var ranges = TBDTranscriptAssembler.segmentRanges(words: words)
        // An edited passage is never cut by a segment boundary.
        for override in overrides.keys.sorted() {
            var merged: [TBDWordRange] = []
            for range in ranges {
                if let last = merged.last, last.overlaps(override) && range.overlaps(override) {
                    merged[merged.count - 1].end = range.end
                } else {
                    merged.append(range)
                }
            }
            ranges = merged
        }

        var segments: [TBDEditableSegment] = []
        var collapsed: [TBDWord] = []
        for range in ranges where !range.isEmpty {
            var pieces: [TBDWord] = []
            var index = range.start
            var edited = false
            while index < range.end {
                if let (override, text) = overrides.first(where: { $0.key.start == index && $0.key.end <= range.end }) {
                    let first = words[override.start], last = words[override.end - 1]
                    pieces.append(TBDWord(text: text, start: first.start, end: last.end, confidence: 1, speaker: first.speaker))
                    index = override.end
                    edited = true
                } else {
                    pieces.append(words[index])
                    index += 1
                }
            }
            collapsed += pieces
            let first = words[range.start], last = words[range.end - 1]
            segments.append(TBDEditableSegment(range: range, segment: TBDSegment(start: first.start, end: last.end,
                                                                                text: TBDTranscriptAssembler.join(pieces), speaker: first.speaker),
                                               edited: edited))
        }

        var item = base
        if !active.isEmpty, !words.isEmpty {
            item.words = collapsed
            item.speakers = ordered
            item.segments = segments.map(\.segment)
            if !overrides.isEmpty { item.cleanText = segments.map(\.segment.text).joined(separator: " ") }
        }
        return Projection(item: item, segments: segments, hasTextEdits: !overrides.isEmpty, editCount: active.count)
    }

    /// Checks an edit against the current words before it is stored.
    static func validate(_ edit: TBDTranscriptEdit, in item: TBDTranscription, projection: Projection) throws {
        func checkRange(_ range: TBDWordRange) throws {
            guard !item.words.isEmpty else { throw EditError.untimed }
            guard range.start >= 0, range.end <= item.words.count, !range.isEmpty else { throw EditError.invalid("That passage no longer exists.") }
        }
        switch edit {
        case .renameSpeaker(_, let label), .addSpeaker(_, let label):
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EditError.invalid("Enter a speaker name.") }
        case .assignSpeaker(let range, let speaker):
            try checkRange(range)
            guard projection.item.speakers.contains(where: { $0.id == speaker }) else { throw EditError.invalid("Unknown speaker.") }
        case .editText(let range, let text):
            try checkRange(range)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EditError.invalid("A passage cannot be empty.") }
        }
    }
}

extension TBDTranscriptAssembler {
    /// Word index ranges of the display segments (same rules as `segments(words:)`).
    public static func segmentRanges(words: [TBDWord]) -> [TBDWordRange] {
        var ranges: [TBDWordRange] = []
        var start = 0
        for index in words.indices where index > start {
            let previous = words[index - 1], word = words[index]
            let count = index - start
            let speakerChanged = word.speaker != previous.speaker
            let pause = word.start - previous.end > 1_200
            let sentenceEnd = previous.text.last.map { ".?!".contains($0) } == true && count >= 4
            if speakerChanged || pause || sentenceEnd || count >= 40 {
                ranges.append(TBDWordRange(start, index))
                start = index
            }
        }
        if start < words.count { ranges.append(TBDWordRange(start, words.count)) }
        return ranges
    }
}

extension TBDListeningDatabase {
    public func corrections(for transcriptionId: String) throws -> [TBDTranscriptCorrection] {
        try writer.read { try TBDTranscriptCorrection.filter(Column("transcriptionId") == transcriptionId).order(Column("sequence")).fetchAll($0) }
    }

    /// The transcript as shown: stored words with the person's edits applied.
    public func projectedTranscription(id: String) throws -> TBDTranscriptEditor.Projection? {
        guard let item = try transcription(id: id) else { return nil }
        return TBDTranscriptEditor.project(item, corrections: try corrections(for: item.id))
    }

    /// Stores an edit made against `fingerprint`. Refused when the words changed meanwhile.
    @discardableResult
    public func applyEdit(_ edit: TBDTranscriptEdit, to transcriptionId: String, fingerprint: String) throws -> TBDTranscriptEditor.Projection {
        try writer.write { db in
            guard var item = try TBDTranscription.fetchOne(db, key: transcriptionId) else { throw TBDTranscriptEditor.EditError.stale }
            let current = TBDTranscriptEditor.fingerprint(item)
            guard current == fingerprint else { throw TBDTranscriptEditor.EditError.stale }
            let existing = try TBDTranscriptCorrection.filter(Column("transcriptionId") == transcriptionId).fetchAll(db)
            if item.words.isEmpty {
                // Untimed transcripts: speaker labels change in place.
                guard case .renameSpeaker(let id, let label) = edit else { throw TBDTranscriptEditor.EditError.untimed }
                if let index = item.speakers.firstIndex(where: { $0.id == id }) { item.speakers[index].label = label }
                try item.update(db)
                return TBDTranscriptEditor.project(item, corrections: [])
            }
            let before = TBDTranscriptEditor.project(item, corrections: existing)
            try TBDTranscriptEditor.validate(edit, in: item, projection: before)
            let sequence = (existing.map(\.sequence).max() ?? 0) + 1
            try TBDTranscriptCorrection(transcriptionId: transcriptionId, sequence: sequence, fingerprint: current, edit: edit).insert(db)
            let after = TBDTranscriptEditor.project(item, corrections: try TBDTranscriptCorrection.filter(Column("transcriptionId") == transcriptionId).fetchAll(db))
            try Self.syncSearchText(item, projection: after, db: db)
            return after
        }
    }

    /// Removes the most recent edit.
    @discardableResult
    public func undoLastEdit(of transcriptionId: String) throws -> TBDTranscriptEditor.Projection? {
        try writer.write { db in
            guard let item = try TBDTranscription.fetchOne(db, key: transcriptionId) else { return nil }
            let print = TBDTranscriptEditor.fingerprint(item)
            let active = try TBDTranscriptCorrection.filter(Column("transcriptionId") == transcriptionId)
                .filter(Column("fingerprint") == print).order(Column("sequence").desc).fetchAll(db)
            guard let last = active.first else { return nil }
            try last.delete(db)
            let after = TBDTranscriptEditor.project(item, corrections: Array(active.dropFirst()))
            try Self.syncSearchText(item, projection: after, db: db)
            return after
        }
    }

    /// Drops all edits (retranscription replaces the words they were made against).
    public func deleteEdits(of transcriptionId: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM transcriptCorrection WHERE transcriptionId = ?", arguments: [transcriptionId])
        }
    }

    /// Search and copy use `cleanText`: it carries edited text while text edits exist.
    private static func syncSearchText(_ item: TBDTranscription, projection: TBDTranscriptEditor.Projection, db: Database) throws {
        let text: String?
        if projection.hasTextEdits {
            text = projection.item.cleanText
        } else {
            let vocabulary = try TBDCustomWord.fetchAll(db)
            let corrected = TBDTextPipeline.applyCustomWords(item.rawText, words: vocabulary)
            text = corrected == item.rawText ? nil : corrected
        }
        try db.execute(sql: "UPDATE transcription SET cleanText = ?, updatedAt = ? WHERE id = ?", arguments: [text, Date(), item.id])
    }

    /// Renames without touching anything else.
    public func rename(transcriptionId: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try writer.write { db in
            try db.execute(sql: "UPDATE transcription SET title = ?, updatedAt = ? WHERE id = ?", arguments: [trimmed, Date(), transcriptionId])
        }
    }
}
