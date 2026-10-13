import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech
import UniformTypeIdentifiers

/// The Transcribe landing page (v1 `TranscribeView`): a link card, a file drop zone and the meeting
/// tile, with the queue underneath.
struct TBDTranscribeView: View {
    let context: TBDListeningContext
    @ObservedObject private var queue: TBDFileQueue
    @State private var link = ""
    @State private var dragging = false

    init(context: TBDListeningContext) {
        self.context = context
        queue = context.files
    }

    private var input: TBDLinkInput { TBDLinkInput.classify(link) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TBDTokens.Space.lg) {
                TBDPageHeader("Transcribe", label: "Listening · Processed on this Mac")
                HStack(alignment: .top, spacing: TBDTokens.Space.lg) {
                    linkCard
                    dropZone
                }
                TBDMeetingTile(meetings: context.meetings)
                TBDQueueStrip(queue: queue)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: From a link

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            TBDLabel("From a link")
            Text(input.title).font(TBDTokens.Typography.display).tracking(TBDTokens.Typography.displayTracking).foregroundStyle(TBDTokens.ink)
            HStack(spacing: TBDTokens.Space.sm) {
                HStack(spacing: TBDTokens.Space.sm) {
                    Image(systemName: input.canSubmit ? "checkmark.circle.fill" : "link").foregroundStyle(input.canSubmit ? TBDTokens.accent : TBDTokens.muted)
                    TextField("Paste a video or podcast link, or a podcast name", text: $link).textFieldStyle(.plain).onSubmit(submit)
                    Button("Paste") {
                        if let clip = NSPasteboard.general.string(forType: .string) { link = clip.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .buttonStyle(TBDButtonStyle(.quiet)).help("Paste from clipboard")
                }
                .padding(.horizontal, TBDTokens.Space.md).frame(minHeight: TBDTokens.Control.minHeight)
                .background(TBDTokens.paper)
                .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
                    .strokeBorder(input == .invalid ? TBDTokens.alert : TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline))
                Button(action: submit) { Label("Transcribe", systemImage: "arrow.right") }
                    .buttonStyle(TBDButtonStyle(.primary)).disabled(!input.canSubmit)
            }
            Text(input.caption).font(.system(size: 12)).foregroundStyle(input == .invalid ? TBDTokens.alert : TBDTokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(TBDTokens.Space.lg)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(TBDTokens.paper)
        .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline))
    }

    private func submit() {
        guard let text = input.queueText else { return }
        queue.enqueue(link: text)
        link = ""
    }

    // MARK: From a file

    private var dropZone: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            TBDLabel("From a file")
            Text("Drop a file to transcribe").font(TBDTokens.Typography.display).tracking(TBDTokens.Typography.displayTracking).foregroundStyle(TBDTokens.ink)
            HStack(spacing: TBDTokens.Space.md) {
                Image(systemName: dragging ? "arrow.down.doc.fill" : "arrow.down.doc").font(.system(size: 20))
                    .foregroundStyle(dragging ? TBDTokens.accent : TBDTokens.muted).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dragging ? "Release to transcribe" : "Drag audio, video or a folder here").font(TBDTokens.Typography.control).foregroundStyle(TBDTokens.ink)
                    Text("MP3, WAV, M4A, MP4, MOV, FLAC and more").font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
                }
                Spacer(minLength: TBDTokens.Space.md)
                Button { queue.pickFiles() } label: { Label("Browse files", systemImage: "folder") }
                    .buttonStyle(TBDButtonStyle(.secondary))
                    .accessibilityHint("Opens a file picker to choose audio or video files")
            }
            .padding(TBDTokens.Space.md)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(dragging ? TBDTokens.selected.opacity(0.7) : TBDTokens.canvas)
            .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
                .strokeBorder(dragging ? TBDTokens.accent : TBDTokens.border, style: StrokeStyle(lineWidth: dragging ? 2 : 1, dash: dragging ? [] : [5, 4])))
            Text("Files never leave this Mac.").font(.system(size: 12)).foregroundStyle(TBDTokens.muted)
        }
        .padding(TBDTokens.Space.lg)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(TBDTokens.paper)
        .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline))
        .onDrop(of: [.fileURL], isTargeted: $dragging) { providers in
            Task { @MainActor in queue.enqueue(files: await TBDDropCollector.urls(from: providers)) }
            return true
        }
        .accessibilityLabel("File drop zone")
    }
}

/// Meeting tile on the Transcribe page: start, pause and stop a recording (v1 `MeetingRecordingTile`).
struct TBDMeetingTile: View {
    @ObservedObject var meetings: TBDMeetingController

    var body: some View {
        HStack(spacing: TBDTokens.Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                TBDLabel("Meeting")
                Text(meetings.phase == .idle ? "Record a meeting" : meetings.statusText)
                    .font(TBDTokens.Typography.title).foregroundStyle(TBDTokens.ink)
                Text(meetings.warning ?? "Captures your microphone and the sound from other apps. Notes and transcript stay on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(meetings.warning == nil ? TBDTokens.muted : TBDTokens.alert)
            }
            Spacer()
            if meetings.phase == .recording || meetings.phase == .paused {
                Button { meetings.phase == .paused ? meetings.resume() : meetings.pause() } label: {
                    Label(meetings.phase == .paused ? "Resume" : "Pause", systemImage: meetings.phase == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(TBDButtonStyle(.secondary))
            }
            TBDMeetingButton(meetings: meetings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tbdCard()
    }
}
