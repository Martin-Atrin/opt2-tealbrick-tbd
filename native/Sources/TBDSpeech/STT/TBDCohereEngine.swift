import CoreML
import FluidAudio
import Foundation

/// Cohere Transcribe (03-2026, q8) through FluidAudio's `CoherePipeline`, on-device Core ML.
/// Batch only and plain text: no word timestamps (no subtitles, no speaker labels) and no live
/// preview. No language detection: the person picks one of 14 languages (default English).
/// Calls are serialised; long audio is cut into overlapping windows and stitched.
public actor TBDCohereEngine: TBDSpeechEngine {
    public nonisolated let kind = TBDSpeechEngineKind.cohere

    private let language: CohereAsrConfig.Language
    private let modelsRoot: URL
    private let pipeline = CoherePipeline()
    private let gate = TBDAsyncLock()
    private var models: CoherePipeline.LoadedModels?
    private var loading: Task<Void, Error>?

    public init(language: String?, modelsRoot: URL = TBDListeningPaths.models) {
        self.language = Self.cohereLanguage(language) ?? .english
        self.modelsRoot = modelsRoot
    }

    static func cohereLanguage(_ code: String?) -> CohereAsrConfig.Language? {
        TBDListeningPreferences.normalizedLanguage(code).flatMap(CohereAsrConfig.Language.init(rawValue:))
    }

    // MARK: Model files

    static func directory(modelsRoot: URL) -> URL {
        modelsRoot.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName, isDirectory: true)
    }

    static func isDownloaded(modelsRoot: URL = TBDListeningPaths.models) -> Bool {
        let names = ModelNames.CohereTranscribe.self
        return TBDEngineSupport.filesExist([names.encoderCompiledFile, names.decoderCacheExternalV2CompiledFile, names.vocab],
                                           in: directory(modelsRoot: modelsRoot))
    }

    /// Only called from an explicit user action.
    static func download(modelsRoot: URL = TBDListeningPaths.models, progress: (@Sendable (Double) -> Void)?) async throws {
        try TBDListeningPaths.ensure(modelsRoot)
        try await ModelHub.download(.cohereTranscribeCoreml, to: modelsRoot, progressHandler: TBDEngineSupport.progressHandler(progress))
    }

    // MARK: Lifecycle

    public func prepare() async throws {
        if models != nil { return }
        if let loading { return try await loading.value }
        let task = Task { try await self.load() }
        loading = task
        defer { loading = nil }
        do { try await task.value } catch { throw TBDEngineSupport.map(error) }
    }

    private func load() async throws {
        guard kind.capabilities.satisfiesMemory() else {
            throw TBDSpeechError.engineFailed("Cohere Transcribe needs 16 GB of memory or more; this Mac has less.")
        }
        guard Self.isDownloaded(modelsRoot: modelsRoot) else { throw TBDSpeechError.modelNotDownloaded(kind.capabilities.displayName) }
        let directory = Self.directory(modelsRoot: modelsRoot)
        let loaded = try await CoherePipeline.loadModels(encoderDir: directory, decoderDir: directory, vocabDir: directory,
                                                         decoderVariant: .v2, computeUnits: .cpuAndNeuralEngine)
        try Task.checkCancellation()
        // One second of silence specialises the Core ML programs so the first real job is fast.
        _ = try? await infer([Float](repeating: 0, count: CohereAsrConfig.sampleRate), models: loaded, language: language)
        try Task.checkCancellation()
        models = loaded
    }

    public func unload() async {
        loading?.cancel()
        _ = try? await loading?.value
        models = nil
    }

    // MARK: Transcription

    public func transcribe(url: URL, lane: TBDLane, progress: (@Sendable (Double) -> Void)?) async throws -> TBDTranscript {
        try await gate.withLock {
            do {
                try await prepare()
                progress?(0)
                let samples = try await Task.detached(priority: .userInitiated) { try AudioConverter().resampleAudioFile(url) }.value
                progress?(0.4)
                let transcript = try await run(samples)
                progress?(1)
                return transcript
            } catch { throw TBDEngineSupport.map(error) }
        }
    }

    public func transcribe(samples: [Float], lane: TBDLane) async throws -> TBDTranscript {
        guard !samples.isEmpty else { return TBDTranscript(text: "", engine: kind.rawValue) }
        return try await gate.withLock {
            do {
                try await prepare()
                return try await run(samples)
            } catch { throw TBDEngineSupport.map(error) }
        }
    }

    private func run(_ samples: [Float]) async throws -> TBDTranscript {
        guard let models else { throw TBDSpeechError.engineFailed("Cohere Transcribe is not loaded") }
        try Task.checkCancellation()
        let text = try await transcribeGuardingTruncation(samples: samples, models: models)
        return TBDTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines), words: [], language: language.rawValue,
                             engine: kind.rawValue, durationMs: samples.count / 16)
    }

    private func infer(_ audio: [Float], models: CoherePipeline.LoadedModels,
                       language: CohereAsrConfig.Language) async throws -> CoherePipeline.TranscriptionResult {
        let pipeline = self.pipeline
        return try await TBDInferenceGate.run { try await pipeline.transcribe(audio: audio, models: models, language: language) }
    }

    /// One pass when the audio fits and the decoder did not hit its token cap; otherwise
    /// overlapping windows. A capped result means text was cut off, so it is re-run in windows.
    private func transcribeGuardingTruncation(samples: [Float], models: CoherePipeline.LoadedModels) async throws -> String {
        let outputCap = CohereAsrConfig.maxSeqLen - language.promptSequence.count
        if samples.count <= CohereAsrConfig.maxSamples {
            let result = try await infer(samples, models: models, language: language)
            if result.tokenIds.count < outputCap - 1 { return result.text }
        }
        let sr = CohereAsrConfig.sampleRate
        let window = samples.count <= CohereAsrConfig.maxSamples ? min(20 * sr, max(8 * sr, samples.count * 3 / 5)) : 20 * sr
        return try await chunkAndStitch(samples: samples, models: models, outputCap: outputCap, window: window, overlap: 4 * sr, minWindow: 4 * sr)
    }

    /// Windows of `window` samples with `overlap`; a window that still hits the cap is re-cut
    /// smaller (down to `minWindow`). Pieces are joined by `mergeOnOverlap`.
    private func chunkAndStitch(samples: [Float], models: CoherePipeline.LoadedModels, outputCap: Int,
                                window: Int, overlap: Int, minWindow: Int) async throws -> String {
        let sr = CohereAsrConfig.sampleRate
        let hop = max(sr, window - overlap)
        var merged = ""
        var start = 0
        while start < samples.count {
            try Task.checkCancellation()
            let end = min(start + window, samples.count)
            let chunk = Array(samples[start..<end])
            let result = try await infer(chunk, models: models, language: language)
            let text: String
            if result.tokenIds.count < outputCap - 1 {
                text = result.text
            } else if window > minWindow {
                let nextWindow = max(minWindow, window * 3 / 5)
                text = try await chunkAndStitch(samples: chunk, models: models, outputCap: outputCap, window: nextWindow,
                                                overlap: min(overlap, max(sr, nextWindow / 5)), minWindow: minWindow)
            } else {
                text = result.text
            }
            merged = merged.isEmpty ? text : Self.mergeOnOverlap(merged, text)
            if end >= samples.count { break }
            start += hop
        }
        return merged
    }

    // MARK: Overlap merge (ported from the donor's debugged implementation)

    /// Joins `b` onto `a`, dropping the longest suffix of `a` repeated at the start of `b`. Words
    /// for spaced scripts; characters for CJK (and unspaced Hangul), with an approximate match
    /// for CJK where the model renders the same audio slightly differently in each window.
    static func mergeOnOverlap(_ a: String, _ b: String, maxOverlap: Int = 30) -> String {
        let safeSuffixLength = max(maxOverlap * 40, 1000)
        if let split = a.index(a.endIndex, offsetBy: -safeSuffixLength, limitedBy: a.startIndex), split > a.startIndex {
            return String(a[..<split]) + mergeOnOverlap(String(a[split...]), b, maxOverlap: maxOverlap)
        }
        if shouldUseCharacterOverlap(a, b) {
            return mergeUnits(a: a.map(String.init), b: b.map(String.init), maxOverlap: maxOverlap * 3, separator: "",
                              allowApproximate: !containsWhitespace(a) && !containsWhitespace(b))
        }
        return mergeUnits(a: a.split(whereSeparator: \.isWhitespace).map(String.init),
                          b: b.split(whereSeparator: \.isWhitespace).map(String.init),
                          maxOverlap: maxOverlap, separator: " ", allowApproximate: false)
    }

    private static func mergeUnits(a: [String], b: [String], maxOverlap: Int, separator: String, allowApproximate: Bool) -> String {
        guard !a.isEmpty else { return b.joined(separator: separator) }
        guard !b.isEmpty else { return a.joined(separator: separator) }
        let limit = min(maxOverlap, a.count, b.count)
        var best = 0
        var k = limit
        while k >= 1 {
            let suffix = Array(a.suffix(k)), prefix = Array(b.prefix(k))
            if overlapMatches(a: suffix, b: prefix) || (allowApproximate && approximateCharacterOverlapMatches(a: suffix, b: prefix)) {
                best = k
                break
            }
            k -= 1
        }
        var mergedA = a
        if best > 0, let last = mergedA.last, isTrailingPartial(unit: last, completedBy: b[best - 1]) {
            mergedA[mergedA.count - 1] = b[best - 1]
        }
        return (mergedA + b.dropFirst(best)).joined(separator: separator)
    }

    private static func overlapMatches(a: [String], b: [String]) -> Bool {
        guard a.count == b.count else { return false }
        let strong = a.count >= 2
        var matchedLexical = false
        for index in a.indices {
            let aUnit = normalizedUnit(a[index]), bUnit = normalizedUnit(b[index])
            if aUnit == nil && bUnit == nil { continue }
            guard let aUnit, let bUnit else { return false }
            matchedLexical = true
            if aUnit == bUnit { continue }
            if strong, index == a.startIndex, isLeadingPartial(unit: bUnit, completedBy: aUnit) { continue }
            if strong, index == a.index(before: a.endIndex), isTrailingPartial(unit: aUnit, completedBy: bUnit) { continue }
            return false
        }
        return matchedLexical
    }

    private static func approximateCharacterOverlapMatches(a: [String], b: [String]) -> Bool {
        let rawA = a.joined(), rawB = b.joined()
        guard containsCJK(rawA) || containsCJK(rawB) || containsHangul(rawA) || containsHangul(rawB) else { return false }
        let aNorm = a.compactMap(normalizedUnit).joined(), bNorm = b.compactMap(normalizedUnit).joined()
        guard min(aNorm.count, bNorm.count) >= 8 else { return false }
        // A stable anchor: same leading number marker, or a 3+ character common prefix.
        if let aMarker = leadingNumber(aNorm), let bMarker = leadingNumber(bNorm) {
            guard aMarker == bMarker else { return false }
        } else if leadingNumber(aNorm) != nil || leadingNumber(bNorm) != nil {
            return false
        } else if commonPrefixLength(aNorm, bNorm) < 3 {
            return false
        }
        guard trailingNumber(aNorm) == trailingNumber(bNorm) else { return false }
        let allowed = max(2, Int((Double(max(aNorm.count, bNorm.count)) * 0.25).rounded(.down)))
        return boundedEditDistance(aNorm, bNorm, maxDistance: allowed) <= allowed
    }

    private static func leadingNumber(_ string: String) -> String? {
        let digits = String(string.unicodeScalars.prefix { CharacterSet.decimalDigits.contains($0) })
        return digits.isEmpty ? nil : digits
    }

    private static func trailingNumber(_ string: String) -> String? {
        let digits = String(String.UnicodeScalarView(string.unicodeScalars.reversed().prefix { CharacterSet.decimalDigits.contains($0) }.reversed()))
        return digits.isEmpty ? nil : digits
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    private static func boundedEditDistance(_ a: String, _ b: String, maxDistance: Int) -> Int {
        let x = Array(a), y = Array(b)
        guard abs(x.count - y.count) <= maxDistance else { return maxDistance + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = Array(repeating: 0, count: y.count + 1)
        for (i, xc) in x.enumerated() {
            current[0] = i + 1
            var rowMinimum = current[0]
            for (j, yc) in y.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (xc == yc ? 0 : 1))
                rowMinimum = min(rowMinimum, current[j + 1])
            }
            if rowMinimum > maxDistance { return maxDistance + 1 }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    private static func isLeadingPartial(unit: String, completedBy full: String) -> Bool {
        guard let unit = normalizedUnit(unit), let full = normalizedUnit(full) else { return false }
        return unit.count >= 2 && full.count > unit.count && full.hasSuffix(unit)
    }

    private static func isTrailingPartial(unit: String, completedBy full: String) -> Bool {
        guard let unit = normalizedUnit(unit), let full = normalizedUnit(full) else { return false }
        return unit.count >= 2 && full.count > unit.count && full.hasPrefix(unit)
    }

    private static let nonAlphanumerics = CharacterSet.alphanumerics.inverted

    private static func normalizedUnit(_ unit: String) -> String? {
        let normalized = unit.lowercased().trimmingCharacters(in: nonAlphanumerics)
        return normalized.isEmpty ? nil : normalized
    }

    private static func shouldUseCharacterOverlap(_ a: String, _ b: String) -> Bool {
        if containsCJK(a) || containsCJK(b) { return true }
        return !containsWhitespace(a) && !containsWhitespace(b) && (containsHangul(a) || containsHangul(b))
    }

    private static func containsWhitespace(_ string: String) -> Bool {
        string.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func containsCJK(_ string: String) -> Bool {
        string.unicodeScalars.contains {
            switch $0.value {
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: true
            default: false
            }
        }
    }

    private static func containsHangul(_ string: String) -> Bool {
        string.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) }
    }
}
