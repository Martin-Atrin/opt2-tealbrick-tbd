import Foundation
import GRDB

/// Applies retention policies to the library: expired items are deleted with their managed audio,
/// and expired meeting audio is detached from its transcript. Only `deleteAfterDays` sweeps.
///
/// Never touched: items still processing, meetings whose recording folder is not finished (crash
/// recovery pending), and files outside the Listening root (a person's own source files).
public struct TBDRetentionSweeper: Sendable {
    public struct Result: Sendable, Equatable {
        public var deletedDictations = 0
        public var deletedTranscriptions = 0
        public var detachedAudio = 0
        public var skippedLocked = 0
        public var failed = 0
        public init() {}
        public var changed: Bool { deletedDictations + deletedTranscriptions + detachedAudio > 0 }
    }

    public let database: TBDListeningDatabase
    /// Only files under this folder are ever deleted.
    public let managedRoot: URL
    /// Folder holding one subfolder per meeting recording.
    public let meetingsRoot: URL

    public init(database: TBDListeningDatabase, managedRoot: URL = TBDListeningPaths.root,
                meetingsRoot: URL = TBDListeningPaths.meetings) {
        self.database = database
        self.managedRoot = managedRoot
        self.meetingsRoot = meetingsRoot
    }

    @discardableResult
    public func sweep(_ settings: TBDRetentionSettings, now: Date = Date()) throws -> Result {
        var result = Result()
        guard settings.sweeps else { return result }
        let folders = meetingFolders()

        if let cutoff = settings[.dictations].cutoff(now: now) {
            try deleteDictations(kinds: [.dictation, .chat], before: cutoff, result: &result)
        }
        if let cutoff = settings[.voiceNotes].cutoff(now: now) {
            try deleteDictations(kinds: [.voiceNote], before: cutoff, result: &result)
            try deleteTranscriptions(kinds: [.voiceNote], before: cutoff, folders: folders, result: &result)
        }
        if let cutoff = settings[.fileTranscriptions].cutoff(now: now) {
            try deleteTranscriptions(kinds: [.file, .url], before: cutoff, folders: folders, result: &result)
        }
        if let cutoff = settings[.meetingTranscripts].cutoff(now: now) {
            try deleteTranscriptions(kinds: [.meeting], before: cutoff, folders: folders, result: &result)
        }
        if let cutoff = settings[.meetingAudio].cutoff(now: now) {
            try detachMeetingAudio(before: cutoff, folders: folders, result: &result)
        }
        return result
    }

    // MARK: Steps

    private func deleteDictations(kinds: [TBDDictationKind], before cutoff: Date, result: inout Result) throws {
        let expired = try database.writer.read { db in
            try TBDDictation.filter(kinds.map(\.rawValue).contains(Column("kind")))
                .filter(Column("createdAt") < cutoff).fetchAll(db)
        }
        for item in expired {
            if let path = item.audioPath, !removeManaged(path) { result.failed += 1; continue }
            try database.deleteDictation(id: item.id)
            result.deletedDictations += 1
        }
    }

    private func deleteTranscriptions(kinds: [TBDSourceKind], before cutoff: Date, folders: MeetingFolders,
                                      result: inout Result) throws {
        let expired = try database.writer.read { db in
            try TBDTranscription.filter(kinds.map(\.rawValue).contains(Column("sourceKind")))
                .filter(Column("status") != TBDTranscriptionStatus.processing.rawValue)
                .filter(Column("createdAt") < cutoff).fetchAll(db)
        }
        for item in expired {
            let folder = item.sourceKind == .meeting ? folders.folder(for: item) : nil
            if let folder, folders.locked.contains(folder.standardizedFileURL.path) { result.skippedLocked += 1; continue }
            var ok = true
            for path in item.audioPaths where !removeManaged(path) { ok = false }
            if let folder, ok { ok = removeManaged(folder.path) }
            guard ok else { result.failed += 1; continue }
            try database.deleteTranscription(id: item.id)
            result.deletedTranscriptions += 1
        }
    }

    private func detachMeetingAudio(before cutoff: Date, folders: MeetingFolders, result: inout Result) throws {
        let candidates = try database.writer.read { db in
            try TBDTranscription.filter(Column("sourceKind") == TBDSourceKind.meeting.rawValue)
                .filter(Column("status") == TBDTranscriptionStatus.completed.rawValue)
                .filter(Column("audioPaths") != "[]")
                .filter(sql: "COALESCE(audioRetentionStartedAt, createdAt) < ?", arguments: [cutoff])
                .fetchAll(db)
        }
        for var item in candidates where !item.audioPaths.isEmpty {
            if let folder = folders.folder(for: item), folders.locked.contains(folder.standardizedFileURL.path) {
                result.skippedLocked += 1
                continue
            }
            let remaining = item.audioPaths.filter { !removeManaged($0) }
            if !remaining.isEmpty { result.failed += 1 }
            // Paths outside the managed root are not ours to delete, but they are detached too.
            item.audioPaths = remaining.filter { FileManager.default.fileExists(atPath: $0) && isManaged($0) }
            try database.save(item)
            result.detachedAudio += 1
        }
    }

    // MARK: Files

    struct MeetingFolders {
        var byTranscription: [String: URL] = [:]
        /// Standardized paths of folders whose recording is not finished.
        var locked: Set<String> = []

        func folder(for item: TBDTranscription) -> URL? {
            byTranscription[item.id] ?? item.audioPaths.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        }
    }

    func meetingFolders() -> MeetingFolders {
        var folders = MeetingFolders()
        let contents = (try? FileManager.default.contentsOfDirectory(at: meetingsRoot, includingPropertiesForKeys: nil)) ?? []
        for folder in contents {
            guard let manifest = TBDMeetingManifest.read(from: folder) else { continue }
            if let id = manifest.transcriptionID { folders.byTranscription[id] = folder }
            if manifest.state != .done { folders.locked.insert(folder.standardizedFileURL.path) }
        }
        return folders
    }

    func isManaged(_ path: String) -> Bool {
        let root = managedRoot.standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Deletes a managed file or folder. Missing files count as removed; unmanaged paths are left
    /// alone and count as removed (they were never ours).
    @discardableResult
    func removeManaged(_ path: String) -> Bool {
        guard isManaged(path) else { return true }
        guard FileManager.default.fileExists(atPath: path) else { return true }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }
}
