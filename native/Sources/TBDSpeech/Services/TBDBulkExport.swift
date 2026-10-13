import Foundation

/// What a bulk export wrote (v1 `BulkTranscriptExportResult`).
public struct TBDBulkExportResult: Sendable, Equatable, Identifiable {
    public struct Failure: Sendable, Equatable {
        public let title: String
        public let message: String
        public init(title: String, message: String) { self.title = title; self.message = message }
    }

    public let directory: URL
    public let format: TBDExportFormat
    public let requestedCount: Int
    public let exportedURLs: [URL]
    public let failures: [Failure]

    public var id: String { directory.path + "\n" + exportedURLs.map(\.path).joined(separator: "\n") }
    public var exportedCount: Int { exportedURLs.count }
    public var failedCount: Int { failures.count }
    public var firstError: String? { failures.first?.message }
    public var isCompleteSuccess: Bool { requestedCount > 0 && failures.isEmpty && exportedCount == requestedCount }

    /// Headline of the result popover (v1 `bulkExportResultTitle`).
    public var title: String {
        if isCompleteSuccess { return "Exported \(exportedCount) \(format.shortName) \(exportedCount == 1 ? "file" : "files")" }
        if exportedCount > 0 { return "Exported \(exportedCount) of \(requestedCount)" }
        return "No files exported"
    }

    /// Every failure on its own line, so a partial export never hides what is missing. Empty when all worked.
    public var failureLines: [String] { failures.map { "\($0.title): \($0.message)" } }
}

/// Writes many transcripts into one folder, one file each (v1 `exportTranscriptsToDirectory`).
public enum TBDBulkExport {
    /// What `run` needs for each item: the transcript as shown (edits applied) and its summaries.
    public typealias Prepare = @Sendable (TBDTranscription) throws -> (item: TBDTranscription, summaries: [TBDSummary])

    /// Exports `items` in order. A file that cannot be written is counted and listed, and the rest go on.
    /// Cancelling removes the files this run wrote (and the folder, when this run created it) and throws
    /// `CancellationError`. When nothing was exported and the folder was new, the empty folder is removed.
    public static func run(_ items: [TBDTranscription], format: TBDExportFormat, options: TBDExportOptions, directory: URL,
                           prepare: Prepare = { ($0, []) }) async throws -> TBDBulkExportResult {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let directoryExisted = fileManager.fileExists(atPath: directory.path)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [Written] = []
        var failures: [TBDBulkExportResult.Failure] = []
        defer { if written.isEmpty, !directoryExisted { removeIfEmpty(directory) } }

        do {
            for source in items {
                try Task.checkCancellation()
                await Task.yield()
                do {
                    let (item, summaries) = try prepare(source)
                    let url = TBDExportFiles.nextAvailableURL(in: directory, stem: TBDExportFiles.stem(item), format: format)
                    try TBDExport.libraryData(item, as: format, summaries: summaries, options: options).write(to: url, options: .atomic)
                    written.append(Written(url: url))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append(.init(title: source.title, message: error.localizedDescription))
                }
            }
        } catch is CancellationError {
            for file in written where file.isUnchanged { try? fileManager.removeItem(at: file.url) }
            if !directoryExisted { removeIfEmpty(directory) }
            throw CancellationError()
        }
        return TBDBulkExportResult(directory: directory, format: format, requestedCount: items.count,
                                   exportedURLs: written.map(\.url), failures: failures)
    }

    private static func removeIfEmpty(_ directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil), contents.isEmpty
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// A file this run wrote, remembered by identity so cleanup never removes a file somebody replaced.
    private struct Written {
        let url: URL
        let identity: Identity?

        init(url: URL) { self.url = url; identity = Identity(url) }

        var isUnchanged: Bool { identity != nil && Identity(url) == identity }

        struct Identity: Equatable {
            let fileNumber: UInt64?
            let size: UInt64?
            let modified: Date?

            init?(_ url: URL) {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
                fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
                size = (attributes[.size] as? NSNumber)?.uint64Value
                modified = attributes[.modificationDate] as? Date
            }
        }
    }
}
