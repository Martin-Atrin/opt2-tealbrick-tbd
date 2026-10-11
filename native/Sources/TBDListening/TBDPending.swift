import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

// Placeholders replaced by later milestones.
@MainActor final class TBDMeetingController: ObservableObject {
    var onMessage: ((String) -> Void)?
    init(env: TBDListeningEnvironment) {}
    var statusText: String { "Idle" }
    var isRecording: Bool { false }
    func start() {}
    func shutdown() {}
    func toggle() { onMessage?("Meetings are not available yet") }
    func retranscribe(_ id: String) {}
}

struct TBDMeetingButton: View {
    @ObservedObject var meetings: TBDMeetingController
    var body: some View { Button("Record meeting") { meetings.toggle() }.buttonStyle(TBDButtonStyle(.primary)) }
}

struct TBDMeetingsView: View {
    let context: TBDListeningContext
    var body: some View { TBDLibraryView(context: context, kind: .meeting) }
}

@MainActor final class TBDTransformController {
    var onMessage: ((String) -> Void)?
    init(env: TBDListeningEnvironment) {}
    func run() {}
    func chooseAndRun() { onMessage?("Transforms are not available yet") }
}

struct TBDListeningSettingsView: View {
    let section: String
    let context: TBDListeningContext
    var body: some View { EmptyView() }
}
