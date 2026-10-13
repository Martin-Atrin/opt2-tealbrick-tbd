import UserNotifications
import XCTest
import TBDSpeech
@testable import TBDListening

@MainActor
final class FakeBoard: TBDPasteboarding {
    var items: [[String: Data]]
    private(set) var changeCount = 0
    var failWrites = false
    init(items: [[String: Data]] = []) { self.items = items }
    func snapshot() -> [[String: Data]] { items }
    func clear() { items = []; changeCount += 1 }
    func setString(_ text: String) -> Bool {
        guard !failWrites else { return false }
        items = [["public.utf8-plain-text": Data(text.utf8)]]; changeCount += 1
        return true
    }
    func restore(_ restored: [[String: Data]]) { if !restored.isEmpty { items = restored; changeCount += 1 } }
    /// Someone else (the user, another app) puts something on the clipboard.
    func external(_ text: String) { items = [["public.utf8-plain-text": Data(text.utf8)]]; changeCount += 1 }
}

@MainActor
final class FakeKeys: TBDKeySending {
    var log: [String] = []
    var failPaste = false
    func paste() throws { if failPaste { throw TBDClipboardPaster.PasteError.eventFailed }; log.append("paste") }
    func returnKey() throws { log.append("return") }
}

@MainActor
final class ClipboardPasterTests: XCTestCase {
    private var board: FakeBoard!
    private var keys: FakeKeys!
    private var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
    private var sleeps: [Duration] = []
    private var trusted = true
    private let original: [[String: Data]] = [["public.rtf": Data("rich".utf8), "public.utf8-plain-text": Data("before".utf8)], ["public.png": Data([1, 2, 3])]]

    private func paster() -> TBDClipboardPaster {
        TBDClipboardPaster(board: board, keys: keys, isTrusted: { [unowned self] in trusted },
                           schedule: { [unowned self] delay, work in scheduled.append((delay, work)) },
                           sleep: { [unowned self] in sleeps.append($0) })
    }

    override func setUp() {
        board = FakeBoard(items: original)
        keys = FakeKeys()
        scheduled = []; sleeps = []; trusted = true
    }

    private func text(_ board: FakeBoard) -> String? { board.items.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) } }

    func testDefaultPasteRestoresTheExactPreviousClipboardAfterTheDelay() async throws {
        try await paster().insert("Hello there. ", keepOnClipboard: false, pressReturn: false)
        XCTAssertEqual(keys.log, ["paste"])
        XCTAssertEqual(board.items, [["public.utf8-plain-text": Data("Hello there. ".utf8)]], "the text is on the clipboard while Cmd-V runs")
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled[0].0, 1.5)
        scheduled[0].1()
        XCTAssertEqual(board.items, original, "every type of every item is back")
    }

    func testKeepOnClipboardLeavesTheTextAndNeverRestores() async throws {
        try await paster().insert("Hello there. ", keepOnClipboard: true, pressReturn: false)
        XCTAssertEqual(keys.log, ["paste"])
        XCTAssertEqual(scheduled.count, 0)
        XCTAssertEqual(board.items, [["public.utf8-plain-text": Data("Hello there. ".utf8)]])
    }

    func testRestoreIsSkippedWhenTheClipboardChangedMeanwhile() async throws {
        try await paster().insert("Hello", keepOnClipboard: false, pressReturn: false)
        board.external("copied by the user")
        scheduled[0].1()
        XCTAssertEqual(text(board), "copied by the user")
    }

    func testAnOlderRestoreDoesNotRunAfterANewerPaste() async throws {
        let p = paster()
        try await p.insert("one", keepOnClipboard: false, pressReturn: false)
        try await p.insert("two", keepOnClipboard: false, pressReturn: false)
        scheduled[0].1()
        XCTAssertEqual(text(board), "two", "the first restore is stale")
        scheduled[1].1()
        XCTAssertEqual(board.items, original, "the second restores the person's clipboard, not the first dictation")
    }

    func testWithoutAccessibilityTheTextStaysOnTheClipboardAndTheErrorSaysSo() async {
        trusted = false
        do {
            try await paster().insert("Hello", keepOnClipboard: false, pressReturn: false)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TBDClipboardPaster.PasteError, .accessibilityRequired)
            XCTAssertEqual(error.localizedDescription, "Allow TBD in System Settings → Privacy & Security → Accessibility to paste automatically. The text is on the clipboard.")
        }
        XCTAssertEqual(text(board), "Hello")
        XCTAssertEqual(keys.log, [])
        XCTAssertEqual(scheduled.count, 0)
    }

    func testFailedShortcutAndFailedClipboardWrite() async {
        keys.failPaste = true
        do { try await paster().insert("Hello", keepOnClipboard: false, pressReturn: false); XCTFail() } catch {
            XCTAssertEqual(error as? TBDClipboardPaster.PasteError, .eventFailed)
        }
        keys.failPaste = false
        board = FakeBoard(items: original)
        board.failWrites = true
        do { try await paster().insert("Hello", keepOnClipboard: false, pressReturn: false); XCTFail() } catch {
            XCTAssertEqual(error as? TBDClipboardPaster.PasteError, .clipboardWriteFailed)
        }
        XCTAssertEqual(board.items, original, "a failed write puts the old clipboard back")
    }

    func testVoiceReturnPressesReturnAfterThePasteWithoutATrailingSpace() async throws {
        try await paster().insert("Send it", keepOnClipboard: false, pressReturn: true)
        XCTAssertEqual(keys.log, ["paste", "return"])
        XCTAssertEqual(sleeps, [.milliseconds(200)])
    }

    func testVoiceReturnAloneOnlyPressesReturnAndLeavesTheClipboard() async throws {
        try await paster().insert("", keepOnClipboard: false, pressReturn: true)
        XCTAssertEqual(keys.log, ["return"])
        XCTAssertEqual(board.items, original)
        keys.log = []
        try await paster().insert("  ", keepOnClipboard: false, pressReturn: false)
        XCTAssertEqual(keys.log, [], "nothing to paste and no action")
        XCTAssertEqual(board.items, original)
    }

    func testVoiceReturnAloneNeedsAccessibility() async {
        trusted = false
        do { try await paster().insert("", keepOnClipboard: false, pressReturn: true); XCTFail() } catch {
            XCTAssertEqual(error as? TBDClipboardPaster.PasteError, .accessibilityRequired)
        }
    }
}

