import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

// Placeholders replaced by later milestones.
@MainActor final class TBDMeetingController {
    var onMessage: ((String) -> Void)?
    init(env: TBDListeningEnvironment) {}
    var statusText: String { "Idle" }
    var isRecording: Bool { false }
    func start() {}
    func shutdown() {}
    func toggle() { onMessage?("Meetings are not available yet") }
}

@MainActor final class TBDFileQueue {
    var onMessage: ((String) -> Void)?
    init(env: TBDListeningEnvironment) {}
    func pickFiles() { onMessage?("File transcription is not available yet") }
    func promptForURL() { onMessage?("Link transcription is not available yet") }
    func cancelAll() {}
}

@MainActor final class TBDTransformController {
    var onMessage: ((String) -> Void)?
    init(env: TBDListeningEnvironment) {}
    func run() {}
    func chooseAndRun() { onMessage?("Transforms are not available yet") }
}

struct TBDListeningView: View {
    let context: TBDListeningContext
    var body: some View { Text("Listening").foregroundStyle(TBDTokens.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

struct TBDListeningSettingsView: View {
    let section: String
    let context: TBDListeningContext
    var body: some View { EmptyView() }
}
