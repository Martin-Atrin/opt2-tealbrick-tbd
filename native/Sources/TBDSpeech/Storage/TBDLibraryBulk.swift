import Foundation
import GRDB

// Favorites and the Library's bulk actions (v1 `TranscriptionLibraryViewModel`): selection mode, bulk delete,
// bulk "remove audio only" for meetings, and the confirmation texts. Pure rules and database/file work live
// here; the Library view only draws them.

extension TBDListeningDatabase {
    /// Stars or unstars a library item.
    public func setFavorite(id: String, _ isFavorite: Bool) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE transcription SET isFavorite = ?, updatedAt = ? WHERE id = ?", arguments: [isFavorite, Date(), id])
        }
    }
}

// MARK: - Selection

/// Which library rows are ticked in selection mode (v1 bulk selection). Selection only ever reaches rows that
/// are on screen: "Select All" means all listed rows, and the confirmation states the exact count.
public struct TBDLibrarySelection: Equatable, Sendable {
    public private(set) var isActive = false
    public private(set) var ids: Set<String> = []
    public init() {}

    public var count: Int { ids.count }
    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Enters selection mode, optionally with a first row ticked ("Select Many…" in a row menu).
    public mutating func begin(startingWith id: String? = nil) {
        isActive = true
        if let id { ids.insert(id) }
    }

    public mutating func toggle(_ id: String) {
        if !ids.insert(id).inserted { ids.remove(id) }
    }

    public mutating func selectAll(_ visible: [String]) { ids = Set(visible) }
    public mutating func clear() { ids = [] }

    /// Leaves selection mode and forgets the ticks.
    public mutating func exit() { isActive = false; ids = [] }

    /// Drops ticks of rows that are no longer listed (a search or filter changed, or rows were deleted).
    public mutating func prune(to visible: Set<String>) { ids.formIntersection(visible) }

    /// After an action that failed for some rows: stay in selection mode with just those rows ticked.
    public mutating func keepFailed(_ failed: [String], visible: Set<String>) {
        let remaining = Set(failed).intersection(visible)
        guard !remaining.isEmpty else { return }
        isActive = true
        ids = remaining
    }

    /// True when every listed row is ticked, or nothing is listed (disables "Select All").
    public func areAllSelected(_ visible: [String]) -> Bool { Set(visible).isSubset(of: ids) }

    /// The ticked rows, in list order.
    public func selected(in items: [TBDTranscription]) -> [TBDTranscription] { items.filter { ids.contains($0.id) } }
}

// MARK: - Confirmation texts (v1 `MeetingDeletionCopy` and the Library alerts)

/// The delete confirmation for a set of rows.
public struct TBDBulkDeletePlan: Equatable, Sendable {
    public let count: Int
    public let meetingCount: Int
    public let hasUnfinishedMeeting: Bool

    public init(_ targets: [TBDTranscription]) {
        count = targets.count
        meetingCount = targets.filter { $0.sourceKind == .meeting }.count
        hasUnfinishedMeeting = targets.contains { $0.sourceKind == .meeting && $0.status != .completed }
    }

    private var allMeetings: Bool { meetingCount == count }

    public var title: String {
        if allMeetings { return count == 1 ? "Delete Meeting?" : "Delete Meetings?" }
        return "Delete Items?"
    }

    public var confirmTitle: String {
        if allMeetings { return count == 1 ? "Delete Meeting" : "Delete Meetings" }
        return "Delete Items"
    }

    public var message: String {
        let warning = hasUnfinishedMeeting ? "At least one selected meeting hasn't been transcribed yet — deleting it makes that permanent. " : ""
        if allMeetings {
            let noun = count == 1 ? "meeting" : "meetings"
            let what = count == 1 ? "its transcript and saved audio" : "transcripts and saved audio"
            let notes = count == 1 ? "this meeting" : "those meetings"
            return warning + "This permanently deletes \(count) \(noun), including \(what). Notes, AI results, and chats for \(notes) are also deleted if they exist."
        }
        if meetingCount > 0 {
            return warning + "This permanently deletes \(count) \(count == 1 ? "item" : "items"), including \(meetingCount) \(meetingCount == 1 ? "meeting" : "meetings"). Meeting transcripts, saved audio, notes, AI results, and chats are removed if they exist. Original local source files are not removed."
        }
        return "Delete \(count) \(count == 1 ? "item" : "items")? This permanently deletes the Library rows and app-owned files. Original local source files are not removed."
    }

