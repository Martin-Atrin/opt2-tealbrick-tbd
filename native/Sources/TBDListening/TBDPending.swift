import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

// Placeholders replaced by later milestones.
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