final class FakeCenter: TBDNotificationCenter, @unchecked Sendable {
    var authorized = true
    private(set) var requests: [UNNotificationRequest] = []
    func isAuthorized() async -> Bool { authorized }
    func add(_ request: UNNotificationRequest) async throws { requests.append(request) }
}

@MainActor
final class NotifierTests: XCTestCase {
    func testRequestCarriesTheExactTitleAndBodyWithNoSoundAndNoTrigger() {
        let request = TBDNotifier.request(for: TBDCompletionNotice.Content(title: "Interview", body: "Transcription complete \u{00B7} 250 words"), id: "abc")
        XCTAssertEqual(request.identifier, "tbd.listening.transcription.abc")
        XCTAssertEqual(request.content.title, "Interview")
        XCTAssertEqual(request.content.body, "Transcription complete \u{00B7} 250 words")
        XCTAssertNil(request.content.sound)
        XCTAssertNil(request.trigger, "delivered at once")
    }

    func testChimeAlwaysAndBannerOnlyWhileTheAppIsInTheBackground() async throws {
        let center = FakeCenter()
        var chimes = 0
        var active = false
        let notifier = TBDNotifier(center: { center }, isAppActive: { active }, chime: { chimes += 1 })
        let content = TBDCompletionNotice.Content(title: "Roadmap", body: "Meeting transcript ready \u{00B7} 10 words")
        await notifier.present(content)?.value
        XCTAssertEqual(chimes, 1)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.content.title, "Roadmap")
        XCTAssertEqual(center.requests.first?.content.body, "Meeting transcript ready \u{00B7} 10 words")

        active = true
        XCTAssertNil(notifier.present(content))
        XCTAssertEqual(chimes, 2)
        XCTAssertEqual(center.requests.count, 1, "no banner while the app is in front")
    }

    func testNoBannerWhenNotificationsAreNotAllowed() async {
        let center = FakeCenter()
        center.authorized = false
        let notifier = TBDNotifier(center: { center }, isAppActive: { false }, chime: {})
        await notifier.present(TBDCompletionNotice.Content(title: "T", body: "B"))?.value
        XCTAssertEqual(center.requests.count, 0)
    }
}

final class MediaBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: TBDNowPlaying?
    private var _sent: [Bool] = []
    private var _snapshots = 0
    init(_ now: TBDNowPlaying?) { _now = now }
    var now: TBDNowPlaying? { get { lock.withLock { _now } } set { lock.withLock { _now = newValue } } }
    var sent: [Bool] { lock.withLock { _sent } }
    var snapshots: Int { lock.withLock { _snapshots } }
    func snapshot() -> TBDNowPlaying? { lock.withLock { _snapshots += 1; return _now } }
    func send(_ pause: Bool) -> Bool { lock.withLock { _sent.append(pause); return true } }
}

