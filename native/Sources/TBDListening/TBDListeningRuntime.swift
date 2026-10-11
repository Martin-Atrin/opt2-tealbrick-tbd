import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// Native embedding facade for Listening. Retain one instance for the host lifetime.
/// Placeholder until the speech-to-text rewrite lands; the public shape is the contract with Companion.
@MainActor
public final class TBDListeningRuntime: ObservableObject {
    public static let shared = TBDListeningRuntime()
    public var activate: (() -> Void)?
    @Published public private(set) var voiceNoteRecording = false
    @Published public private(set) var captureBusy = false
    @Published public private(set) var captureMessage = ""
    @Published public private(set) var lastRawTranscript = ""
    private var started = false
    public init() {}

    public func start() { started = true }
    public func content() -> AnyView {
        AnyView(Text("Listening is being rebuilt.").foregroundStyle(TBDTokens.muted).frame(maxWidth: .infinity, maxHeight: .infinity))
    }
    public func settingsContent(section: String) -> AnyView { AnyView(EmptyView()) }
    public func shouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
    public var meetingStatus: String { "Idle" }
    public func menuAction(_ action: String) { captureMessage = "Listening is not available yet" }
    public func toggleVoiceNote() async { captureMessage = "Listening is not available yet" }
    public func chatAudio(_ operation: String) async throws -> Any {
        throw NSError(domain: "TBD.Listening", code: 1, userInfo: [NSLocalizedDescriptionKey: "Listening is not available yet"])
    }
    public func terminate() { started = false }
}
