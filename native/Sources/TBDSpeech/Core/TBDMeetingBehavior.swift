import CoreGraphics
import Foundation

// Pure logic for the v1 live-meeting behaviour (PARITY WP4, meeting-live): audio source modes, mic mute,
// activity auto-stop, what happens when a meeting ends, and the floating pill. No AppKit here, so every
// rule has an exact-value test. The recorder, controller and panels only wire these to the screen.

// MARK: - Audio source mode (v1 `MeetingAudioSourceMode`)

/// Which audio a meeting records. Raw values are the v1 values.
public enum TBDMeetingAudioSource: String, CaseIterable, Sendable, Equatable {
    case microphoneAndSystem = "microphone_and_system"
    case microphoneOnly = "microphone_only"
    case systemOnly = "system_only"

    public var capturesMicrophone: Bool { self != .systemOnly }
    public var capturesSystemAudio: Bool { self != .microphoneOnly }

    public var title: String {
        switch self {
        case .microphoneAndSystem: "Microphone + system audio"
        case .microphoneOnly: "Microphone only"
        case .systemOnly: "System audio only"
        }
    }

    public var detail: String {
        switch self {
        case .microphoneAndSystem: "Capture your voice and call audio. Best when using headphones."
        case .microphoneOnly: "Capture only your microphone. Useful when speaker audio bleeds into the mic."
        case .systemOnly: "Capture only computer audio. Your microphone stays available for dictation."
        }
    }

    public static let `default`: TBDMeetingAudioSource = .microphoneAndSystem
}

// MARK: - Settings (v1 keys and defaults)

extension TBDListeningPreferences {
    enum MeetingLiveKey {
        static let audioSource = "tbd.listening.meetingAudioSourceMode"
        static let startMuted = "tbd.listening.startMeetingsMuted"
        static let showPill = "tbd.listening.showMeetingRecordingPill"
        static let openAppAfterEnd = "tbd.listening.openAppAfterMeetingEnd"
        static let autoStop = "tbd.listening.meetingAutoStopEnabled"
    }

    private func flag(_ key: String, default value: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? value }

    /// Which sources a meeting records (v1 `meetingAudioSourceMode`; an unknown stored value reads as the default).
    public var meetingAudioSourceMode: TBDMeetingAudioSource {
        get { defaults.string(forKey: MeetingLiveKey.audioSource).flatMap(TBDMeetingAudioSource.init(rawValue:)) ?? .default }
        nonmutating set { defaults.set(newValue.rawValue, forKey: MeetingLiveKey.audioSource) }
    }
    /// Begin each meeting with the microphone muted (v1 `startMeetingsMuted`, default off).
    public var startMeetingsMuted: Bool {
        get { flag(MeetingLiveKey.startMuted, default: false) }
        nonmutating set { defaults.set(newValue, forKey: MeetingLiveKey.startMuted) }
    }
    /// The floating pill while a meeting records (v1 `showMeetingRecordingPill`, default on).
    public var showMeetingRecordingPill: Bool {
        get { flag(MeetingLiveKey.showPill, default: true) }
        nonmutating set { defaults.set(newValue, forKey: MeetingLiveKey.showPill) }
    }
    /// Bring the app forward on the finished meeting (v1 `openAppAfterMeetingEnd`, default on).
    public var openAppAfterMeetingEnd: Bool {
        get { flag(MeetingLiveKey.openAppAfterEnd, default: true) }
        nonmutating set { defaults.set(newValue, forKey: MeetingLiveKey.openAppAfterEnd) }
    }
    /// Offer to stop when the meeting looks finished (v1 `meetingAutoStopEnabled`, default off).
    public var meetingAutoStopEnabled: Bool {
        get { flag(MeetingLiveKey.autoStop, default: false) }
        nonmutating set { defaults.set(newValue, forKey: MeetingLiveKey.autoStop) }
    }
}

// MARK: - System audio fallback (C124)

public enum TBDMeetingWarnings {
    /// Shown on the pill, the panel and the live panel, and kept with the meeting, when the system track is missing.
    public static let systemAudioMissing = "System audio is not recorded — only your microphone"

    /// "Microphone + system audio" falls back to the microphone when system audio cannot start, but never silently.
    /// Other modes have no fallback: "System audio only" refuses to start, "Microphone only" never wanted it.
    public static func systemAudioNotice(source: TBDMeetingAudioSource, systemStarted: Bool) -> String? {
        source == .microphoneAndSystem && !systemStarted ? systemAudioMissing : nil
    }
}

// MARK: - Mic mute (v1 `MeetingRecordingService.setMicrophoneMuted`)

