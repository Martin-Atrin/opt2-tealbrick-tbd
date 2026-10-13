import CoreGraphics
import XCTest
@testable import TBDSpeech

/// PARITY WP4 meeting-live: audio source modes, mic mute, activity auto-stop, meeting-end presentation,
/// and the floating pill rules. Every rule is checked for the case that acts and the case that must not.
final class MeetingLiveSettingsTests: XCTestCase {
    private func freshDefaults() throws -> (UserDefaults, TBDListeningPreferences, () -> Void) {
        let suite = "tbd.tests.meetinglive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, TBDListeningPreferences(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    func testV1DefaultsWhenTheKeysAreAbsent() throws {
        let (defaults, prefs, cleanup) = try freshDefaults()
        defer { cleanup() }
        XCTAssertEqual(prefs.meetingAudioSourceMode, .microphoneAndSystem)
        XCTAssertFalse(prefs.startMeetingsMuted)
        XCTAssertTrue(prefs.showMeetingRecordingPill)
        XCTAssertTrue(prefs.openAppAfterMeetingEnd)
        XCTAssertFalse(prefs.meetingAutoStopEnabled)
        XCTAssertTrue(prefs.notifyOnMeetingEnd)
        // Reading never writes: an existing user's settings are not rewritten on upgrade.
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("tbd.listening.") }.isEmpty)
    }

    func testStoredValuesAreReadBackUnderTheTbdKeys() throws {
        let (defaults, prefs, cleanup) = try freshDefaults()
        defer { cleanup() }
        prefs.meetingAudioSourceMode = .systemOnly
        prefs.startMeetingsMuted = true
        prefs.showMeetingRecordingPill = false
        prefs.openAppAfterMeetingEnd = false
        prefs.meetingAutoStopEnabled = true
        XCTAssertEqual(defaults.string(forKey: "tbd.listening.meetingAudioSourceMode"), "system_only")
        XCTAssertEqual(defaults.object(forKey: "tbd.listening.startMeetingsMuted") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "tbd.listening.showMeetingRecordingPill") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "tbd.listening.openAppAfterMeetingEnd") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "tbd.listening.meetingAutoStopEnabled") as? Bool, true)
        XCTAssertEqual(prefs.meetingAudioSourceMode, .systemOnly)
        XCTAssertTrue(prefs.startMeetingsMuted)
        XCTAssertFalse(prefs.showMeetingRecordingPill)
        XCTAssertFalse(prefs.openAppAfterMeetingEnd)
        XCTAssertTrue(prefs.meetingAutoStopEnabled)
    }

    func testAnUnknownStoredSourceReadsAsTheDefault() throws {
        let (defaults, prefs, cleanup) = try freshDefaults()
        defer { cleanup() }
        defaults.set("everything", forKey: "tbd.listening.meetingAudioSourceMode")
        XCTAssertEqual(prefs.meetingAudioSourceMode, .microphoneAndSystem)
    }

    func testAudioSourceModesCaptureTheRightSources() {
        XCTAssertEqual(TBDMeetingAudioSource.allCases.map(\.rawValue), ["microphone_and_system", "microphone_only", "system_only"])
        XCTAssertEqual(TBDMeetingAudioSource.allCases.map(\.capturesMicrophone), [true, true, false])
        XCTAssertEqual(TBDMeetingAudioSource.allCases.map(\.capturesSystemAudio), [true, false, true])
        XCTAssertEqual(TBDMeetingAudioSource.allCases.map(\.title), ["Microphone + system audio", "Microphone only", "System audio only"])
        XCTAssertEqual(TBDMeetingAudioSource.default, .microphoneAndSystem)
        for mode in TBDMeetingAudioSource.allCases {
            XCTAssertTrue(mode.capturesMicrophone || mode.capturesSystemAudio, "\(mode) must record something")
            XCTAssertFalse(mode.detail.isEmpty)
        }
    }
}

