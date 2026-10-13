import AppKit
import SwiftUI
import TBDSpeech

/// Shared services for the Listening UI and controllers. Created once by the runtime.
@MainActor
final class TBDListeningEnvironment: ObservableObject {
    let preferences = TBDListeningPreferences()
    let speech = TBDSpeechService.shared
    let microphone = TBDSharedMicrophone.shared
    let overlay = TBDDictationOverlay()
    let database: TBDListeningDatabase?
    let databaseError: String?
    /// Bumped whenever library data changes so views reload.
    @Published var revision = 0
    /// Set to open a library item (for example after a file finishes).
    @Published var selectedTranscriptionID: String?
    @Published var selectedTab: TBDListeningTab = .library
    /// Dictation search text (shared so library search can hand a query over).
    @Published var dictationQuery = ""

    init() {
        do {
            database = try TBDListeningDatabase()
            databaseError = nil
            try? database?.markInterruptedTranscriptions()
            // Built-in prompts and the one-time import of the old prompt settings.
            try? database?.preparePromptLibrary(preferences: preferences)
        } catch {
            database = nil
            databaseError = error.localizedDescription
        }
        microphone.setPreferredDevice(uid: preferences.microphoneUID)
    }

    var transcriber: TBDTranscriber? { database.map { TBDTranscriber(speech: speech, database: $0) } }

    func changed() { revision &+= 1 }

    /// Moves a capture into a private folder and returns the new location.
    func keep(_ url: URL, in folder: URL, name: String) throws -> URL {
        let destination = try TBDListeningPaths.ensure(folder).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

enum TBDListeningTab: String, CaseIterable, Identifiable {
    case library, dictations, meetings, prompts, transforms
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: "Library"
        case .dictations: "Dictations"
        case .meetings: "Meetings"
        case .prompts: "Prompts"
        case .transforms: "Transforms"
        }
    }
}