public enum TBDMicMute {
    /// While muted the track keeps its length and timing but carries silence, so the microphone and system
    /// tracks stay aligned; the meter shows nothing. Pause is separate: it stops both tracks.
    public static func apply(_ samples: [Float], muted: Bool) -> (samples: [Float], level: Float) {
        guard muted else { return (samples, TBDAudioLevel.normalized(samples)) }
        return ([Float](repeating: 0, count: samples.count), 0)
    }

    /// The mute control works only when the microphone is part of the recording (v1 `canMuteMicrophone`).
    public static func canMute(source: TBDMeetingAudioSource, recording: Bool) -> Bool { recording && source.capturesMicrophone }

    /// A meeting that starts muted needs a microphone to mute (v1 `clearStartMicrophoneMuteIfNeeded`).
    public static func startsMuted(setting: Bool, source: TBDMeetingAudioSource) -> Bool { setting && source.capturesMicrophone }
}

// MARK: - Auto-stop (v1 `MeetingAutoStopPolicy` and `MeetingAutoStopCoordinator`)

/// Native conferencing apps whose quitting suggests the meeting ended (v1 `MeetingAppRegistry.nativeAppBundleIDs`).
public enum TBDMeetingApps {
    public static let nativeBundleIDs: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark",
        "com.apple.FaceTime",
    ]
    public static func isRecognized(_ bundleID: String) -> Bool { nativeBundleIDs.contains(bundleID) }
}

/// Decides whether the current observation justifies proposing a stop. No clocks, no UI.
public enum TBDMeetingAutoStopPolicy {
    public struct Context: Sendable, Equatable {
        /// Recognised meeting apps seen running at or after the recording started.
        public var observedApps: Set<String>
        public var startedAt: Date
        public init(observedApps: Set<String>, startedAt: Date) { self.observedApps = observedApps; self.startedAt = startedAt }
    }

    public struct Observation: Sendable, Equatable {
        public var now: Date
        public var isRecording: Bool
        public var isPaused: Bool
        public var runningApps: Set<String>
        /// Seconds both channels have stayed below the silence level.
        public var continuousSilenceSeconds: TimeInterval
        public init(now: Date, isRecording: Bool, isPaused: Bool, runningApps: Set<String>, continuousSilenceSeconds: TimeInterval) {
            self.now = now; self.isRecording = isRecording; self.isPaused = isPaused
            self.runningApps = runningApps; self.continuousSilenceSeconds = continuousSilenceSeconds
        }
    }

    public struct Config: Sendable, Equatable {
        public var appQuitEnabled: Bool
        public var silenceEnabled: Bool
        /// The meeting app must stay closed this long before the countdown shows.
        public var appQuitGraceSeconds: TimeInterval
        /// Both channels quiet for this long proposes a stop.
        public var silenceGraceSeconds: TimeInterval
        public init(appQuitEnabled: Bool = true, silenceEnabled: Bool = true, appQuitGraceSeconds: TimeInterval = 15,
                    silenceGraceSeconds: TimeInterval = 240) {
            self.appQuitEnabled = appQuitEnabled; self.silenceEnabled = silenceEnabled
            self.appQuitGraceSeconds = appQuitGraceSeconds; self.silenceGraceSeconds = silenceGraceSeconds
        }
        public static let `default` = Config()
    }

    public enum StopReason: Sendable, Hashable {
        case meetingAppClosed(bundleID: String)
        case prolongedSilence

        /// Title of the countdown toast (v1 wording).
        public var countdownTitle: String {
            switch self {
            case .meetingAppClosed: "Meeting app closed"
            case .prolongedSilence: "This meeting looks finished"
            }
        }
    }

    public enum Decision: Sendable, Equatable {
        case keepRecording
        case proposeStop(StopReason)
    }

    /// A paused or idle recording is never stopped. An app that closed wins over silence; when several closed,
    /// the first by bundle ID is named.
    public static func evaluate(context: Context, observation: Observation, config: Config) -> Decision {
        guard observation.isRecording, !observation.isPaused else { return .keepRecording }
        if config.appQuitEnabled, let closed = context.observedApps.subtracting(observation.runningApps).sorted().first {
            return .proposeStop(.meetingAppClosed(bundleID: closed))
        }
        if config.silenceEnabled, observation.continuousSilenceSeconds >= config.silenceGraceSeconds {
            return .proposeStop(.prolongedSilence)
        }
        return .keepRecording
    }
}

/// The auto-stop state machine: one observation per second in, what to show out. It keeps the silence clock, the
/// grace clocks, the "keep recording" vetoes and the countdown state of v1 `MeetingAutoStopCoordinator`.
public struct TBDMeetingAutoStopMonitor: Sendable {
    public typealias StopReason = TBDMeetingAutoStopPolicy.StopReason

