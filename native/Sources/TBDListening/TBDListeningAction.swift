import Foundation

/// The Listening actions the host can start (menu-bar rows, deep links). One name per action, shared by
/// the host and Listening, so a menu row can never send a name Listening does not know (v1 parity:
/// MenuBarCoordinator rows Dictate, Start/stop meeting, Meeting controls, Transcribe file,
/// Transcribe URL, Recent dictations).
public enum TBDListeningAction: String, CaseIterable, Sendable {
    case dictation
    case meeting
    /// v1 opened the floating meeting panel; opt2 shows the meeting panel in the Meetings page.
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
        /// Bring Listening to the front on this page.
        case show(page: String)
    }

    public var effect: Effect {
        switch self {
        case .dictation: .toggleDictation
        case .meeting: .toggleMeeting
        case .meetingPanel: .show(page: "meetings")
        case .transcribeFile: .pickFiles
        case .transcribeURL: .promptForURL
        case .history: .show(page: "dictations")
        case .openLibrary: .show(page: "library")
        case .transform: .chooseTransform
        }
    }
}
