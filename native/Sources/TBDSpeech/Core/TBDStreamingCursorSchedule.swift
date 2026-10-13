import Foundation

/// One typed group of the streaming cursor and the wait before it.
public struct TBDStreamingBatch: Equatable, Sendable {
    public let text: String
    public let delayBefore: Duration
    public init(text: String, delayBefore: Duration) { self.text = text; self.delayBefore = delayBefore }
}

/// When each group of characters is typed so the text "races early and lingers at the end" (v1 `StreamingCursorScheduler`).
/// Short text (under 4 characters) is typed at once; longer text takes 180 to 420 ms.
public enum TBDStreamingSchedule {
    public static let minMotionMs = 180.0
    public static let maxMotionMs = 420.0
    public static let msPerGrapheme = 12.0
    public static let targetHz = 120.0
    public static let maxAnimationBatches = 48
    public static let minGraphemesForMotion = 4

    public static func batches(for text: String) -> [TBDStreamingBatch] {
        let graphemes = text.map(String.init)
        guard !graphemes.isEmpty, !graphemes.contains(where: { $0.utf16.count > TBDStreamingCursor.maxUTF16PerEvent }) else { return [] }
        guard graphemes.count >= minGraphemesForMotion else {
            return TBDStreamingCursor.chunks(text).map { TBDStreamingBatch(text: $0, delayBefore: .zero) }
        }
        let durationMs = min(max(msPerGrapheme * Double(graphemes.count), minMotionMs), maxMotionMs)
        let hzBatches = Int((durationMs * targetHz / 1_000).rounded(.up))
        let count = min(graphemes.count, maxAnimationBatches, max(2, hzBatches))
        let groups = split(graphemes, into: count)
        let last = groups.count - 1
        var previous = 0.0
        var batches: [TBDStreamingBatch] = []
        for (index, group) in groups.enumerated() {
            let time = last == 0 ? 0 : durationMs * inverseEaseOutCubic(Double(index) / Double(last))
            let delay = index == 0 ? 0 : time - previous
            previous = time
            for (chunkIndex, chunk) in TBDStreamingCursor.chunks(group.joined()).enumerated() {
                batches.append(TBDStreamingBatch(text: chunk, delayBefore: chunkIndex == 0 ? .milliseconds(delay) : .zero))
            }
        }
        return batches
    }

    static func split(_ graphemes: [String], into count: Int) -> [[String]] {
        let groupCount = min(max(count, 1), graphemes.count)
        var groups: [[String]] = []
        var index = 0
        for groupIndex in 0..<groupCount {
            let remainingGroups = groupCount - groupIndex
            let size = (graphemes.count - index + remainingGroups - 1) / remainingGroups
            groups.append(Array(graphemes[index..<(index + size)]))
            index += size
        }
        return groups
    }

    private static func inverseEaseOutCubic(_ p: Double) -> Double { 1 - pow(1 - min(max(p, 0), 1), 1.0 / 3.0) }
}