final class MeetingMicMuteTests: XCTestCase {
    func testMutedAudioKeepsItsLengthButCarriesSilenceAndShowsNoLevel() {
        let speech: [Float] = [0.5, -0.4, 0.3, -0.2]
        let muted = TBDMicMute.apply(speech, muted: true)
        XCTAssertEqual(muted.samples, [0, 0, 0, 0])
        XCTAssertEqual(muted.level, 0)
    }

    func testUnmutedAudioPassesThroughUnchangedWithItsLevel() {
        let speech: [Float] = [0.5, -0.5, 0.5, -0.5]
        let open = TBDMicMute.apply(speech, muted: false)
        XCTAssertEqual(open.samples, speech)
        XCTAssertEqual(open.level, TBDAudioLevel.normalized(speech))
        XCTAssertEqual(open.level, 1, accuracy: 0.0001)
    }

    func testMutingEmptyAudioStaysEmpty() {
        XCTAssertEqual(TBDMicMute.apply([], muted: true).samples, [])
    }

    func testTheMuteControlNeedsARunningRecordingThatCapturesTheMicrophone() {
        XCTAssertTrue(TBDMicMute.canMute(source: .microphoneAndSystem, recording: true))
        XCTAssertTrue(TBDMicMute.canMute(source: .microphoneOnly, recording: true))
        XCTAssertFalse(TBDMicMute.canMute(source: .systemOnly, recording: true))
        XCTAssertFalse(TBDMicMute.canMute(source: .microphoneAndSystem, recording: false))
    }

    func testStartMutedAppliesOnlyWhenTheMicrophoneIsRecorded() {
        XCTAssertTrue(TBDMicMute.startsMuted(setting: true, source: .microphoneAndSystem))
        XCTAssertTrue(TBDMicMute.startsMuted(setting: true, source: .microphoneOnly))
        XCTAssertFalse(TBDMicMute.startsMuted(setting: true, source: .systemOnly))
        XCTAssertFalse(TBDMicMute.startsMuted(setting: false, source: .microphoneAndSystem))
    }

    func testAnIdleRecorderCannotMute() {
        let recorder = TBDMeetingRecorder()
        XCTAssertFalse(recorder.canMuteMic)
        XCTAssertFalse(recorder.setMicMuted(true))
        XCTAssertFalse(recorder.isMicMuted)
    }
}

final class MeetingAutoStopPolicyTests: XCTestCase {
    private let zoom = "us.zoom.xos"
    private let teams = "com.microsoft.teams2"
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func decide(observed: Set<String>, running: Set<String>, silence: TimeInterval = 0, paused: Bool = false,
                        recording: Bool = true, config: TBDMeetingAutoStopPolicy.Config = .default) -> TBDMeetingAutoStopPolicy.Decision {
        TBDMeetingAutoStopPolicy.evaluate(
            context: .init(observedApps: observed, startedAt: start),
            observation: .init(now: start, isRecording: recording, isPaused: paused, runningApps: running, continuousSilenceSeconds: silence),
            config: config)
    }

    func testV1Thresholds() {
        let config = TBDMeetingAutoStopPolicy.Config.default
        XCTAssertEqual(config.appQuitGraceSeconds, 15)
        XCTAssertEqual(config.silenceGraceSeconds, 240)
        XCTAssertTrue(config.appQuitEnabled && config.silenceEnabled)
        XCTAssertEqual(TBDMeetingAutoStopMonitor.countdownSeconds, 15)
        XCTAssertEqual(TBDMeetingAutoStopMonitor.silenceLevel, 0.1, accuracy: 0.0001)
    }

    func testAClosedMeetingAppProposesAStopNamingTheApp() {
        XCTAssertEqual(decide(observed: [zoom], running: []), .proposeStop(.meetingAppClosed(bundleID: zoom)))
    }

    func testARunningMeetingAppKeepsRecording() {
        XCTAssertEqual(decide(observed: [zoom], running: [zoom]), .keepRecording)
    }