@MainActor
final class DictationMediaTests: XCTestCase {
    private let player = TBDNowPlaying(isPlaying: true, processIdentifier: 42, bundleIdentifier: "example.player")

    private func media(_ box: MediaBox) -> TBDDictationMedia {
        TBDDictationMedia(snapshot: { box.snapshot() }, send: { box.send($0) })
    }

    private func pauseAndWait(_ media: TBDDictationMedia, enabled: Bool = true, meeting: Bool = false) async -> Bool {
        let paused = expectation(description: "paused")
        paused.isInverted = !enabled || meeting
        var fired = false
        media.requestPause(enabled: enabled, meetingActive: meeting) { fired = true; paused.fulfill() }
        await fulfillment(of: [paused], timeout: paused.isInverted ? 0.3 : 3)
        return fired
    }

    func testPlayingMediaIsPausedThenResumedOnce() async {
        let box = MediaBox(player)
        let media = media(box)
        let fired = await pauseAndWait(media)
        XCTAssertTrue(fired)
        XCTAssertTrue(media.isPaused)
        XCTAssertEqual(box.sent, [true])
        box.now = TBDNowPlaying(isPlaying: false, processIdentifier: 42, bundleIdentifier: "example.player")
        await media.resume()
        XCTAssertEqual(box.sent, [true, false])
        XCTAssertFalse(media.isPaused)
        await media.resume()
        XCTAssertEqual(box.sent, [true, false], "nothing left to resume")
    }

    func testNothingHappensWhenOffDuringAMeetingOrWhenNothingPlays() async {
        let off = MediaBox(player)
        var fired = await pauseAndWait(media(off), enabled: false)
        XCTAssertFalse(fired)
        XCTAssertEqual(off.snapshots, 0, "off: the system is not even asked")
        let meeting = MediaBox(player)
        fired = await pauseAndWait(media(meeting), meeting: true)
        XCTAssertFalse(fired)
        XCTAssertEqual(meeting.sent, [])
        let silent = MediaBox(TBDNowPlaying(isPlaying: false, processIdentifier: 42, bundleIdentifier: "example.player"))
        let silentMedia = media(silent)
        silentMedia.requestPause(enabled: true, meetingActive: false)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(silent.sent, [])
        XCTAssertFalse(silentMedia.isPaused)
        let unknown = MediaBox(TBDNowPlaying(isPlaying: true, processIdentifier: nil, bundleIdentifier: nil))
        let unknownMedia = media(unknown)
        unknownMedia.requestPause(enabled: true, meetingActive: false)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(unknown.sent, [], "a player with no identity is not paused: it could not be matched on resume")
    }

    func testResumeSkipsAChangedOrAlreadyPlayingPlayer() async {
        let box = MediaBox(player)
        let media = media(box)
        _ = await pauseAndWait(media)
        box.now = TBDNowPlaying(isPlaying: false, processIdentifier: 99, bundleIdentifier: "example.other")
        await media.resume()
        XCTAssertEqual(box.sent, [true], "a different player is left alone")

        let second = MediaBox(player)
        let again = self.media(second)
        _ = await pauseAndWait(again)
        second.now = player   // the person pressed play themselves
        await again.resume()
        XCTAssertEqual(second.sent, [true])
    }

