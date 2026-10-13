import Foundation

/// The Listening actions the host can start (menu-bar rows, deep links). One name per action, shared by
/// the host and Listening, so a menu row can never send a name Listening does not know (v1 parity:
/// MenuBarCoordinator rows Dictate, Start/stop meeting, Meeting controls, Transcribe file,
/// Transcribe URL, Recent dictations).
public enum TBDListeningAction: String, CaseIterable, Sendable {
    case dictation
    case meeting
    /// Meeting controls: the floating meeting panel while a meeting records (v1), else the Meetings page.
    case meetingPanel
    case transcribeFile
    case transcribeURL
    /// Recent dictations: the Dictations page.
    case history
    case openLibrary
    case transform

    /// What the action does, without side effects (tested).
    public enum Effect: Equatable, Sendable {
        case toggleDictation
        case toggleMeeting
        case pickFiles
        case promptForURL
        case chooseTransform
        /// The floating meeting panel while recording, else the Meetings page (`meetingControlsTarget`).
        case meetingControls
        /// Bring Listening to the front on this page.
        case show(page: String)
    }

    public enum MeetingControlsTarget: Equatable, Sendable { case floatingPanel, meetingsPage }

    /// Where "Meeting controls" goes: v1's floating panel while a meeting records; nothing to control otherwise.
    public static func meetingControlsTarget(isRecording: Bool) -> MeetingControlsTarget {
        isRecording ? .floatingPanel : .meetingsPage
    }

    public var effect: Effect {
        switch self {
        case .dictation: .toggleDictation
        case .meeting: .toggleMeeting
        case .meetingPanel: .meetingControls
        case .transcribeFile: .pickFiles
        case .transcribeURL: .promptForURL
        case .history: .show(page: "dictations")
        case .openLibrary: .show(page: "library")
        case .transform: .chooseTransform
        }
    }
}