    func testWhenSeveralAppsClosedTheFirstByBundleIDIsNamed() {
        XCTAssertEqual(decide(observed: [zoom, teams], running: []), .proposeStop(.meetingAppClosed(bundleID: teams)))
    }

    func testSilenceProposesAStopOnlyAtTheGraceLimit() {
        XCTAssertEqual(decide(observed: [], running: [], silence: 239.99), .keepRecording)
        XCTAssertEqual(decide(observed: [], running: [], silence: 240), .proposeStop(.prolongedSilence))
        XCTAssertEqual(decide(observed: [], running: [], silence: 600), .proposeStop(.prolongedSilence))
    }

    func testAClosedAppWinsOverSilence() {
        XCTAssertEqual(decide(observed: [zoom], running: [], silence: 900), .proposeStop(.meetingAppClosed(bundleID: zoom)))
    }

    func testAPausedOrIdleRecordingIsNeverStopped() {
        XCTAssertEqual(decide(observed: [zoom], running: [], silence: 900, paused: true), .keepRecording)
        XCTAssertEqual(decide(observed: [zoom], running: [], silence: 900, recording: false), .keepRecording)
    }

    func testDisabledSignalsAreIgnored() {
        let noApp = TBDMeetingAutoStopPolicy.Config(appQuitEnabled: false)
        XCTAssertEqual(decide(observed: [zoom], running: [], config: noApp), .keepRecording)
        let noSilence = TBDMeetingAutoStopPolicy.Config(silenceEnabled: false)
        XCTAssertEqual(decide(observed: [], running: [], silence: 900, config: noSilence), .keepRecording)
    }

    func testOnlyNativeConferencingAppsAreRecognised() {
        XCTAssertEqual(TBDMeetingApps.nativeBundleIDs.count, 6)
        for id in ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.apple.FaceTime"] {
            XCTAssertTrue(TBDMeetingApps.isRecognized(id), id)
        }
        XCTAssertFalse(TBDMeetingApps.isRecognized("com.google.Chrome"))
        XCTAssertFalse(TBDMeetingApps.isRecognized("com.tinyspeck.slackmacgap"))
    }

    func testTheCountdownTitlesAreTheV1Wording() {
        XCTAssertEqual(TBDMeetingAutoStopPolicy.StopReason.meetingAppClosed(bundleID: zoom).countdownTitle, "Meeting app closed")
        XCTAssertEqual(TBDMeetingAutoStopPolicy.StopReason.prolongedSilence.countdownTitle, "This meeting looks finished")
    }
}

final class MeetingAutoStopMonitorTests: XCTestCase {
    private typealias Reason = TBDMeetingAutoStopPolicy.StopReason
    private let zoom = "us.zoom.xos"
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func signals(_ seconds: TimeInterval, running: Set<String> = [], mic: Float = 0.5, system: Float = 0.5,
                         paused: Bool = false) -> TBDMeetingAutoStopMonitor.Signals {
        .init(now: t0.addingTimeInterval(seconds), runningApps: running, micLevel: mic, systemLevel: system, isPaused: paused)
    }

    private func started(running: Set<String> = []) -> TBDMeetingAutoStopMonitor {
        var monitor = TBDMeetingAutoStopMonitor()
        monitor.begin(runningApps: running, now: t0)
        return monitor
    }

    // MARK: Meeting app quits

    func testAppQuitShowsTheCountdownOnlyAfterTheFifteenSecondGrace() {
        var monitor = started(running: [zoom])
        XCTAssertEqual(monitor.observe(signals(1, running: [zoom])), .none)
        XCTAssertEqual(monitor.observe(signals(2, running: [])), .none, "first poll without the app starts the grace clock")
        XCTAssertEqual(monitor.observe(signals(16.9, running: [])), .none, "14.9 s after the app closed")
        XCTAssertEqual(monitor.observe(signals(17, running: [])), .showCountdown(.meetingAppClosed(bundleID: zoom)))
        XCTAssertEqual(monitor.countdownReason, .meetingAppClosed(bundleID: zoom))
        XCTAssertEqual(monitor.observe(signals(18, running: [])), .none, "one countdown only")
    }