    func testDecodingTheHelperOutput() {
        let playing = TBDNowPlaying.decode(Data(#"{"available":true,"playing":true,"playbackRate":1,"processIdentifier":42,"bundleIdentifier":"example.player"}"#.utf8))
        XCTAssertEqual(playing, TBDNowPlaying(isPlaying: true, processIdentifier: 42, bundleIdentifier: "example.player"))
        XCTAssertNil(TBDNowPlaying.decode(Data(#"{"available":false}"#.utf8)))
        XCTAssertNil(TBDNowPlaying.decode(Data("nope".utf8)))
        XCTAssertEqual(TBDNowPlaying.decode(Data(#"{"playbackRate":0.5,"processIdentifier":-1,"bundleIdentifier":""}"#.utf8)),
                       TBDNowPlaying(isPlaying: true, processIdentifier: nil, bundleIdentifier: nil))
        XCTAssertTrue(player.matches(TBDMediaPauseToken(processIdentifier: 42, bundleIdentifier: "example.player")))
        XCTAssertFalse(player.matches(TBDMediaPauseToken(processIdentifier: 42, bundleIdentifier: "example.other")))
        XCTAssertFalse(player.matches(TBDMediaPauseToken(processIdentifier: nil, bundleIdentifier: nil)))
    }
}

@MainActor
final class SoundAndHubTests: XCTestCase {
    func testCuesUseV1sSystemSoundsAndVolumes() {
        XCTAssertEqual(TBDSoundCue.recordStart.systemName, "Tink")
        XCTAssertEqual(TBDSoundCue.recordStop.systemName, "Pop")
        XCTAssertEqual(TBDSoundCue.complete.systemName, "Glass")
        XCTAssertEqual(TBDSoundCue.allCases.map(\.volume), [0.4, 0.4, 1.0])
        XCTAssertEqual(TBDSoundCue.allCases.map(\.restartsWhilePlaying), [true, true, false])
    }

    func testSoundsFollowTheMacOSSoundEffectsSetting() {
        XCTAssertTrue(TBDSounds.systemSoundEffectsEnabled(globalDomain: nil))
        XCTAssertTrue(TBDSounds.systemSoundEffectsEnabled(globalDomain: [:]))
        XCTAssertTrue(TBDSounds.systemSoundEffectsEnabled(globalDomain: ["com.apple.sound.uiaudio.enabled": true]))
        XCTAssertFalse(TBDSounds.systemSoundEffectsEnabled(globalDomain: ["com.apple.sound.uiaudio.enabled": false]))
    }

    func testTranscriptSavedHubCallsHandlersInOrderAndRemoves() {
        let hub = TBDTranscriptSavedHub()
        var log: [String] = []
        let first = hub.add { log.append("a:" + $0.title) }
        hub.add { log.append("b:" + $0.title) }
        let item = TBDTranscription(title: "T", sourceKind: .file, status: .completed)
        hub.publish(item)
        XCTAssertEqual(log, ["a:T", "b:T"])
        hub.remove(first)
        hub.publish(item)
        XCTAssertEqual(log, ["a:T", "b:T", "b:T"])
    }
}

final class FakePoster: TBDStreamingPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _posted: [String] = []
    var failOn: Int?
    var posted: [String] { lock.withLock { _posted } }
    func typeUnicode(_ text: String) throws {
        try lock.withLock {
            if let failOn, _posted.count == failOn { throw TBDStreamingError.unavailable }
            _posted.append(text)
        }
    }
}

final class StreamingTests: XCTestCase {
    func testPlaybackTypesGroupsInOrderAndTheInterruptFlushesTheRest() throws {
        let poster = FakePoster()
        let playback = TBDStreamingPlayback(posting: poster, batches: ["ab", "cd", "ef"])
        try playback.play("ab")
        try playback.play("ef")   // not the next group: ignored
        XCTAssertEqual(poster.posted, ["ab"])
        playback.interruptAndDrain()
        XCTAssertEqual(poster.posted, ["ab", "cd", "ef"], "the rest lands at once, before the person's key")
        XCTAssertTrue(playback.isInterrupted)
        try playback.play("cd")
        XCTAssertEqual(poster.posted.count, 3, "nothing is typed twice")
    }

    func testAFailedGroupStaysQueuedAndReportsPartialProgress() {
        let poster = FakePoster()
        poster.failOn = 1
        let playback = TBDStreamingPlayback(posting: poster, batches: ["ab", "cd"])
        XCTAssertNoThrow(try playback.play("ab"))
        XCTAssertThrowsError(try playback.play("cd"))
        XCTAssertEqual(playback.committed, 1)
        poster.failOn = nil
        XCTAssertNoThrow(try playback.drainRemaining())
        XCTAssertEqual(poster.posted, ["ab", "cd"])
    }

    @MainActor
    func testInserterTypesTheWholeTextInSchedule() async throws {
        let poster = FakePoster()
        let inserter = TBDStreamingInserter(posting: poster, sleep: { _ in })
        try await inserter.insert("Hello streaming world. ")
        XCTAssertEqual(poster.posted.joined(), "Hello streaming world. ")
        XCTAssertEqual(poster.posted, TBDStreamingSchedule.batches(for: "Hello streaming world. ").map(\.text))
    }

    @MainActor
    func testInserterFailingBeforeAnyTextIsTypedThrowsTheOriginalError() async {
        let poster = FakePoster()
        poster.failOn = 0
        let inserter = TBDStreamingInserter(posting: poster, sleep: { _ in })
        do { try await inserter.insert("Hello world"); XCTFail() } catch { XCTAssertEqual(error as? TBDStreamingError, .unavailable) }
    }
}