    /// One row, from its context menu or the detail header.
    public static func single(_ item: TBDTranscription) -> (title: String, confirm: String, message: String) {
        let plan = TBDBulkDeletePlan([item])
        return (item.sourceKind == .meeting ? "Delete Meeting?" : "Delete Transcription?",
                item.sourceKind == .meeting ? "Delete Meeting" : "Delete",
                item.sourceKind == .meeting ? plan.message : "“\(item.title)” will be permanently deleted. Original local source files are not removed.")
    }
}

/// The "remove audio only" confirmation for the ticked meetings.
public struct TBDBulkAudioPlan: Equatable, Sendable {
    public let count: Int
    /// Ticked meetings that cannot have their audio removed right now.
    public let skipped: Int
    public let hasUnfinishedMeeting: Bool
    /// "Library" or "Meetings": the page the meetings stay in.
    public let surface: String

    public init(_ targets: [TBDTranscription], skipped: Int, surface: String) {
        count = targets.count
        self.skipped = skipped
        hasUnfinishedMeeting = targets.contains { $0.status != .completed }
        self.surface = surface
    }

    public static let title = "Remove Meeting Audio?"
    public static let confirmTitle = "Remove Audio Only"

    public var message: String {
        let selected = count + skipped
        let meetings = count == 1 ? "meeting" : "meetings"
        var text = hasUnfinishedMeeting ? "At least one selected meeting hasn't been transcribed yet — deleting the audio makes that permanent. " : ""
        if skipped > 0 { text += "\(selected) selected \(selected == 1 ? "meeting" : "meetings"). " }
        text += "This permanently deletes saved audio from \(count) \(meetings). \(count == 1 ? "The meeting stays" : "The meetings stay") in \(surface) with \(count == 1 ? "its transcript" : "their transcripts"). Notes, AI results, and chats stay too if they exist. Playback and re-transcription will no longer be available."
        if skipped > 0 {
            text += skipped == 1 ? " 1 selected meeting cannot have its audio removed right now, so it will be skipped."
                : " \(skipped) selected meetings cannot have their audio removed right now, so they will be skipped."
        }
        return text
    }

    /// One meeting, from its context menu.
    public static func single(_ item: TBDTranscription, surface: String) -> String {
        let warning = item.status == .completed ? "" : "This meeting hasn't been transcribed yet — deleting the audio makes that permanent. "
        return warning + "This permanently deletes the saved audio for this meeting. The meeting stays in \(surface) with its transcript. Notes, AI results, and chats stay too if they exist. Playback and re-transcription will no longer be available."
    }
}

// MARK: - Doing it