    func testACountdownThatRunsOutWhileTheAppIsStillClosedStopsTheRecording() {
        var monitor = started(running: [zoom])
        _ = monitor.observe(signals(1, running: []))
        XCTAssertEqual(monitor.observe(signals(16, running: [])), .showCountdown(.meetingAppClosed(bundleID: zoom)))
        XCTAssertTrue(monitor.countdownEnded(.completed, reason: .meetingAppClosed(bundleID: zoom), signals: signals(31, running: [])))
    }

    func testACountdownThatRunsOutAfterTheAppCameBackDoesNotStop() {
        var monitor = started(running: [zoom])
        _ = monitor.observe(signals(1, running: []))
        XCTAssertEqual(monitor.observe(signals(16, running: [])), .showCountdown(.meetingAppClosed(bundleID: zoom)))
        XCTAssertFalse(monitor.countdownEnded(.completed, reason: .meetingAppClosed(bundleID: zoom), signals: signals(31, running: [zoom])))
    }

    func testTheAppReturningClosesTheCountdownAndRestartsTheGrace() {
        var monitor = started(running: [zoom])
        _ = monitor.observe(signals(1, running: []))
        XCTAssertEqual(monitor.observe(signals(16, running: [])), .showCountdown(.meetingAppClosed(bundleID: zoom)))
        XCTAssertEqual(monitor.observe(signals(17, running: [zoom])), .closeCountdown)
        XCTAssertNil(monitor.countdownReason)
        // Closing again starts a fresh grace.
        XCTAssertEqual(monitor.observe(signals(18, running: [])), .none)
        XCTAssertEqual(monitor.observe(signals(32.9, running: [])), .none)
        XCTAssertEqual(monitor.observe(signals(33, running: [])), .showCountdown(.meetingAppClosed(bundleID: zoom)))
    }

    func testKeepRecordingVetoesThatReasonAndTheAppIsForgotten() {
        var monitor = started(running: [zoom])
        _ = monitor.observe(signals(1, running: []))
        XCTAssertEqual(monitor.observe(signals(16, running: [])), .showCountdown(.meetingAppClosed(bundleID: zoom)))
        XCTAssertFalse(monitor.countdownEnded(.userDismissed, reason: .meetingAppClosed(bundleID: zoom), signals: signals(20, running: [])))
        XCTAssertTrue(monitor.vetoed.contains(.meetingAppClosed(bundleID: zoom)))
        XCTAssertEqual(monitor.context?.observedApps, [])
        for second in stride(from: 21.0, through: 200.0, by: 1.0) {
            XCTAssertEqual(monitor.observe(signals(second, running: [], mic: 0.5, system: 0.5)), .none)
        }
    }

    func testAnAppThatQuitBetweenTwoPollsStillCounts() {
        var monitor = started(running: [])
        monitor.appTerminated(bundleID: zoom)
        XCTAssertEqual(monitor.context?.observedApps, [zoom])
        XCTAssertEqual(monitor.observe(signals(1, running: [])), .none)
        XCTAssertEqual(monitor.observe(signals(16, running: [])), .showCountdown(.meetingAppClosed(bundleID: zoom)))
    }

    func testUnrecognisedAppsNeverTriggerAStop() {
        var monitor = started(running: ["com.example.editor", "com.google.Chrome"])
        XCTAssertEqual(monitor.context?.observedApps, [])
        monitor.appTerminated(bundleID: "com.example.editor")
        XCTAssertEqual(monitor.context?.observedApps, [])
        XCTAssertEqual(monitor.observe(signals(1, running: [])), .none)
        XCTAssertEqual(monitor.observe(signals(100, running: [])), .none)
    }

