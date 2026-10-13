import Foundation
import GRDB

/// The Knowledge document a transcript was saved as ("Save to Knowledge"). One per transcript: the
/// detail view shows "Saved to Knowledge" and automatic saves never run twice for the same transcript.
public struct TBDKnowledgeLink: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "knowledgeDocument"
    public var transcriptionId: String
    public var documentId: String
    public var area: String?
    public var savedAt: Date

    public init(transcriptionId: String, documentId: String, area: String? = nil, savedAt: Date = Date()) {
        self.transcriptionId = transcriptionId; self.documentId = documentId; self.area = area; self.savedAt = savedAt
    }
}

extension TBDListeningDatabase {
    public func knowledgeLink(transcriptionId: String) throws -> TBDKnowledgeLink? {
        try writer.read { try TBDKnowledgeLink.fetchOne($0, key: transcriptionId) }
    }

    public func save(_ link: TBDKnowledgeLink) throws { try writer.write { try link.save($0) } }
}
