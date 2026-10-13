import XCTest
@testable import TBDSpeech

final class DictationBehaviorTests: XCTestCase {
    private func isolatedDefaults() -> (UserDefaults, () -> Void) {
        let name = "tbd.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    // MARK: Insertion style

    func testSentenceStyleCapitalisesAndKeepsPunctuation() {
        XCTAssertEqual(TBDInsertionStyle.sentence.apply(to: "hello world."), "Hello world.")
        XCTAssertEqual(TBDInsertionStyle.sentence.apply(to: "Hello world?"), "Hello world?")
        XCTAssertEqual(TBDInsertionStyle.sentence.apply(to: ""), "")
    }

    func testInlineStyleDropsEndingPunctuationAndLowercasesTheFirstWord() {
        let inline = TBDInsertionStyle.inline
        XCTAssertEqual(inline.apply(to: "Hello world."), "hello world")
        XCTAssertEqual(inline.apply(to: "Hello world?!"), "hello world")
        XCTAssertEqual(inline.apply(to: "Wait..."), "wait")
        XCTAssertEqual(inline.apply(to: "Hello, world."), "hello, world")
        // Capitals that mean something stay.
        XCTAssertEqual(inline.apply(to: "I think so."), "I think so")
        XCTAssertEqual(inline.apply(to: "NASA says hi."), "NASA says hi")
        XCTAssertEqual(inline.apply(to: "iPhone is great."), "iPhone is great")
    }

    func testInlineStyleKeepsProtectedLeadingTerms() {
        let inline = TBDInsertionStyle.inline
        XCTAssertEqual(inline.apply(to: "Teal Brick rocks."), "teal Brick rocks")
        XCTAssertEqual(inline.apply(to: "Teal Brick rocks.", protectedLeadingTerms: ["Teal Brick"]), "Teal Brick rocks")
        // The term must end at a word boundary.
        XCTAssertEqual(inline.apply(to: "Tealium is.", protectedLeadingTerms: ["Teal"]), "tealium is")
        XCTAssertEqual(inline.apply(to: "Teal, said he.", protectedLeadingTerms: ["Teal"]), "Teal, said he")
    }

    func testInsertionTextAddsATrailingSpaceOnlyInSentenceStyleWithoutAnAction() {
        XCTAssertEqual(TBDInsertionStyle.sentence.insertionText("Hi there.", hasAction: false), "Hi there. ")
        XCTAssertEqual(TBDInsertionStyle.sentence.insertionText("Hi there.", hasAction: true), "Hi there.")
        XCTAssertEqual(TBDInsertionStyle.inline.insertionText("hi there", hasAction: false), "hi there")
        XCTAssertEqual(TBDInsertionStyle.inline.previewText, "hello world")
        XCTAssertEqual(TBDInsertionStyle.sentence.previewText, "Hello world.")
    }

    func testProtectedTermsComeFromEnabledVocabularyAndExpandedSnippets() {
        let words = [TBDCustomWord(word: "tealbrick", replacement: "Teal Brick"), TBDCustomWord(word: "kubernetes"),
                     TBDCustomWord(word: "off", replacement: "OFF", isEnabled: false)]
        let used = TBDSnippet(trigger: "my address", expansion: "1 Main Street")
        let unused = TBDSnippet(trigger: "sig", expansion: "Best regards")
        let terms = TBDInsertionStyle.protectedLeadingTerms(customWords: words, snippets: [used, unused], expandedSnippetIDs: [used.id])
        XCTAssertEqual(terms, ["Teal Brick", "kubernetes", "1 Main Street"])
    }

    // MARK: Voice return

    func testVoiceReturnRemovesTheTriggerAtTheEnd() {
        let triggers = ["press return"]
        XCTAssertEqual(TBDVoiceReturn.extract(from: "Send it press return", triggers: triggers).text, "Send it")
        XCTAssertEqual(TBDVoiceReturn.extract(from: "Send it press return", triggers: triggers).trigger, "press return")
        XCTAssertEqual(TBDVoiceReturn.extract(from: "Send it. Press return.", triggers: triggers).text, "Send it.")
        XCTAssertEqual(TBDVoiceReturn.extract(from: "Send it press  return!  ", triggers: triggers).text, "Send it")
        let only = TBDVoiceReturn.extract(from: "Press return.", triggers: triggers)
        XCTAssertEqual(only.text, "")
        XCTAssertEqual(only.trigger, "press return")
    }

    func testVoiceReturnLeavesTextWhenTheTriggerIsNotTheEnd() {
        let triggers = ["press return"]
        for text in ["press return and then more", "I said press return to him", "compress return", "Please press returns", "plain text"] {
            let result = TBDVoiceReturn.extract(from: text, triggers: triggers)
            XCTAssertEqual(result.text, text)
            XCTAssertNil(result.trigger)
        }
        XCTAssertEqual(TBDVoiceReturn.extract(from: "ok press return", triggers: []).text, "ok press return")
    }

    func testVoiceReturnPrefersTheLongestPhraseAndNormalisesTheList() {
        let result = TBDVoiceReturn.extract(from: "ok press return", triggers: ["return", "press return"])
        XCTAssertEqual(result.text, "ok")
        XCTAssertEqual(result.trigger, "press return")
        XCTAssertEqual(TBDVoiceReturn.normalized([" Send it ", "send it", "", "  ", "go"]), ["Send it", "go"])
        XCTAssertEqual(TBDVoiceReturn.normalizedOrDefault([" "]), ["press return"])
    }

    func testPipelineSetsPressReturnOnlyWhenEnabledPhraseEndsTheText() {
        let pipeline = TBDTextPipeline()
        let on = pipeline.process("um send it press return", voiceReturnTriggers: ["press return"])
        XCTAssertEqual(on.text, "Send it")
        XCTAssertTrue(on.pressReturn)
        let off = pipeline.process("um send it press return")
        XCTAssertEqual(off.text, "Send it press return")
        XCTAssertFalse(off.pressReturn)
        let only = pipeline.process("press return", voiceReturnTriggers: ["press return"])
        XCTAssertEqual(only.text, "")
        XCTAssertTrue(only.pressReturn)
    }

    // MARK: Silence auto-stop

    func testSilenceAutoStopFiresOnceAfterTheDelay() {
        var stop = TBDSilenceAutoStop(delay: 2, start: 100)
        XCTAssertFalse(stop.feed(level: 0, at: 101))
        XCTAssertFalse(stop.feed(level: 0.03, at: 101.5), "a level at the threshold is speech")
        XCTAssertFalse(stop.feed(level: 0.029, at: 103.4), "1.9 s of quiet")
        XCTAssertTrue(stop.feed(level: 0.029, at: 103.5), "2.0 s of quiet")
        XCTAssertFalse(stop.feed(level: 0, at: 110), "fires once")
    }

    func testSilenceAutoStopCountsFromRecordingStartAndSpeechResetsIt() {
        var stop = TBDSilenceAutoStop(delay: 1, start: 50)
        XCTAssertTrue(stop.feed(level: 0, at: 51), "never spoke: stops one delay after the start")
        var talker = TBDSilenceAutoStop(delay: 1, start: 50)
        XCTAssertFalse(talker.feed(level: 0.5, at: 50.9))
        XCTAssertFalse(talker.feed(level: 0, at: 51.8))
        XCTAssertTrue(talker.feed(level: 0, at: 51.9))
        XCTAssertEqual(TBDSilenceAutoStop.delays, [1, 1.5, 2, 3, 5])
    }

    // MARK: Placement

    func testPlacementGivesExactFramesForAScreenWithADockAndANotch() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
        let usable = TBDDictationOverlayLayout.usableFrame(screenFrame: screen, visibleFrame: visible, topInset: 37)
        XCTAssertEqual(usable, CGRect(x: 0, y: 70, width: 1440, height: 793))
        let panel = CGSize(width: 460, height: 132)
        XCTAssertEqual(TBDDictationOverlayLayout.origin(in: usable, panelSize: panel, placement: .bottom), CGPoint(x: 490, y: 82))
        XCTAssertEqual(TBDDictationOverlayLayout.origin(in: usable, panelSize: panel, placement: .top), CGPoint(x: 490, y: 719))
    }