    /// Seconds the person has to keep the recording once the countdown shows (v1 toast duration).
    public static let countdownSeconds: TimeInterval = 15
    /// Both channels at or below this are silent. v1 measured RMS 0.02; opt2 meter levels are RMS x 5.
    public static let silenceLevel: Float = 0.1

    public struct Signals: Sendable, Equatable {
        public var now: Date
        public var runningApps: Set<String>
        public var micLevel: Float
        public var systemLevel: Float
        public var isPaused: Bool
        public init(now: Date, runningApps: Set<String>, micLevel: Float, systemLevel: Float, isPaused: Bool) {
            self.now = now; self.runningApps = runningApps; self.micLevel = micLevel
            self.systemLevel = systemLevel; self.isPaused = isPaused
        }
    }

    public enum Action: Sendable, Equatable {
        case none
        case closeCountdown
        case showCountdown(StopReason)
    }

    public enum CountdownOutcome: Sendable { case completed, userDismissed, programmaticClose }

    public let config: TBDMeetingAutoStopPolicy.Config
    public private(set) var context: TBDMeetingAutoStopPolicy.Context?
    public private(set) var countdownReason: StopReason?
    public private(set) var vetoed: Set<StopReason> = []
    private var silenceStartedAt: Date?
    private var firstSeen: [StopReason: Date] = [:]

    public init(config: TBDMeetingAutoStopPolicy.Config = .default) { self.config = config }

    public var isActive: Bool { context != nil }

    /// A recording started (or auto-stop was switched on during one): note the meeting apps already running.
    public mutating func begin(runningApps: Set<String>, now: Date) {
        context = .init(observedApps: runningApps.filter(TBDMeetingApps.isRecognized), startedAt: now)
        silenceStartedAt = nil; firstSeen = [:]; vetoed = []; countdownReason = nil
    }

    /// The recording ended, or auto-stop was switched off. Forgets vetoes too.
    public mutating func end() {
        context = nil; silenceStartedAt = nil; firstSeen = [:]; vetoed = []; countdownReason = nil
    }

    /// A recognised app quit between two polls: it still counts as closed.
    public mutating func appTerminated(bundleID: String) {
        guard TBDMeetingApps.isRecognized(bundleID) else { return }
        context?.observedApps.insert(bundleID)
    }

    /// One poll. Returns what the toast should do.
    public mutating func observe(_ signals: Signals) -> Action {
        guard let decision = decide(signals) else { return .none }
        return handle(decision, now: signals.now)
    }

    /// The countdown ended. `true` means stop the recording now: only a countdown that ran out while the same
    /// reason still holds stops it. "Keep recording" vetoes that reason for the rest of the recording.
    public mutating func countdownEnded(_ outcome: CountdownOutcome, reason: StopReason, signals: Signals) -> Bool {
        guard countdownReason == reason else { return false }
        countdownReason = nil
        switch outcome {
        case .completed:
            if case .proposeStop(let current)? = decide(signals), current == reason { return true }
            firstSeen = [:]
            return false
        case .userDismissed:
            vetoed.insert(reason)
            suppress(reason)
            return false
        case .programmaticClose:
            return false
        }
    }

    private mutating func decide(_ signals: Signals) -> TBDMeetingAutoStopPolicy.Decision? {
        guard var current = context else { return nil }
        let running = signals.runningApps.filter(TBDMeetingApps.isRecognized)
        current.observedApps.formUnion(running)
        context = current
        let silence = silenceSeconds(signals)
        return TBDMeetingAutoStopPolicy.evaluate(
            context: current,
            observation: .init(now: signals.now, isRecording: true, isPaused: signals.isPaused, runningApps: running,
                               continuousSilenceSeconds: silence),
            config: config)
    }

    /// Seconds of continuous quiet. The first quiet poll starts the clock (0); a pause or any sound resets it.
    private mutating func silenceSeconds(_ signals: Signals) -> TimeInterval {
        guard !signals.isPaused, signals.micLevel <= Self.silenceLevel, signals.systemLevel <= Self.silenceLevel else {
            silenceStartedAt = nil
            return 0
        }
        guard let started = silenceStartedAt else { silenceStartedAt = signals.now; return 0 }
        return max(0, signals.now.timeIntervalSince(started))
    }

    private mutating func handle(_ decision: TBDMeetingAutoStopPolicy.Decision, now: Date) -> Action {
        switch decision {
        case .keepRecording:
            firstSeen = [:]
            guard countdownReason != nil else { return .none }
            countdownReason = nil
            return .closeCountdown
        case .proposeStop(let reason):
            if vetoed.contains(reason) { suppress(reason); return .none }
            guard graceElapsed(reason, now: now), countdownReason != reason else { return .none }
            countdownReason = reason
            return .showCountdown(reason)
        }
    }

