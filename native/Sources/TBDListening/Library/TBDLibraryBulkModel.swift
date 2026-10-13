import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// Selection mode, bulk delete, "remove audio only" and bulk export of the Library list (v1
/// `TranscriptionLibraryViewModel` bulk actions). The rules and the file work are in TBDSpeech
/// (`TBDLibrarySelection`, `TBDRetentionSweeper.deleteFromLibrary`, `TBDBulkExport`); this class holds the
/// screen state and shows every outcome, including failures.
@MainActor
final class TBDLibraryBulkModel: ObservableObject {
    struct AudioRequest { let targets: [TBDTranscription]; let skipped: Int }

    @Published var selection = TBDLibrarySelection()
    @Published var pendingDelete: [TBDTranscription]?
    @Published var pendingAudio: AudioRequest?
    /// What is running ("Deleting…"); the bar shows it and disables the actions.
    @Published private(set) var working: String?
    /// Last error or partial result, shown in red under the filters until dismissed.
    @Published var message: String?
    @Published var showExportOptions = false
    @Published var exportResult: TBDBulkExportResult?
    /// Remembered between exports (v1 `libraryBulkExport…`).
    @Published var exportFormat: TBDExportFormat { didSet { env.preferences.libraryExport.format = exportFormat } }
    @Published var exportOptions: TBDExportOptions { didSet { env.preferences.libraryExport.options = exportOptions } }

    private let env: TBDListeningEnvironment
    private var exportTask: Task<Void, Never>?

    init(env: TBDListeningEnvironment) {
        self.env = env
        exportFormat = env.preferences.libraryExport.format
        exportOptions = env.preferences.libraryExport.options
    }

    var isBusy: Bool { working != nil }

    // MARK: Favorites

    func toggleFavorite(_ item: TBDTranscription) {
        do {
            try env.database?.setFavorite(id: item.id, !item.isFavorite)
            env.changed()
        } catch {
            message = "Could not update the favorite: \(error.localizedDescription)"
        }
    }

    // MARK: Delete and remove audio

    func requestDelete(_ targets: [TBDTranscription]) {
        guard !isBusy, !targets.isEmpty else { return }
        pendingDelete = targets
    }

    func requestRemoveAudio(_ targets: [TBDTranscription], skipped: Int = 0) {
        guard !isBusy, !targets.isEmpty else { return }
        pendingAudio = AudioRequest(targets: targets, skipped: skipped)
    }

    /// Runs a delete the person confirmed. `targets` is passed by value: the alert clears `pendingDelete` as it closes.
    func confirmDelete(_ targets: [TBDTranscription]) {
        guard let database = env.database, !isBusy else { return }
        pendingDelete = nil
        message = nil
        working = "Deleting…"
        let ids = targets.map(\.id)
        let sweeper = TBDRetentionSweeper(database: database)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { sweeper.deleteFromLibrary(ids: ids) }.value
            finish(outcome, message: outcome.deleteMessage())
            if let selected = env.selectedTranscriptionID, outcome.succeeded.contains(selected) { env.selectedTranscriptionID = nil }
        }
    }

    func confirmRemoveAudio(_ request: AudioRequest) {
        guard let database = env.database, !isBusy else { return }
        pendingAudio = nil
        message = nil
        working = "Removing audio…"
        let ids = request.targets.map(\.id)
        let sweeper = TBDRetentionSweeper(database: database)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { sweeper.removeAudio(ids: ids) }.value
            finish(outcome, message: outcome.audioMessage(skipped: request.skipped))
        }
    }

    private func finish(_ outcome: TBDLibraryOutcome, message text: String?) {
        working = nil
        message = text
        if outcome.failed.isEmpty { selection.exit() } else { selection.keepFailed(outcome.failedIDs, visible: Set(outcome.failedIDs)) }
        env.changed()
    }

    // MARK: Export

    /// Asks for a folder, then writes one file per ticked row (v1 "Choose Folder…").
    func exportSelected(_ items: [TBDTranscription]) {
        guard let database = env.database, !isBusy, !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.prompt = "Export"
        panel.message = "Choose a folder for the selected transcript files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        showExportOptions = false
        message = nil
        exportResult = nil
        working = "Exporting…"
        let format = exportFormat, options = exportOptions
        exportTask = Task {
            defer { working = nil; exportTask = nil }
            do {
                let result = try await TBDBulkExport.run(items, format: format, options: options, directory: directory) { item in
                    (try database.projectedTranscription(id: item.id)?.item ?? item, try database.summaries(for: item.id))
                }
                if result.exportedCount == 0 {
                    message = "No files were exported. " + (result.failureLines.first ?? "")
                } else {
                    if !result.failures.isEmpty { message = result.failureLines.joined(separator: " ") }
                    exportResult = result
                }
            } catch is CancellationError {
            } catch {
                message = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Stops a running export (the page is closing). Files already written by this run are removed.
    func cancelExport() {
        exportTask?.cancel()
    }
}
