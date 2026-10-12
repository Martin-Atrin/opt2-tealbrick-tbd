import Foundation

public enum TBDMeetingEditError: Error, LocalizedError, Equatable {
    case unsupportedFormat(String)
    case notEligible(String)
    case cutOutOfRange(Int, durationMs: Int)
    case unorderedCuts
    case blankTitle

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name): "\(name) is not an audio or video file Listening can read."
        case .notEligible(let reason): reason
        case .cutOutOfRange(let ms, let duration):
            "Split points must be between 0:00 and \(TBDExport.clock(duration)); \(TBDExport.clock(ms)) is outside."
        case .unorderedCuts: "Split points must be in order and different."
        case .blankTitle: "Every part needs a title."
        }
    }
}

/// `m:ss`, `h:mm:ss` and `m:ss.fff` time codes.
public enum TBDTimecode {
    public static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let main: Substring
        var fractionMs = 0
        if let dot = trimmed.firstIndex(of: ".") {
            let fraction = trimmed[trimmed.index(after: dot)...]
            guard (1...3).contains(fraction.count), fraction.allSatisfy(\.isASCIIDigit) else { return nil }
            fractionMs = Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
            main = trimmed[..<dot]
        } else {
            main = Substring(trimmed)
        }
        let parts = main.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) && $0.count <= 6 }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        let seconds = numbers[numbers.count - 1]
        let minutes = numbers[numbers.count - 2]
        guard seconds < 60, parts.count == 2 || minutes < 60 else { return nil }
        let hours = parts.count == 3 ? numbers[0] : 0
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + fractionMs
    }

    public static func format(_ ms: Int) -> String {
        let base = TBDExport.clock(ms)
        return ms % 1000 == 0 ? base : base + String(format: ".%03d", ms % 1000)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Imports an audio or video file as a meeting: one "others" track in a meeting folder, ready
/// for the normal meeting transcription (`TBDMeetingRecorder.finalize`).
public enum TBDMeetingImporter {
    /// Decodes `file` into a new meeting folder and creates its library record (status processing).
    /// The recording date is the file's creation date; the audio retention clock starts now.
    public static func prepare(file: URL, title: String? = nil, startedAt: Date? = nil, database: TBDListeningDatabase,
                               meetingsRoot: URL = TBDListeningPaths.meetings) async throws -> (item: TBDTranscription, folder: URL) {
        guard TBDAudioDecoder.supportedExtensions.contains(file.pathExtension.lowercased()) else {
            throw TBDMeetingEditError.unsupportedFormat(file.lastPathComponent)
        }
        if let title, title.trimmingCharacters(in: .whitespaces).isEmpty { throw TBDMeetingEditError.blankTitle }
        let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let date = startedAt ?? values?.creationDate ?? values?.contentModificationDate ?? Date()
        let name = title ?? file.deletingPathExtension().lastPathComponent
        let id = tbdNewID()
        let folder = try TBDListeningPaths.ensure(meetingsRoot.appendingPathComponent(id, isDirectory: true))
        do {
            let durationMs = try await TBDAudioDecoder.decodeToWAV(file, destination: folder.appendingPathComponent("system.wav"))
            var item = TBDTranscription(title: name, sourceKind: .meeting, sourcePath: file.path)
            item.createdAt = date
            item.durationMs = durationMs
            item.audioRetentionStartedAt = Date()
            item.audioPaths = [folder.appendingPathComponent("system.wav").path]
            try TBDMeetingManifest(id: id, title: name, startedAt: date, state: .stopped, durationMs: durationMs,
                                   transcriptionID: item.id).write(to: folder)
            try database.save(item)
            return (item, folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

/// Splits a meeting at time points into new meetings. The source is never changed: each part gets
/// its own audio slice and its own first transcription. Notes, answers and summaries stay with the source.
public enum TBDMeetingSplitter {
    /// Half-open, gapless ranges for the cut points.
    public static func ranges(cuts: [Int], durationMs: Int) throws -> [Range<Int>] {
        var previous = 0
        for cut in cuts {
            guard cut > 0, cut < durationMs else { throw TBDMeetingEditError.cutOutOfRange(cut, durationMs: durationMs) }
            guard cut > previous else { throw TBDMeetingEditError.unorderedCuts }
            previous = cut
        }
        let bounds = [0] + cuts + [durationMs]
        return zip(bounds, bounds.dropFirst()).map { $0..<$1 }
    }

    public static func defaultTitles(_ title: String, parts: Int) -> [String] {
        (1...max(1, parts)).map { "\(title) — Part \($0)" }
    }

    /// Why a meeting cannot be split, or nil.
    public static func ineligibility(_ item: TBDTranscription) -> String? {
        guard item.sourceKind == .meeting else { return "Only meetings can be split." }
        guard item.status == .completed || item.status == .failed else { return "Wait until the meeting has finished processing." }
        let tracks = item.audioPaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !tracks.isEmpty else { return "The meeting audio is no longer available, so it cannot be split." }
        let folder = URL(fileURLWithPath: tracks[0]).deletingLastPathComponent()
        if let manifest = TBDMeetingManifest.read(from: folder), manifest.state != .done, item.status == .completed {
            return "The meeting is still being saved."
        }
        return nil
    }

    /// Writes the parts' audio and creates their records (status processing). Transcribe each folder next.
    public static func prepare(_ item: TBDTranscription, cutsMs: [Int], titles: [String]? = nil, database: TBDListeningDatabase,
                               meetingsRoot: URL = TBDListeningPaths.meetings) throws -> [(item: TBDTranscription, folder: URL)] {
        if let reason = ineligibility(item) { throw TBDMeetingEditError.notEligible(reason) }
        let tracks = item.audioPaths.map(URL.init(fileURLWithPath:)).filter { FileManager.default.fileExists(atPath: $0.path) }
        let duration = tracks.map { TBDAudioDecoder.durationMs(of: $0) }.max() ?? item.durationMs
        let parts = try ranges(cuts: cutsMs, durationMs: duration)
        let names = titles ?? defaultTitles(item.title, parts: parts.count)
        guard names.count == parts.count, names.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw TBDMeetingEditError.blankTitle
        }
        var created: [(item: TBDTranscription, folder: URL)] = []
        do {
            for (index, range) in parts.enumerated() {
                let id = tbdNewID()
                let folder = try TBDListeningPaths.ensure(meetingsRoot.appendingPathComponent(id, isDirectory: true))
                var paths: [String] = []
                for track in tracks {
                    let destination = folder.appendingPathComponent(track.lastPathComponent)
                    if try sliceWAV(track, to: destination, range: range) { paths.append(destination.path) }
                }
                var part = TBDTranscription(title: names[index], sourceKind: .meeting)
                part.createdAt = item.createdAt.addingTimeInterval(Double(range.lowerBound) / 1000)
                part.durationMs = range.count
                part.audioPaths = paths
                part.audioRetentionStartedAt = Date()
                try TBDMeetingManifest(id: id, title: part.title, startedAt: part.createdAt, state: .stopped,
                                       durationMs: range.count, transcriptionID: part.id).write(to: folder)
                created.append((part, folder))
            }
            try database.writer.write { db in for part in created { try part.item.insert(db) } }
            return created
        } catch {
            for part in created { try? FileManager.default.removeItem(at: part.folder) }
            throw error
        }
    }

    /// Copies the samples of `range` (ms) from a Listening WAV (16-bit mono) into a new file. Returns
    /// false (and writes nothing) when the track has no audio in that range.
    @discardableResult
    static func sliceWAV(_ source: URL, to destination: URL, range: Range<Int>, sampleRate: Int = 16_000) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let headerSize: UInt64 = 44
        let total = (try handle.seekToEnd() - headerSize) / 2
        let start = UInt64((Double(range.lowerBound) * Double(sampleRate) / 1000).rounded())
        let end = min(total, UInt64((Double(range.upperBound) * Double(sampleRate) / 1000).rounded()))
        guard end > start else { return false }
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        let bytes = (end - start) * 2
        try out.write(contentsOf: TBDWAVWriter.header(dataBytes: UInt32(bytes), sampleRate: sampleRate))
        try handle.seek(toOffset: headerSize + start * 2)
        var remaining = bytes
        while remaining > 0 {
            let chunk = Int(min(remaining, 1 << 20))
            guard let data = try handle.read(upToCount: chunk), !data.isEmpty else { break }
            try out.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
        return true
    }
}