    private mutating func graceElapsed(_ reason: StopReason, now: Date) -> Bool {
        let grace: TimeInterval
        switch reason {
        case .meetingAppClosed: grace = config.appQuitGraceSeconds
        case .prolongedSilence: grace = 0
        }
        guard grace > 0 else { return true }
        guard let first = firstSeen[reason] else { firstSeen[reason] = now; return false }
        return now.timeIntervalSince(first) >= grace
    }

    private mutating func suppress(_ reason: StopReason) {
        firstSeen.removeValue(forKey: reason)
        if case .meetingAppClosed(let bundleID) = reason { context?.observedApps.remove(bundleID) }
    }
}

// MARK: - Meeting end (v1 `handleMeetingTranscriptReady`)

public enum TBDMeetingEndPresentation {
    public struct Result: Sendable, Equatable {
        /// Bring the app forward on the finished meeting.
        public var openApp: Bool
        /// Post the "transcript ready" notice instead.
        public var notify: Bool
    }

    /// `canPresent` is false when a newer recording is running or queued: the finished meeting then neither
    /// takes focus nor notifies. The notice is the quiet path, used only when the app does not open itself.
    public static func decide(openAppAfterMeetingEnd: Bool, notifyOnMeetingEnd: Bool, canPresent: Bool) -> Result {
        guard canPresent else { return Result(openApp: false, notify: false) }
        return Result(openApp: openAppAfterMeetingEnd, notify: !openAppAfterMeetingEnd && notifyOnMeetingEnd)
    }
}

// MARK: - Floating pill and panel (v1 `MeetingRecordingPillController`, `MeetingRecordingPanelController`)

/// What the floating pill shows. v1 also had a flower animation between recording and saving: decoration, not ported.
public enum TBDMeetingPillFace: Sendable, Equatable {
    case hidden, starting, recording, paused, saving, saved

    /// Pause and resume apply to a running recording only.
    public var canPause: Bool { self == .recording || self == .paused }
    public var isLive: Bool { self == .starting || self == .recording || self == .paused }
}

public enum TBDMeetingPillRules {
    /// Seconds the "saved" check stays after the audio is stored (v1 `savedCheckmarkHold`).
    public static let savedHoldSeconds: TimeInterval = 1.7

    /// The pill shows for every face except hidden, and only while the setting is on.
    public static func isVisible(_ face: TBDMeetingPillFace, showSetting: Bool) -> Bool { showSetting && face != .hidden }

    /// Width and height per face; the recording face carries the controls.
    public static func size(for face: TBDMeetingPillFace, hasNotice: Bool = false) -> CGSize {
        let base = baseSize(for: face)
        return hasNotice && face.isLive ? CGSize(width: max(base.width, 354), height: base.height + 22) : base
    }

    private static func baseSize(for face: TBDMeetingPillFace) -> CGSize {
        switch face {
        case .hidden: .zero
        case .starting, .saving: CGSize(width: 150, height: 40)
        case .saved: CGSize(width: 120, height: 40)
        case .recording, .paused: CGSize(width: 354, height: 40)   // 4 icon controls with 36x36 hit areas (C145)
        }
    }

    /// First placement: flush against the right edge, centred vertically (v1).
    public static func defaultOrigin(in visibleFrame: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: visibleFrame.maxX - size.width, y: visibleFrame.midY - size.height / 2)
    }

    /// A pill moved by hand keeps its right edge and vertical centre when the face changes its width.
    public static func resized(frame: CGRect, to size: CGSize) -> CGRect {
        CGRect(x: frame.maxX - size.width, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// A remembered frame is moved back onto the screen when the screen layout changed.
    public static func clamped(_ frame: CGRect, into visibleFrame: CGRect) -> CGRect {
        var result = frame
        result.origin.x = min(max(result.minX, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - result.width))
        result.origin.y = min(max(result.minY, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - result.height))
        return result
    }

    /// First placement of the expanded panel: bottom right, 24 from the edge and 96 above the bottom (v1).
    public static func panelOrigin(in visibleFrame: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: visibleFrame.maxX - size.width - 24, y: visibleFrame.minY + 96)
    }
}

/// The two-step stop of the live controls (v1 `StopRecordingButton`): the first press arms it, a second press
/// within three seconds stops. After that the button falls back.
public struct TBDStopConfirmation: Sendable, Equatable {
    public static let window: TimeInterval = 3
    private var armedAt: Date?

    public init() {}

    public func isArmed(now: Date) -> Bool { armedAt.map { now.timeIntervalSince($0) < Self.window } ?? false }

    /// Returns true when this press confirms the stop.
    public mutating func press(now: Date) -> Bool {
        if isArmed(now: now) { armedAt = nil; return true }
        armedAt = now
        return false
    }

    public mutating func reset() { armedAt = nil }
}
