import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// Format picker and option switches shared by the single export (transcript header) and the bulk export
/// (Library selection bar). Same wording and rules as v1: the options show only for Text and Markdown, and
/// an option the transcript cannot honour reads unchecked with the reason.
struct TBDExportPanel: View {
    let title: String
    var subtitle: String?
    @Binding var format: TBDExportFormat
    @Binding var options: TBDExportOptions
    /// Why timestamps / speaker labels are not available for this transcript; nil when they are (or for a batch).
    var timestampsReason: String?
    var speakerLabelsReason: String?
    /// Batch wording: "… when available".
    var forBatch = false
    let actionTitle: String
    let actionIcon: String
    var actionDisabled = false
    /// Result line under the button: text, whether it is an error, and a file to show in Finder.
    var status: Status?
    let onAction: () -> Void
    let onClose: () -> Void

    struct Status {
        let text: String
        var isError = false
        var reveal: [URL] = []
    }

    static func icon(_ format: TBDExportFormat) -> String {
        switch format {
        case .txt: "doc.text"
        case .md: "text.document"
        case .srt: "captions.bubble"
        case .vtt: "captions.bubble.fill"
        case .dapt: "chevron.left.forwardslash.chevron.right"
        case .docx: "doc.richtext"
        case .pdf: "doc.viewfinder"
        case .json: "curlybraces"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            HStack {
                Label(title, systemImage: "arrow.down.doc").font(TBDTokens.Typography.control)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(TBDButtonStyle(.icon)).accessibilityLabel("Close export options")
            }
            if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(TBDTokens.muted) }

            VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                TBDLabel("Format")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(TBDExportFormat.pickerOrder, id: \.self) { candidate in
                        Button { format = candidate } label: {
                            HStack(spacing: 6) {
                                Image(systemName: Self.icon(candidate)).frame(width: 16)
                                Text(candidate.shortName).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(TBDTokens.ink)
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(format == candidate ? TBDTokens.selected : TBDTokens.paper)
                            .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
                                .strokeBorder(format == candidate ? TBDTokens.accent : TBDTokens.border,
                                              lineWidth: format == candidate ? TBDTokens.Stroke.bar : TBDTokens.Stroke.hairline))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(candidate.title)
                        .accessibilityValue(format == candidate ? "Selected" : "")
                    }
                }
            }

            if format.supportsOptions {
                VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                    TBDLabel("Options")
                    toggle(forBatch ? "Include timestamps when available" : "Include timestamps", $options.includeTimestamps, reason: timestampsReason)
                    toggle(forBatch ? "Include speaker labels when available" : "Include speaker labels", $options.includeSpeakerLabels, reason: speakerLabelsReason)
                    Toggle("Include metadata", isOn: $options.includeMetadata)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button(action: onAction) { Label(actionTitle, systemImage: actionIcon) }
                    .buttonStyle(TBDButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(actionDisabled)
            }
            if let status {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.text).font(.system(size: 12)).foregroundStyle(status.isError ? TBDTokens.alert : TBDTokens.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !status.reveal.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(status.reveal) }
                            .buttonStyle(TBDButtonStyle(.quiet))
                    }
                }
            }
        }
        .padding(TBDTokens.Space.md)
        .frame(width: 380)
    }

    /// Shows the effective state: an unavailable option reads unchecked and disabled, with the reason below.
    private func toggle(_ label: String, _ value: Binding<Bool>, reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(label, isOn: Binding(get: { reason == nil && value.wrappedValue }, set: { value.wrappedValue = $0 }))
                .disabled(reason != nil)
            if let reason { Text(reason).font(.system(size: 11)).foregroundStyle(TBDTokens.muted) }
        }
    }
}

/// Export menu of the transcript header: pick a format and options, the file lands in Downloads under the
/// transcript's title (a taken name gets " (1)", " (2)"), and the result line offers Show in Finder.
/// Options start all on and are not remembered (v1 single export).
struct TBDExportButton: View {
    let item: TBDTranscription
    let summaries: [TBDSummary]
    @State private var shown = false
    @State private var format: TBDExportFormat = .txt
    @State private var options = TBDExportOptions.default
    @State private var status: TBDExportPanel.Status?

    var body: some View {
        Button { shown.toggle() } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .buttonStyle(TBDButtonStyle(.secondary))
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                TBDExportPanel(title: "Export Transcript", format: $format, options: $options,
                               timestampsReason: item.canExportTimestamps ? nil : "This transcript has no word timestamps.",
                               speakerLabelsReason: item.canExportSpeakerLabels ? nil : "This transcript has no speaker labels.",
                               actionTitle: "Export", actionIcon: "arrow.down.doc", status: status,
                               onAction: export, onClose: { shown = false })
            }
            .onChange(of: format) { _, _ in status = nil }
    }

    private func export() {
        do {
            guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            let url = TBDExportFiles.nextAvailableURL(in: downloads, stem: TBDExportFiles.stem(item), format: format)
            try TBDExport.libraryData(item, as: format, summaries: summaries, options: options).write(to: url, options: .atomic)
            status = .init(text: "Exported \(format.title) to Downloads as \(url.lastPathComponent).", reveal: [url])
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            status = .init(text: "Your Downloads folder could not be found.", isError: true)
        } catch {
            status = .init(text: "Export failed: \(error.localizedDescription)", isError: true)
        }
    }
}

/// Star toggle for a library item (transcript header).
struct TBDFavoriteButton: View {
    let item: TBDTranscription
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var failure: String?

    var body: some View {
        Button {
            do { try env.database?.setFavorite(id: item.id, !item.isFavorite); env.changed() }
            catch { failure = error.localizedDescription }
        } label: { Image(systemName: item.isFavorite ? "star.fill" : "star") }
            .buttonStyle(TBDButtonStyle(.icon))
            .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .alert("Could not update the favorite", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
    }
}