    func testAMeetingAppStartedAfterTheRecordingIsWatchedToo() {
        var monitor = started(running: [])
        XCTAssertEqual(monitor.observe(signals(1, running: [zoom])), .none)
        XCTAssertEqual(monitor.context?.observedApps, [zoom])
        XCTAssertEqual(monitor.observe(signals(2, running: [])), .none)
        XCTAssertEqual(monitor.observe(signals(17, running: [])), .showCountdown(.meetingAppClosed(bundleID: zoom)))
    }

    // MARK: Silence

    func testSilenceShowsTheCountdownAfterFourMinutesOfBothChannelsQuiet() {
        var monitor = started()
        XCTAssertEqual(monitor.observe(signals(0, mic: 0, system: 0)), .none, "first quiet poll starts the clock")
        XCTAssertEqual(monitor.observe(signals(239, mic: 0, system: 0)), .none)
        XCTAssertEqual(monitor.observe(signals(240, mic: 0, system: 0)), .showCountdown(.prolongedSilence))
        XCTAssertEqual(monitor.observe(signals(241, mic: 0, system: 0)), .none)
        XCTAssertTrue(monitor.countdownEnded(.completed, reason: .prolongedSilence, signals: signals(256, mic: 0, system: 0)))
    }

    func testSoundDuringTheCountdownCancelsIt() {
        var monitor = started()
        _ = monitor.observe(signals(0, mic: 0, system: 0))
        XCTAssertEqual(monitor.observe(signals(240, mic: 0, system: 0)), .showCountdown(.prolongedSilence))
        XCTAssertEqual(monitor.observe(signals(241, mic: 0.5, system: 0)), .closeCountdown)
        XCTAssertFalse(monitor.countdownEnded(.completed, reason: .prolongedSilence, signals: signals(256, mic: 0, system: 0)))
    }

    func testAnySoundRestartsTheSilenceClock() {
        var monitor = started()
        _ = monitor.observe(signals(0, mic: 0, system: 0))
        XCTAssertEqual(monitor.observe(signals(200, mic: 0, system: 0.5)), .none)
        XCTAssertEqual(monitor.observe(signals(201, mic: 0, system: 0)), .none, "clock restarts here")
        XCTAssertEqual(monitor.observe(signals(440, mic: 0, system: 0)), .none)
        XCTAssertEqual(monitor.observe(signals(441, mic: 0, system: 0)), .showCountdown(.prolongedSilence))
    }

    func testTheSilenceLevelItselfCountsAsQuietAndAnythingAboveDoesNot() {
        var monitor = started()
        _ = monitor.observe(signals(0, mic: 0.1, system: 0.1))
        XCTAssertEqual(monitor.observe(signals(240, mic: 0.1, system: 0.1)), .showCountdown(.prolongedSilence))
        var other = started()
        _ = other.observe(signals(0, mic: 0.11, system: 0))
        XCTAssertEqual(other.observe(signals(240, mic: 0.11, system: 0)), .none)
        XCTAssertEqual(other.observe(signals(1000, mic: 0.11, system: 0)), .none)
    }

    func testAPausedRecordingNeverCountsSilenceAndUnpausingRestartsTheClock() {
        var monitor = started()
        _ = monitor.observe(signals(0, mic: 0, system: 0))
        XCTAssertEqual(monitor.observe(signals(300, mic: 0, system: 0, paused: true)), .none)
        XCTAssertEqual(monitor.observe(signals(301, mic: 0, system: 0)), .none, "clock restarts after the pause")
        XCTAssertEqual(monitor.observe(signals(540, mic: 0, system: 0)), .none)
        XCTAssertEqual(monitor.observe(signals(541, mic: 0, system: 0)), .showCountdown(.prolongedSilence))
    }