    func testPlacementOnASecondScreenAndATooSmallFrame() {
        let screen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let usable = TBDDictationOverlayLayout.usableFrame(screenFrame: screen, visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055), topInset: 0)
        XCTAssertEqual(usable, CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        let panel = CGSize(width: 460, height: 132)
        XCTAssertEqual(TBDDictationOverlayLayout.origin(in: usable, panelSize: panel, placement: .bottom), CGPoint(x: 2170, y: 12))
        XCTAssertEqual(TBDDictationOverlayLayout.origin(in: usable, panelSize: panel, placement: .top), CGPoint(x: 2170, y: 911))
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 100)
        XCTAssertEqual(TBDDictationOverlayLayout.origin(in: tiny, panelSize: panel, placement: .top), CGPoint(x: 170, y: 0), "never below the usable bottom")
        XCTAssertTrue(TBDOverlayPlacement.top.anchorsToTop)
        XCTAssertFalse(TBDOverlayPlacement.bottom.anchorsToTop)
    }

    func testPreviewTextSizeMetricsAreV1s() {
        XCTAssertEqual(TBDPreviewTextSize.allCases.map(\.fontSize), [13, 16, 19])
        XCTAssertEqual(TBDPreviewTextSize.allCases.map(\.visibleHeight), [50, 62, 76])
        XCTAssertEqual(TBDPreviewTextSize.allCases.map(\.title), ["Small", "Medium", "Large"])
    }

    // MARK: Escape

    func testEscapeToggleOnAndOff() {
        var gesture = TBDHotkeyGesture()
        _ = gesture.press(at: 0)
        XCTAssertEqual(gesture.armed(), .start)
        XCTAssertEqual(gesture.state, .holding)
        XCTAssertEqual(gesture.escape(keyHeld: true, cancelsDictation: false), .none)
        XCTAssertEqual(gesture.state, .holding, "off: the gesture is untouched")
        XCTAssertEqual(gesture.escape(keyHeld: true, cancelsDictation: true), .cancel)
        XCTAssertEqual(gesture.state, .blocked)

        var handsFree = TBDHotkeyGesture()
        _ = handsFree.press(at: 0)
        XCTAssertEqual(handsFree.release(at: 10), .startHandsFree)
        XCTAssertEqual(handsFree.escape(keyHeld: false, cancelsDictation: false), .none)
        XCTAssertEqual(handsFree.state, .handsFree)
        XCTAssertEqual(handsFree.escape(keyHeld: false, cancelsDictation: true), .cancel)
        XCTAssertEqual(handsFree.state, .idle)
    }

    // MARK: Streaming cursor

    func testStreamableText() {
        XCTAssertTrue(TBDStreamingCursor.isStreamable("Hello world. "))
        XCTAssertFalse(TBDStreamingCursor.isStreamable(""))
        XCTAssertFalse(TBDStreamingCursor.isStreamable("two\nlines"))
        XCTAssertFalse(TBDStreamingCursor.isStreamable("tab\there"))
        XCTAssertTrue(TBDStreamingCursor.inputSourceAllowsStreaming(asciiCapable: true))
        XCTAssertFalse(TBDStreamingCursor.inputSourceAllowsStreaming(asciiCapable: false))
        XCTAssertFalse(TBDStreamingCursor.inputSourceAllowsStreaming(asciiCapable: nil), "unknown fails closed")
    }

    func testChunksNeverSplitACharacterAndStayWithinTheEventLimit() {
        XCTAssertEqual(TBDStreamingCursor.chunks(String(repeating: "a", count: 45)).map(\.count), [20, 20, 5])
        let family = "👨‍👩‍👧"   // one character, 8 UTF-16 units
        let chunks = TBDStreamingCursor.chunks(String(repeating: family, count: 5))
        XCTAssertEqual(chunks.map { $0.utf16.count }, [16, 16, 8])
        XCTAssertEqual(chunks.joined(), String(repeating: family, count: 5))
    }

    func testShortTextIsTypedAtOnceAndLongerTextEasesOverUnderHalfASecond() {
        XCTAssertEqual(TBDStreamingSchedule.batches(for: "Hi"), [TBDStreamingBatch(text: "Hi", delayBefore: .zero)])
        XCTAssertEqual(TBDStreamingSchedule.batches(for: ""), [])
        let text = "Hello you"
        let batches = TBDStreamingSchedule.batches(for: text)
        XCTAssertEqual(batches.map(\.text).joined(), text)
        XCTAssertEqual(batches.count, 9)
        XCTAssertEqual(batches[0].delayBefore, .zero)
        let totalMs = batches.reduce(0.0) { $0 + Double($1.delayBefore.components.attoseconds) / 1e15 + Double($1.delayBefore.components.seconds) * 1000 }
        XCTAssertEqual(totalMs, 180, accuracy: 0.5, "9 characters take the 180 ms minimum")
        XCTAssertTrue(batches.dropFirst().allSatisfy { $0.delayBefore > .zero })
        let long = TBDStreamingSchedule.batches(for: String(repeating: "word ", count: 40))
        let longMs = long.reduce(0.0) { $0 + Double($1.delayBefore.components.attoseconds) / 1e15 + Double($1.delayBefore.components.seconds) * 1000 }
        XCTAssertEqual(longMs, 420, accuracy: 0.5, "long text is capped at 420 ms")
        XCTAssertLessThanOrEqual(long.count, 48 + 10)
    }

    // MARK: Pre-roll and WAV

    func testPreRollKeepsTheLastSecondAndPrependsTheLastFortyFiveHundredths() {
        var buffer = TBDPreRollBuffer()
        buffer.append((0..<20_000).map { Float($0) })
        XCTAssertEqual(buffer.count, 16_000)
        let latest = buffer.latest()
        XCTAssertEqual(latest.count, 7_200)
        XCTAssertEqual(latest.first, 12_800)
        XCTAssertEqual(latest.last, 19_999)
        XCTAssertEqual(buffer.latest(3), [19_997, 19_998, 19_999])
        buffer.clear()
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.latest(), [])
    }

    func testDroppingLeadingSamplesRewritesTheWavHeader() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("take.wav")
        let writer = try TBDWAVWriter(url: url)
        writer.append([0.5, 0.25, -0.5, 0.125, 0.0])
        try writer.close()
        XCTAssertEqual(try TBDWAVWriter.dropLeadingSamples(at: url, count: 2), 2)
        let samples = try TBDAudioDecoder.samples(from: url)
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0], -0.5, accuracy: 0.001)
        XCTAssertEqual(samples[1], 0.125, accuracy: 0.001)
        XCTAssertEqual(try TBDWAVWriter.dropLeadingSamples(at: url, count: 99), 3, "more than the file holds empties it")
        XCTAssertEqual(try TBDWAVWriter.dropLeadingSamples(at: url, count: 0), 0)
    }

    // MARK: Keep discarded dictations

    func testDiscardedDictationIsKeptOnlyWhenBothSwitchesAreOn() {
        XCTAssertTrue(TBDDiscardedDictation.shouldKeep(preserve: true, keepHistory: true))
        XCTAssertFalse(TBDDiscardedDictation.shouldKeep(preserve: true, keepHistory: false))
        XCTAssertFalse(TBDDiscardedDictation.shouldKeep(preserve: false, keepHistory: true))
    }

    func testDiscardedDictationWritesACancelledHistoryRow() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let kept = TBDDiscardedDictation.record(id: "d1", durationMs: 2300, rawText: "um this was cancelled", cleanText: "This was cancelled",
                                                engine: "parakeetV3", audioPath: nil, targetApp: "Notes")
        try db.save(kept)
        try db.save(TBDDictation(id: "d2", durationMs: 900, rawText: "finished one"))
        let rows = try db.dictations()
        let cancelled = try XCTUnwrap(rows.first { $0.id == "d1" })
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.rawText, "um this was cancelled")
        XCTAssertEqual(cancelled.cleanText, "This was cancelled")
        XCTAssertEqual(cancelled.text, "This was cancelled")
        XCTAssertEqual(cancelled.wordCount, 3)
        XCTAssertEqual(cancelled.targetApp, "Notes")
        XCTAssertEqual(cancelled.durationMs, 2300)
        XCTAssertEqual(cancelled.kind, .dictation)
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.id == "d2" }).status, .completed)
    }

    func testDictationStatusColumnIsAddedToAnExistingDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("listening.sqlite")
        do { try TBDListeningDatabase(url: url).save(TBDDiscardedDictation.record(id: "x", durationMs: 1, rawText: "a b", cleanText: nil, engine: nil, audioPath: nil, targetApp: nil)) }
        XCTAssertEqual(try TBDListeningDatabase(url: url).dictations().first?.status, .cancelled)
    }

    // MARK: Preferences

    func testBehaviourDefaultsAreV1sAndValuesRoundTrip() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let prefs = TBDListeningPreferences(defaults: defaults)
        XCTAssertFalse(prefs.pauseMediaDuringDictation)
        XCTAssertFalse(prefs.playDictationCaptureSounds)
        XCTAssertTrue(prefs.escapeCancelsDictation)
        XCTAssertFalse(prefs.preserveDiscardedDictations)
        XCTAssertFalse(prefs.instantDictationEnabled)
        XCTAssertFalse(prefs.keepDictationOnClipboard)
        XCTAssertFalse(prefs.dictationStreamingCursorEnabled)
        XCTAssertEqual(prefs.dictationPreviewTextSize, .medium)
        XCTAssertTrue(prefs.showIdlePill)
        XCTAssertEqual(prefs.dictationOverlayPlacement, .bottom)
        XCTAssertFalse(prefs.silenceAutoStop)
        XCTAssertEqual(prefs.silenceDelay, 2.0)
        XCTAssertEqual(prefs.dictationInsertionStyle, .sentence)
        XCTAssertFalse(prefs.voiceReturnEnabled)
        XCTAssertEqual(prefs.voiceReturnTriggers, ["press return"])
        XCTAssertTrue(prefs.notifyOnTranscriptionComplete)
        XCTAssertTrue(prefs.notifyOnMeetingEnd)
        XCTAssertNil(prefs.meetingArtifactsFolder)

        prefs.escapeCancelsDictation = false
        prefs.dictationOverlayPlacement = .top
        prefs.dictationPreviewTextSize = .large
        prefs.silenceDelay = 3
        prefs.dictationInsertionStyle = .inline
        prefs.voiceReturnTriggers = ["send it", "Send It", "go"]
        prefs.showIdlePill = false
        XCTAssertFalse(prefs.escapeCancelsDictation)
        XCTAssertEqual(prefs.dictationOverlayPlacement, .top)
        XCTAssertEqual(prefs.dictationPreviewTextSize, .large)
        XCTAssertEqual(prefs.silenceDelay, 3)
        XCTAssertEqual(prefs.dictationInsertionStyle, .inline)
        XCTAssertEqual(prefs.voiceReturnTriggers, ["send it", "go"])
        XCTAssertFalse(prefs.showIdlePill)
        XCTAssertEqual(defaults.string(forKey: "tbd.listening.dictationOverlayPlacement"), "top")
        defaults.set("diagonal", forKey: "tbd.listening.dictationOverlayPlacement")
        XCTAssertEqual(prefs.dictationOverlayPlacement, .bottom, "an unknown stored value falls back")
    }

    func testMeetingArtifactsFolderMustBeAbsolute() {
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let prefs = TBDListeningPreferences(defaults: defaults)
        prefs.meetingArtifactsFolder = "relative/folder"
        XCTAssertNil(prefs.meetingArtifactsFolder)
        prefs.meetingArtifactsFolder = "/tmp/tbd-meetings/../tbd-meetings2"
        XCTAssertEqual(prefs.meetingArtifactsFolder, "/tmp/tbd-meetings2")
        prefs.meetingArtifactsFolder = nil
        XCTAssertNil(prefs.meetingArtifactsFolder)
        XCTAssertNil(TBDListeningPreferences.normalizedFolder("  "))
    }
}
