import AppKit
import TBDSpeech
import UniformTypeIdentifiers

/// Batch queue for file and link transcription. Items run one after another on the file lane.
@MainActor
final class TBDFileQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        enum Source: Equatable { case file(URL), link(URL) }
        enum State: Equatable { case queued, running(String, Double), done(String), failed(String), cancelled }
        let id = UUID()
        let source: Source
        var title: String
        var state: State = .queued
        var isFinished: Bool {
            switch state { case .done, .failed, .cancelled: true; default: false }
        }
    }

    @Published private(set) var items: [Item] = []
    var onMessage: ((String) -> Void)?
    private let env: TBDListeningEnvironment
    private var worker: Task<Void, Never>?
    private var current: (id: UUID, task: Task<Void, Never>)?

    init(env: TBDListeningEnvironment) { self.env = env }

    var isBusy: Bool { items.contains { !$0.isFinished } }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent, .folder]
        panel.message = "Choose one or more audio or video files, or a folder, to transcribe"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        enqueue(files: panel.urls)
    }

    func promptForURL() {
        let alert = NSAlert()
        alert.messageText = "Transcribe a link"
        alert.informativeText = "Paste a video or Apple Podcasts link, or type a podcast name and episode (for example “hard fork 120”). Podcasts are found with the Apple Podcasts directory; other videos use the yt-dlp already installed on this Mac."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://… or podcast name and episode"
        if let clip = NSPasteboard.general.string(forType: .string), TBDLinkDownloader.validate(clip) != nil { field.stringValue = clip }
        alert.accessoryView = field
        alert.addButton(withTitle: "Transcribe")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        enqueue(link: field.stringValue)
    }

    /// Queues files; folders are searched recursively for audio and video (up to 200 files, natural name order).
    func enqueue(files: [URL]) {
        let scoped = files.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let result = TBDAudioFileEnumerator.expand(files)
        if result.files.isEmpty {
            let formats = TBDAudioDecoder.supportedExtensions.map { $0.uppercased() }.sorted().joined(separator: ", ")
            onMessage?("Unsupported file type. Supported formats: \(formats).")
            return
        }
        if result.dropped > 0 {
            onMessage?("Queued the first \(result.files.count) files; \(result.stoppedEarly ? "at least " : "")\(result.dropped) more were skipped (\(TBDAudioFileEnumerator.defaultMaxFiles)-file limit).")
        } else if result.skippedUnsupported > 0 {
            onMessage?("Some files were skipped: not audio or video.")
        }
        items += result.files.map { Item(source: .file($0), title: $0.lastPathComponent) }
        pump()
    }

    func enqueue(link text: String) {
        guard let url = TBDLinkDownloader.linkOrPodcastSearch(text) else { onMessage?("Enter a link or a podcast name."); return }
        let title = url.scheme == TBDLinkDownloader.podcastSearchScheme ? "Podcast: \(text.trimmingCharacters(in: .whitespacesAndNewlines))" : url.host ?? url.absoluteString
        items.append(Item(source: .link(url), title: title))
        pump()
    }

    func cancel(_ id: UUID) {
        if current?.id == id { current?.task.cancel(); return }
        update(id) { $0.state = .cancelled }
    }

    func cancelAll() {
        for index in items.indices where items[index].state == .queued { items[index].state = .cancelled }
        current?.task.cancel()
    }

    func clearFinished() { items.removeAll(where: \.isFinished) }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func pump() {
        guard worker == nil else { return }
        worker = Task {
            while let next = items.first(where: { $0.state == .queued }) {
                let task = Task { await self.process(next) }
                current = (next.id, task)
                await task.value
                current = nil
            }
            worker = nil
        }
    }

    private func process(_ item: Item) async {
        guard let transcriber = env.transcriber else {
            update(item.id) { $0.state = .failed(env.databaseError ?? "Library unavailable") }
            return
        }
        let id = item.id
        let progress: TBDTranscriber.Progress = { [weak self] stage, fraction in
            Task { @MainActor in self?.update(id) { item in if !item.isFinished { item.state = .running(stage, fraction) } } }
        }
        update(id) { $0.state = .running("Starting", 0) }
        do {
            let result: TBDTranscription
            switch item.source {
            case .file(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                result = try await transcriber.transcribe(file: url, progress: progress)
            case .link(let url):
                update(id) { $0.state = .running("Downloading", 0) }
                let download = try await TBDLinkDownloader().download(url, into: TBDListeningPaths.downloads)
                defer { try? FileManager.default.removeItem(at: download.file) }
                update(id) { $0.title = download.title }
                result = try await transcriber.transcribe(file: download.file, kind: .url, title: download.title,
                                                          sourceURL: download.sourceURL ?? url.absoluteString, keepAudio: env.preferences.keepsAudio(.fileTranscriptions), progress: progress)
            }
            update(id) { $0.state = .done(result.id) }
            env.selectedTranscriptionID = result.id
        } catch is CancellationError {
            update(id) { $0.state = .cancelled }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
        env.changed()
    }
}