    func testKeepRecordingOnSilenceVetoesSilenceForTheRestOfTheRecording() {
        var monitor = started()
        _ = monitor.observe(signals(0, mic: 0, system: 0))
        XCTAssertEqual(monitor.observe(signals(240, mic: 0, system: 0)), .showCountdown(.prolongedSilence))
        XCTAssertFalse(monitor.countdownEnded(.userDismissed, reason: .prolongedSilence, signals: signals(245, mic: 0, system: 0)))
        XCTAssertEqual(monitor.observe(signals(500, mic: 0, system: 0)), .none)
        XCTAssertEqual(monitor.observe(signals(5000, mic: 0, system: 0)), .none)
        // A new recording forgets the veto.
        monitor.end()
        monitor.begin(runningApps: [], now: t0.addingTimeInterval(6000))
        XCTAssertTrue(monitor.vetoed.isEmpty)
    }

    func testTheCountdownEndsWithoutStoppingWhenItIsClosedByTheProgram() {
        var monitor = started()
        _ = monitor.observe(signals(0, mic: 0, system: 0))
        XCTAssertEqual(monitor.observe(signals(240, mic: 0, system: 0)), .showCountdown(.prolongedSilence))
        XCTAssertFalse(monitor.countdownEnded(.programmaticClose, reason: .prolongedSilence, signals: signals(241, mic: 0, system: 0)))
    }

    func testAnOutcomeForADifferentReasonIsIgnored() {
        var monitor = started(running: [zoom])
        _ = monitor.observe(signals(1, running: []))
        XCTAssertEqual(monitor.observe(signals(16, running: [])), .showCountdown(.meetingAppClosed(bundleID: zoom)))
        XCTAssertFalse(monitor.countdownEnded(.completed, reason: .prolongedSilence, signals: signals(31, running: [])))
        XCTAssertEqual(monitor.countdownReason, .meetingAppClosed(bundleID: zoom))
    }

    func testAnInactiveMonitorDoesNothing() {
        var monitor = TBDMeetingAutoStopMonitor()
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(monitor.observe(signals(1000, running: [], mic: 0, system: 0)), .none)
        monitor.begin(runningApps: [zoom], now: t0)
        XCTAssertTrue(monitor.isActive)
        monitor.end()
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(monitor.observe(signals(1000, running: [], mic: 0, system: 0)), .none)
    }
}

final class MeetingEndPresentationTests: XCTestCase {
    private func decide(open: Bool, notify: Bool, canPresent: Bool = true) -> TBDMeetingEndPresentation.Result {
        TBDMeetingEndPresentation.decide(openAppAfterMeetingEnd: open, notifyOnMeetingEnd: notify, canPresent: canPresent)
    }

    func testOpeningTheAppReplacesTheNotice() {
        XCTAssertEqual(decide(open: true, notify: true), .init(openApp: true, notify: false))
        XCTAssertEqual(decide(open: true, notify: false), .init(openApp: true, notify: false))
    }

    func testTheNoticeIsTheQuietPath() {
        XCTAssertEqual(decide(open: false, notify: true), .init(openApp: false, notify: true))
        XCTAssertEqual(decide(open: false, notify: false), .init(openApp: false, notify: false))
    }

    func testAFinishedMeetingDoesNothingWhileANewerOneRecords() {
        XCTAssertEqual(decide(open: true, notify: true, canPresent: false), .init(openApp: false, notify: false))
        XCTAssertEqual(decide(open: false, notify: true, canPresent: false), .init(openApp: false, notify: false))
    }
}

final class MeetingPillRulesTests: XCTestCase {
    func testThePillShowsForEveryFaceButHiddenWhenTheSettingIsOn() {
        let faces: [TBDMeetingPillFace] = [.hidden, .starting, .recording, .paused, .saving, .saved]
        XCTAssertEqual(faces.map { TBDMeetingPillRules.isVisible($0, showSetting: true) }, [false, true, true, true, true, true])
        XCTAssertEqual(faces.map { TBDMeetingPillRules.isVisible($0, showSetting: false) }, [false, false, false, false, false, false])
    }

