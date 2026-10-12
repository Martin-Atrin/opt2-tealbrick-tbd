import Foundation

/// Undo for a cancelled dictation: cancelling keeps the audio for a short window; Undo transcribes
/// and pastes it as if the dictation had been stopped normally, expiry deletes it.
public struct TBDCancelUndo: Sendable {
    public enum Window: Int, CaseIterable, Sendable {
        case off = 0, oneSecond = 1, fiveSeconds = 5
        public var title: String {
            switch self {
            case .off: "Off"
            case .oneSecond: "1 s"
            case .fiveSeconds: "5 s"
            }
        }
    }

    public struct Pending: Sendable, Equatable {
        public let url: URL
        public let durationMs: Int
        public let generation: Int
        public fileprivate(set) var remaining: Int
        public let total: Int
    }

    public private(set) var pending: Pending?
    private var generation = 0

    public init() {}

    /// Holds a cancelled take. Returns false when undo is off (discard immediately).
    public mutating func hold(_ url: URL, durationMs: Int, window: Window) -> (accepted: Bool, discard: URL?) {
        let previous = pending?.url
        pending = nil
        guard window != .off else { return (false, previous) }
        generation += 1
        pending = Pending(url: url, durationMs: durationMs, generation: generation, remaining: window.rawValue, total: window.rawValue)
        return (true, previous)
    }

    /// One second passed. Returns the audio to delete when the window ran out.
    public mutating func tick(generation: Int) -> URL? {
        guard var current = pending, current.generation == generation else { return nil }
        current.remaining -= 1
        if current.remaining <= 0 { pending = nil; return current.url }
        pending = current
        return nil
    }

    /// Takes the held audio for transcription.
    public mutating func undo() -> Pending? {
        defer { pending = nil }
        return pending
    }

    /// Ends the window now (confirmed cancel or a new dictation). Returns the audio to delete.
    public mutating func discard() -> URL? {
        defer { pending = nil }
        return pending?.url
    }
}

/// Expands dropped or chosen files and folders into audio and video files to transcribe.
public enum TBDAudioFileEnumerator {
    public static let defaultMaxFiles = 200

    public struct Result: Sendable, Equatable {
        public var files: [URL]
        /// Supported files found beyond the limit (at least this many when the walk stopped early).
        public var dropped: Int
        public var stoppedEarly: Bool
        public var skippedUnsupported: Int
    }

    public static func isSupported(_ url: URL) -> Bool {
        TBDAudioDecoder.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Folders are walked recursively (hidden files and package contents skipped). Results are de-duplicated and
    /// sorted by file name in natural order ("part2" before "part10").
    public static func expand(_ urls: [URL], maxFiles: Int = defaultMaxFiles) -> Result {
        var seen = Set<String>()
        var files: [URL] = []
        var skipped = 0
        var stoppedEarly = false
        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard isSupported(standardized) else { skipped += 1; return }
            if seen.insert(standardized.path).inserted { files.append(standardized) }
        }
        walk: for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else { add(url); continue }
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = walker?.nextObject() as? URL {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if isSupported(file) { add(file) }
                if files.count > maxFiles { stoppedEarly = true; break walk }
            }
        }
        files.sort { lhs, rhs in
            let order = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
            return order == .orderedSame ? lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending : order == .orderedAscending
        }
        let dropped = max(0, files.count - maxFiles)
        return Result(files: Array(files.prefix(maxFiles)), dropped: dropped, stoppedEarly: stoppedEarly, skippedUnsupported: skipped)
    }
}

/// Calendar meetings the person chose not to auto-record: one occurrence, or a whole series.
public struct TBDCalendarSkips: Codable, Sendable, Equatable {
    public var occurrences: Set<String> = []
    public var series: Set<String> = []
    public init() {}

    public static func occurrenceKey(id: String, start: Date) -> String { "\(id)|\(Int(start.timeIntervalSinceReferenceDate))" }

    public func skips(id: String, seriesID: String, start: Date) -> Bool {
        series.contains(seriesID) || occurrences.contains(Self.occurrenceKey(id: id, start: start))
    }

    /// Drops occurrence skips older than 14 days.
    public mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-14 * 86_400).timeIntervalSinceReferenceDate
        occurrences = occurrences.filter { key in
            guard let separator = key.lastIndex(of: "|"), let seconds = Double(key[key.index(after: separator)...]) else { return false }
            return seconds >= cutoff
        }
    }
}

/// Interrupted meeting recordings found at launch.
public enum TBDMeetingRecovery {
    /// Audio smaller than this means the recording died within its first moment.
    public static let minimumViableBytes = 4 * 1024

    public struct Candidate: Sendable, Equatable {
        public let folder: URL
        public let manifest: TBDMeetingManifest
    }

    /// Unfinished recordings worth offering, oldest first, and folders too small to recover.
    public static func scan(meetingsRoot: URL = TBDListeningPaths.meetings, database: TBDListeningDatabase?)
        -> (offer: [Candidate], empty: [URL]) {
        var offer: [Candidate] = []
        var empty: [URL] = []
        for folder in TBDMeetingRecorder.pendingRecoveries(root: meetingsRoot) {
            guard let manifest = TBDMeetingManifest.read(from: folder) else { continue }
            let bytes = ["microphone.wav", "system.wav"].map { name -> Int in
                let path = folder.appendingPathComponent(name).path
                return ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? 0
            }.max() ?? 0
            let hasRecord = manifest.transcriptionID.flatMap { try? database?.transcription(id: $0) } != nil
            if bytes >= minimumViableBytes || hasRecord {
                offer.append(Candidate(folder: folder, manifest: manifest))
            } else {
                empty.append(folder)
            }
        }
        return (offer.sorted { $0.manifest.startedAt < $1.manifest.startedAt }, empty)
    }
}