/// What a bulk action did to each row. Failures keep their reason so the message never says only "failed".
public struct TBDLibraryOutcome: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public let id: String
        public let title: String
        public let reason: String
    }
    public var succeeded: [String] = []
    public var failed: [Failure] = []
    public init() {}

    public var failedIDs: [String] { failed.map(\.id) }

    /// Text for the error line under the header, or nil when everything worked (v1 `bulkDeleteFailureMessage`).
    public func deleteMessage() -> String? {
        guard !failed.isEmpty else { return nil }
        let head = succeeded.isEmpty ? (failed.count == 1 ? "1 item could not be deleted." : "\(failed.count) items could not be deleted.")
            : "Deleted \(succeeded.count) items. \(failed.count) could not be deleted."
        return ([head] + reasonLines).joined(separator: " ")
    }

    /// Text for the error line after "remove audio only" (v1 `bulkAudioDeleteFailureMessage`).
    public func audioMessage(skipped: Int) -> String? {
        guard !failed.isEmpty || skipped > 0 else { return nil }
        var parts: [String] = []
        if !succeeded.isEmpty { parts.append("Deleted audio for \(succeeded.count) \(succeeded.count == 1 ? "meeting" : "meetings").") }
        if !failed.isEmpty {
            parts.append(failed.count == 1 ? "1 meeting audio file could not be deleted." : "\(failed.count) meeting audio files could not be deleted.")
        }
        if skipped > 0 { parts.append(skipped == 1 ? "1 selected item was skipped." : "\(skipped) selected items were skipped.") }
        return (parts + reasonLines).joined(separator: " ")
    }

    private var reasonLines: [String] {
        failed.prefix(3).map { "\($0.title): \($0.reason)" } + (failed.count > 3 ? ["and \(failed.count - 3) more."] : [])
    }
}

extension TBDRetentionSweeper {
    /// A meeting whose audio can be removed: it has a file on disk and is not being recorded or transcribed.
    public static func hasRemovableAudio(_ item: TBDTranscription, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        item.sourceKind == .meeting && item.status != .processing && item.audioPaths.contains(where: exists)
    }

    /// Deletes library rows with their managed audio and meeting folders (v1 full delete). A row still
    /// processing is refused; a row whose files cannot be removed is kept and listed. Files outside the
    /// Listening folder are never touched.
    public func deleteFromLibrary(ids: [String]) -> TBDLibraryOutcome {
        var outcome = TBDLibraryOutcome()
        let folders = meetingFolders()
        for id in ids {
            let loaded: TBDTranscription?
            do { loaded = try database.transcription(id: id) } catch {
                outcome.failed.append(.init(id: id, title: id, reason: error.localizedDescription)); continue
            }
            guard let item = loaded else { outcome.succeeded.append(id); continue }
            func fail(_ reason: String) { outcome.failed.append(.init(id: id, title: item.title, reason: reason)) }
            if item.status == .processing { fail("It is still processing. Wait for it to finish."); continue }
            var removed = true
            for path in item.audioPaths where !removeManaged(path) { removed = false }
            if item.sourceKind == .meeting, let folder = folders.folder(for: item), isMeetingFolder(folder), removed {
                removed = removeManaged(folder.path)
            }
            guard removed else { fail("Some of its files could not be removed."); continue }
            do {
                try database.deleteTranscription(id: id)
                outcome.succeeded.append(id)
            } catch {
                fail(error.localizedDescription)
            }
        }
        return outcome
    }

    /// Removes the saved audio of meetings and keeps the meetings (v1 "Remove Audio Only").
    public func removeAudio(ids: [String]) -> TBDLibraryOutcome {
        var outcome = TBDLibraryOutcome()
        for id in ids {
            let loaded: TBDTranscription?
            do { loaded = try database.transcription(id: id) } catch {
                outcome.failed.append(.init(id: id, title: id, reason: error.localizedDescription)); continue
            }
            guard var item = loaded else { outcome.succeeded.append(id); continue }
            let title = item.title
            func fail(_ reason: String) { outcome.failed.append(.init(id: id, title: title, reason: reason)) }
            guard item.sourceKind == .meeting else { fail("Only meetings have saved audio."); continue }
            if item.status == .processing { fail("It is still processing. Wait for it to finish."); continue }
            let remaining = item.audioPaths.filter { !removeManaged($0) }
            item.audioPaths = remaining
            do {
                try database.save(item)
                if remaining.isEmpty { outcome.succeeded.append(id) } else { fail("Some audio files could not be removed.") }
            } catch {
                fail(error.localizedDescription)
            }
        }
        return outcome
    }

    /// A folder inside the meetings folder, never the meetings folder itself.
    private func isMeetingFolder(_ folder: URL) -> Bool {
        let root = meetingsRoot.standardizedFileURL.path
        return folder.standardizedFileURL.path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