    func testOnlyARunningRecordingCanBePaused() {
        let faces: [TBDMeetingPillFace] = [.hidden, .starting, .recording, .paused, .saving, .saved]
        XCTAssertEqual(faces.map(\.canPause), [false, false, true, true, false, false])
        XCTAssertEqual(faces.map(\.isLive), [false, true, true, true, false, false])
    }

    func testTheRecordingFaceIsTheWidestAndHiddenHasNoSize() {
        XCTAssertEqual(TBDMeetingPillRules.size(for: .hidden), .zero)
        XCTAssertEqual(TBDMeetingPillRules.size(for: .recording), CGSize(width: 354, height: 40))
        XCTAssertEqual(TBDMeetingPillRules.size(for: .paused), CGSize(width: 354, height: 40))
        XCTAssertEqual(TBDMeetingPillRules.size(for: .starting), CGSize(width: 150, height: 40))
        XCTAssertEqual(TBDMeetingPillRules.size(for: .saving), CGSize(width: 150, height: 40))
        XCTAssertEqual(TBDMeetingPillRules.size(for: .saved), CGSize(width: 120, height: 40))
    }

    func testTheSavedCheckStaysForV1HoldTime() {
        XCTAssertEqual(TBDMeetingPillRules.savedHoldSeconds, 1.7)
    }

    func testFirstPlacementIsFlushRightAndVerticallyCentred() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 800)
        XCTAssertEqual(TBDMeetingPillRules.defaultOrigin(in: visible, size: CGSize(width: 330, height: 40)), CGPoint(x: 1110, y: 420))
    }

    func testAFaceChangeKeepsTheRightEdgeAndTheCentre() {
        let frame = CGRect(x: 1110, y: 420, width: 330, height: 40)
        XCTAssertEqual(TBDMeetingPillRules.resized(frame: frame, to: CGSize(width: 150, height: 40)), CGRect(x: 1290, y: 420, width: 150, height: 40))
        XCTAssertEqual(TBDMeetingPillRules.resized(frame: CGRect(x: 1290, y: 420, width: 150, height: 40), to: CGSize(width: 330, height: 40)), frame)
    }

    func testARememberedPlaceOffScreenIsMovedBackAndOneOnScreenIsKept() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 800)
        let onScreen = CGRect(x: 200, y: 300, width: 330, height: 40)
        XCTAssertEqual(TBDMeetingPillRules.clamped(onScreen, into: visible), onScreen)
        XCTAssertEqual(TBDMeetingPillRules.clamped(CGRect(x: 2500, y: -400, width: 330, height: 40), into: visible),
                       CGRect(x: 1110, y: 40, width: 330, height: 40))
        XCTAssertEqual(TBDMeetingPillRules.clamped(CGRect(x: -500, y: 2000, width: 330, height: 40), into: visible),
                       CGRect(x: 0, y: 800, width: 330, height: 40))
    }

    func testTheExpandedPanelStartsBottomRight() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 800)
        XCTAssertEqual(TBDMeetingPillRules.panelOrigin(in: visible, size: CGSize(width: 420, height: 460)), CGPoint(x: 996, y: 136))
    }
}

final class StopConfirmationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    func testTheFirstPressOnlyArmsTheStop() {
        var stop = TBDStopConfirmation()
        XCTAssertFalse(stop.isArmed(now: t0))
        XCTAssertFalse(stop.press(now: t0))
        XCTAssertTrue(stop.isArmed(now: t0.addingTimeInterval(1)))
    }

    func testASecondPressWithinThreeSecondsStopsAndTheButtonResets() {
        var stop = TBDStopConfirmation()
        _ = stop.press(now: t0)
        XCTAssertTrue(stop.press(now: t0.addingTimeInterval(2.9)))
        XCTAssertFalse(stop.isArmed(now: t0.addingTimeInterval(3)))
        XCTAssertFalse(stop.press(now: t0.addingTimeInterval(3)), "after a stop the next press arms again")
    }

    func testAPressAfterThreeSecondsOnlyArmsAgain() {
        var stop = TBDStopConfirmation()
        _ = stop.press(now: t0)
        XCTAssertFalse(stop.isArmed(now: t0.addingTimeInterval(3)))
        XCTAssertFalse(stop.press(now: t0.addingTimeInterval(3)))
        XCTAssertTrue(stop.press(now: t0.addingTimeInterval(4)))
    }

    func testResetDisarms() {
        var stop = TBDStopConfirmation()
        _ = stop.press(now: t0)
        stop.reset()
        XCTAssertFalse(stop.isArmed(now: t0.addingTimeInterval(1)))
        XCTAssertFalse(stop.press(now: t0.addingTimeInterval(1)))
    }
}

