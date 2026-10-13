import XCTest
@testable import TBDSpeech

final class TranscriptReaderTests: XCTestCase {
    private func isolatedDefaults() -> (UserDefaults, () -> Void) {
        let name = "tbd.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    // MARK: Find

    private func find(_ query: String, in blocks: [String]) -> TBDTranscriptFind {
        var find = TBDTranscriptFind()
        find.setBlocks(blocks)
        find.setQuery(query)
        return find
    }

    func testFindMatchesIgnoreCaseAndDiacritics() {
        let result = find("cafe", in: ["Un Café noir", "no match", "CAFE and cafe"])
        XCTAssertEqual(result.matches, [
            .init(blockIndex: 0, range: NSRange(location: 3, length: 4)),
            .init(blockIndex: 2, range: NSRange(location: 0, length: 4)),
            .init(blockIndex: 2, range: NSRange(location: 9, length: 4)),
        ])
        XCTAssertEqual(find("NAIVE", in: ["a naïve idea"]).matches, [.init(blockIndex: 0, range: NSRange(location: 2, length: 5))])
    }

    func testFindUsesTheUntrimmedQueryAndIgnoresBlankQueries() {
        let blocks = ["the other there the end"]
        // " the " appears once, before "end": the words "other" and "there" do not match.
        XCTAssertEqual(find(" the ", in: blocks).matches.count, 1)
        XCTAssertEqual(find(" the ", in: blocks).matches[0].range, NSRange(location: 15, length: 5))
        XCTAssertEqual(find("the", in: blocks).matches.count, 4)
        for blank in ["", "   ", "\n\t"] {
            let result = find(blank, in: blocks)
            XCTAssertEqual(result.matches, [])
            XCTAssertNil(result.currentMatchIndex)
            XCTAssertNil(result.displayPosition)
            XCTAssertFalse(result.hasQueryButNoMatches)
        }
    }

    func testFindReportsAQueryWithoutMatches() {
        let result = find("zebra", in: ["one", "two"])
        XCTAssertTrue(result.hasQueryButNoMatches)
        XCTAssertNil(result.displayPosition)
        XCTAssertFalse(find("one", in: ["one", "two"]).hasQueryButNoMatches)
    }

    func testFindNavigationWrapsAround() {
        var result = find("a", in: ["a", "a", "a"])
        XCTAssertEqual(result.displayPosition?.current, 1)
        XCTAssertEqual(result.displayPosition?.total, 3)
        result.next(); XCTAssertEqual(result.currentMatchIndex, 1)
        result.next(); XCTAssertEqual(result.currentMatchIndex, 2)
        result.next(); XCTAssertEqual(result.currentMatchIndex, 0)
        result.prev(); XCTAssertEqual(result.currentMatchIndex, 2)
        result.prev(); XCTAssertEqual(result.currentMatchIndex, 1)
        XCTAssertEqual(result.current?.blockIndex, 1)
        var empty = find("zebra", in: ["one"])
        empty.next(); empty.prev()
        XCTAssertNil(empty.currentMatchIndex)
    }

    func testFindKeepsTheCurrentMatchWhenBlocksChange() {
        var result = find("a", in: ["a", "a", "a"])
        result.next()  // second match
        // Same blocks: the same match stays current.
        result.setBlocks(["a", "a", "a"])
        XCTAssertEqual(result.currentMatchIndex, 1)
        // A block disappears before the current match: the current match is gone, so the position is kept.
        result.setBlocks(["a", "a"])
        XCTAssertEqual(result.currentMatchIndex, 1)
        // Fewer matches than the old position: clamp to the last.
        result.next()
        result.setBlocks(["a"])
        XCTAssertEqual(result.currentMatchIndex, 0)
        // Clearing the blocks removes every match.
        result.setBlocks([])
        XCTAssertEqual(result.matches, [])
        XCTAssertNil(result.currentMatchIndex)
    }

    func testFindChangingTheQueryRestartsAtTheFirstMatch() {
        var result = find("a", in: ["a b", "b a"])
        result.next()
        result.setQuery("b")
        XCTAssertEqual(result.currentMatchIndex, 0)
        XCTAssertEqual(result.matches.count, 2)
        result.clear()
        XCTAssertEqual(result.query, "")
        XCTAssertEqual(result.matches, [])
    }

    func testFindRangesPerBlock() {
        let result = find("ab", in: ["ab ab", "none", "xab"])
        XCTAssertEqual(result.ranges(inBlock: 0), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(result.ranges(inBlock: 1), [])
        XCTAssertEqual(result.ranges(inBlock: 2), [NSRange(location: 1, length: 2)])
        XCTAssertEqual(result.currentRange(inBlock: 0), NSRange(location: 0, length: 2))
        XCTAssertNil(result.currentRange(inBlock: 2))
    }

    func testFindBlocksFollowTheViewMode() {
        let segments = [TBDSegment(start: 0, end: 1000, text: "one"), TBDSegment(start: 1000, end: 2000, text: "two")]
        XCTAssertEqual(TBDTranscriptReader.findBlocks(mode: .timed, segments: segments, body: "one two"), ["one", "two"])
        XCTAssertEqual(TBDTranscriptReader.findBlocks(mode: .text, segments: segments, body: "one two"), ["one two"])
    }

    func testTextAnchorPrefix() {
        XCTAssertEqual(TBDTranscriptReader.prefix(of: "hello world", utf16Offset: 6), "hello ")
        XCTAssertEqual(TBDTranscriptReader.prefix(of: "hello", utf16Offset: 0), "")
        XCTAssertEqual(TBDTranscriptReader.prefix(of: "hello", utf16Offset: 5), "hello")
        XCTAssertNil(TBDTranscriptReader.prefix(of: "hello", utf16Offset: 6))
        XCTAssertNil(TBDTranscriptReader.prefix(of: "hello", utf16Offset: -1))
        // An offset inside a surrogate pair is not a character boundary.
        XCTAssertNil(TBDTranscriptReader.prefix(of: "a😀b", utf16Offset: 2))
        XCTAssertEqual(TBDTranscriptReader.prefix(of: "a😀b", utf16Offset: 3), "a😀")
    }

    // MARK: Font scale

    func testFontScaleClampsAndSteps() {
        XCTAssertEqual(TBDTranscriptFontScale.defaultValue, 1.0)
        XCTAssertEqual(TBDTranscriptFontScale.range, 0.85...1.4)
        XCTAssertEqual(TBDTranscriptFontScale.step, 0.1)
        XCTAssertEqual(TBDTranscriptFontScale.clamped(0.1), 0.85)
        XCTAssertEqual(TBDTranscriptFontScale.clamped(9), 1.4)
        XCTAssertEqual(TBDTranscriptFontScale.clamped(1.2), 1.2)
        XCTAssertEqual(TBDTranscriptFontScale.clamped(.nan), 1.0)
        XCTAssertEqual(TBDTranscriptFontScale.adjusted(1.0, by: 0.1), 1.1, accuracy: 1e-9)
        XCTAssertEqual(TBDTranscriptFontScale.adjusted(1.0, by: -0.1), 0.9, accuracy: 1e-9)
        XCTAssertEqual(TBDTranscriptFontScale.adjusted(0.9, by: -0.1), 0.85, accuracy: 1e-9)
        XCTAssertEqual(TBDTranscriptFontScale.adjusted(1.35, by: 0.1), 1.4, accuracy: 1e-9)
        XCTAssertEqual(TBDTranscriptFontScale.adjusted(7, by: -0.1), 1.3, accuracy: 1e-9)
        XCTAssertEqual(TBDTranscriptFontScale.pointSize(1.0), 13, accuracy: 1e-9)
        XCTAssertEqual(TBDTranscriptFontScale.pointSize(1.4), 18.2, accuracy: 1e-9)
        XCTAssertEqual(TBDTranscriptFontScale.pointSize(0), 11.05, accuracy: 1e-9)
    }

    func testFontScaleButtonsDisableAtTheEnds() {
        XCTAssertFalse(TBDTranscriptFontScale.canDecrease(0.85))
        XCTAssertTrue(TBDTranscriptFontScale.canDecrease(0.9))
        XCTAssertFalse(TBDTranscriptFontScale.canIncrease(1.4))
        XCTAssertTrue(TBDTranscriptFontScale.canIncrease(1.3))
        XCTAssertTrue(TBDTranscriptFontScale.canDecrease(1.0))
        XCTAssertTrue(TBDTranscriptFontScale.canIncrease(1.0))
    }

    func testFontScalePreferenceUsesTheV1DefaultAndClamps() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let prefs = TBDListeningPreferences(defaults: defaults)
        XCTAssertEqual(TBDTranscriptFontScale.defaultsKey, "tbd.listening.transcriptFontScale")
        XCTAssertEqual(prefs.transcriptFontScale, 1.0)
        // Reading never writes the key.
        XCTAssertNil(defaults.object(forKey: "tbd.listening.transcriptFontScale"))
        prefs.transcriptFontScale = 1.2
        XCTAssertEqual(defaults.double(forKey: "tbd.listening.transcriptFontScale"), 1.2)
        XCTAssertEqual(prefs.transcriptFontScale, 1.2)
        defaults.set(5.0, forKey: "tbd.listening.transcriptFontScale")
        XCTAssertEqual(prefs.transcriptFontScale, 1.4)
        prefs.transcriptFontScale = 0.1
        XCTAssertEqual(prefs.transcriptFontScale, 0.85)
    }

    // MARK: Playback rate

    func testPlaybackRateListLabelsAndLimits() {
        XCTAssertEqual(TBDPlaybackRate.options, [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
        XCTAssertEqual(TBDPlaybackRate.options.map(TBDPlaybackRate.label(for:)), ["0.5x", "0.75x", "1x", "1.25x", "1.5x", "1.75x", "2x"])
        XCTAssertEqual(TBDPlaybackRate.defaultValue, 1.0)
        XCTAssertEqual(TBDPlaybackRate.normalized(0.1), 0.5)
        XCTAssertEqual(TBDPlaybackRate.normalized(4), 2.0)
        XCTAssertEqual(TBDPlaybackRate.normalized(1.25), 1.25)
        XCTAssertEqual(TBDPlaybackRate.normalized(.infinity), 1.0)
        XCTAssertEqual(TBDPlaybackRate.normalized(.nan), 1.0)
    }

    func testPlaybackRatePreferenceUsesTheV1DefaultAndClamps() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let prefs = TBDListeningPreferences(defaults: defaults)
        XCTAssertEqual(TBDPlaybackRate.defaultsKey, "tbd.listening.playbackRate")
        XCTAssertEqual(prefs.playbackRate, 1.0)
        XCTAssertNil(defaults.object(forKey: "tbd.listening.playbackRate"))
        prefs.playbackRate = 1.5
        XCTAssertEqual(defaults.double(forKey: "tbd.listening.playbackRate"), 1.5)
        XCTAssertEqual(prefs.playbackRate, 1.5)
        defaults.set(9.0, forKey: "tbd.listening.playbackRate")
        XCTAssertEqual(prefs.playbackRate, 2.0)
        prefs.playbackRate = 0.01
        XCTAssertEqual(prefs.playbackRate, 0.5)
    }

    // MARK: Playing along

    func testSegmentIndexIsTheLastSegmentStartedAtOrBeforeTheTime() {
        let starts = [0, 1000, 2500, 2500, 9000]
        XCTAssertNil(TBDTranscriptReader.segmentIndex(starts: [], atMs: 500))
        XCTAssertNil(TBDTranscriptReader.segmentIndex(starts: [1000, 2000], atMs: 999))
        XCTAssertEqual(TBDTranscriptReader.segmentIndex(starts: starts, atMs: 0), 0)
        XCTAssertEqual(TBDTranscriptReader.segmentIndex(starts: starts, atMs: 999), 0)
        XCTAssertEqual(TBDTranscriptReader.segmentIndex(starts: starts, atMs: 1000), 1)
        XCTAssertEqual(TBDTranscriptReader.segmentIndex(starts: starts, atMs: 2499), 1)
        XCTAssertEqual(TBDTranscriptReader.segmentIndex(starts: starts, atMs: 2500), 3)
        XCTAssertEqual(TBDTranscriptReader.segmentIndex(starts: starts, atMs: 8999), 3)
        XCTAssertEqual(TBDTranscriptReader.segmentIndex(starts: starts, atMs: 99_999), 4)
    }

    func testHighlightNeedsAudioAndTimeAfterZero() {
        let starts = [0, 1000]
        XCTAssertNil(TBDTranscriptReader.highlightIndex(starts: starts, atMs: 0, hasAudio: true))
        XCTAssertNil(TBDTranscriptReader.highlightIndex(starts: starts, atMs: 1500, hasAudio: false))
        XCTAssertEqual(TBDTranscriptReader.highlightIndex(starts: starts, atMs: 1, hasAudio: true), 0)
        XCTAssertEqual(TBDTranscriptReader.highlightIndex(starts: starts, atMs: 1500, hasAudio: true), 1)
    }

    func testSeekJumpThreshold() {
        XCTAssertFalse(TBDTranscriptReader.isSeekJump(from: 1000, to: 1100))
        XCTAssertFalse(TBDTranscriptReader.isSeekJump(from: 1000, to: 3000))
        XCTAssertTrue(TBDTranscriptReader.isSeekJump(from: 1000, to: 3001))
        XCTAssertTrue(TBDTranscriptReader.isSeekJump(from: 9000, to: 100))
        XCTAssertEqual(TBDTranscriptReader.followPauseSeconds, 5)
    }

    func testPlayableAudioKeepsExistingFilesInOrderOnce() {
        let existing: Set<String> = ["/m/microphone.wav", "/m/system.wav"]
        let paths = ["/m/microphone.wav", "/m/gone.wav", "/m/system.wav", "/m/microphone.wav"]
        XCTAssertEqual(TBDTranscriptReader.playableAudio(paths, exists: existing.contains), ["/m/microphone.wav", "/m/system.wav"])
        XCTAssertEqual(TBDTranscriptReader.playableAudio([], exists: existing.contains), [])
        XCTAssertEqual(TBDTranscriptReader.playableAudio(["/m/gone.wav"], exists: existing.contains), [])
    }

    // MARK: Text and Timed

    func testViewModeStartsInTextAndHasTwoModes() {
        XCTAssertEqual(TBDTranscriptViewMode.initial, .text)
        XCTAssertEqual(TBDTranscriptViewMode.allCases.map(\.rawValue), ["Text", "Timed"])
    }

    func testBodyTextUsesTheStoredTextThenTheSegments() {
        var item = TBDTranscription(title: "T", sourceKind: .file)
        item.rawText = "raw words"
        XCTAssertEqual(TBDTranscriptReader.bodyText(item), "raw words")
        item.cleanText = "Clean words."
        XCTAssertEqual(TBDTranscriptReader.bodyText(item), "Clean words.")
        item.rawText = ""; item.cleanText = nil
        item.segments = [TBDSegment(start: 0, end: 1000, text: "First."), TBDSegment(start: 1000, end: 2000, text: "Second.")]
        XCTAssertEqual(TBDTranscriptReader.bodyText(item), "First.\n\nSecond.")
        item.segments = []
        XCTAssertEqual(TBDTranscriptReader.bodyText(item), "")
    }

    func testTimedViewIsOfferedOnlyForTimedTranscripts() {
        var item = TBDTranscription(title: "T", sourceKind: .file)
        item.rawText = "plain"
        XCTAssertFalse(TBDTranscriptReader.hasTimedView(item))
        item.segments = [TBDSegment(start: 0, end: 1000, text: "plain")]
        XCTAssertTrue(TBDTranscriptReader.hasTimedView(item))
        item.segments = []
        item.words = [TBDWord(text: "plain", start: 0, end: 500)]
        XCTAssertTrue(TBDTranscriptReader.hasTimedView(item))
    }

    func testClipboardTextWithTimestamp() {
        XCTAssertEqual(TBDTranscriptReader.clipboardText(timestamp: "12:03", body: " Hello world "), "[12:03] Hello world")
        XCTAssertEqual(TBDTranscriptReader.clipboardText(timestamp: "  ", body: "Hello"), "Hello")
        XCTAssertEqual(TBDTranscriptReader.clipboardText(timestamp: "0:05", body: "  "), "[0:05]")
    }
}