/// C124: in "microphone + system audio" mode a failed system track falls back to the microphone, never silently.
final class SystemAudioFallbackNoticeTests: XCTestCase {
    func testTheExactWarningShowsWhenSystemAudioFailsInMicPlusSystemMode() {
        XCTAssertEqual(TBDMeetingWarnings.systemAudioMissing, "System audio is not recorded — only your microphone")
        XCTAssertEqual(TBDMeetingWarnings.systemAudioNotice(source: .microphoneAndSystem, systemStarted: false),
                       "System audio is not recorded — only your microphone")
    }

    func testNoWarningWhenBothSourcesStart() {
        XCTAssertNil(TBDMeetingWarnings.systemAudioNotice(source: .microphoneAndSystem, systemStarted: true))
    }

    func testNoFallbackWarningInTheOtherModes() {
        // System-only refuses to start (an error, not a warning); microphone-only never asked for system audio.
        XCTAssertNil(TBDMeetingWarnings.systemAudioNotice(source: .systemOnly, systemStarted: false))
        XCTAssertNil(TBDMeetingWarnings.systemAudioNotice(source: .microphoneOnly, systemStarted: false))
        XCTAssertNil(TBDMeetingWarnings.systemAudioNotice(source: .microphoneOnly, systemStarted: true))
    }

    func testAnIdleRecorderShowsNoNotice() {
        XCTAssertNil(TBDMeetingRecorder().captureNotice)
    }

    func testSystemOnlyStartFailureIsAPlainError() {
        XCTAssertTrue(TBDMeetingStartError.systemAudioUnavailable.localizedDescription.hasPrefix("System audio could not start."))
    }

    func testThePillGrowsATextRowWhileTheNoticeShows() {
        XCTAssertEqual(TBDMeetingPillRules.size(for: .recording, hasNotice: true), CGSize(width: 354, height: 62))
        XCTAssertEqual(TBDMeetingPillRules.size(for: .paused, hasNotice: true), CGSize(width: 354, height: 62))
        XCTAssertEqual(TBDMeetingPillRules.size(for: .recording, hasNotice: false), CGSize(width: 354, height: 40))
        XCTAssertEqual(TBDMeetingPillRules.size(for: .saved, hasNotice: true), CGSize(width: 120, height: 40))
    }

    func testTheNoticeIsKeptWithTheSavedMeeting() throws {
        var manifest = TBDMeetingManifest(id: "a", title: "M", startedAt: Date(), state: .done, durationMs: 0, transcriptionID: "t")
        XCTAssertNil(manifest.captureNotice)
        manifest.systemAudioMissing = true
        XCTAssertEqual(manifest.captureNotice, "System audio is not recorded — only your microphone")

        let database = try TBDListeningDatabase(inMemory: ())
        var missing = TBDTranscription(id: "t-missing", title: "M", sourceKind: .meeting, status: .completed)
        missing.captureNotice = manifest.captureNotice
        try database.save(missing)
        try database.save(TBDTranscription(id: "t-full", title: "M", sourceKind: .meeting, status: .completed))
        XCTAssertEqual(try database.transcription(id: "t-missing")?.captureNotice, "System audio is not recorded — only your microphone")
        XCTAssertNil(try database.transcription(id: "t-full")?.captureNotice)
    }
}
