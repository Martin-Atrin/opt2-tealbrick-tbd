import SwiftUI
import TBDDesign
import TBDSpeech

/// Record / pause / stop button for the page header.
struct TBDMeetingButton: View {
    @ObservedObject var meetings: TBDMeetingController
    var body: some View {
        switch meetings.phase {
        case .idle:
            Button { meetings.begin(title: nil) } label: { Label("Record meeting", systemImage: "record.circle") }
                .buttonStyle(TBDButtonStyle(.primary))
        case .starting, .processing:
            Button {} label: { Label(meetings.statusText, systemImage: "hourglass") }.buttonStyle(TBDButtonStyle(.secondary)).disabled(true)
        case .recording, .paused:
            Button { meetings.stop() } label: { Label("Stop · " + TBDPillClock.text(meetings.elapsedMs), systemImage: "stop.fill") }
                .buttonStyle(TBDButtonStyle(.destructive))
        }
    }
}

/// Live meeting panel above the list of recorded meetings.
struct TBDMeetingsView: View {
    let context: TBDListeningContext
    @ObservedObject private var meetings: TBDMeetingController
    @State private var labelFilter: Set<String> = []

    init(context: TBDListeningContext) {
        self.context = context
        meetings = context.meetings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.lg) {
            if meetings.phase != .idle { livePanel } else if !meetings.upcoming.isEmpty { upcomingPanel }
            if let stage = meetings.finalizingStage {
                HStack(spacing: TBDTokens.Space.sm) { ProgressView().controlSize(.small); Text(stage).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted) }
            }
            if let notice = meetings.captureNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.brickInk)
            }
            if let warning = meetings.warning {
                Text(warning).font(TBDTokens.Typography.body).foregroundStyle(TBDColor.brickInk)
            }
            HStack {
                TBDLabelFilterBar(selection: $labelFilter)
                Spacer()
                Button { meetings.importMeeting() } label: { Label("Import recording…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(TBDButtonStyle(.quiet)).help("Import an audio or video file as a meeting")
            }
            TBDLibraryView(context: context, kind: .meeting, labelFilter: labelFilter)
        }
    }

    private var livePanel: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            HStack(spacing: TBDTokens.Space.md) {
                TBDChip(meetings.statusText, color: meetings.phase == .recording ? TBDColor.brick : TBDColor.muted)
                TBDMeetingLevels(meetings: meetings)
                Spacer()
                switch meetings.phase {
                case .recording, .paused:
                    if meetings.canMuteMic {
                        Button { meetings.toggleMute() } label: {
                            Label(meetings.isMicMuted ? "Unmute" : "Mute", systemImage: meetings.isMicMuted ? "mic.slash.fill" : "mic.fill")
                        }
                        .buttonStyle(TBDButtonStyle(.secondary))
                        .help(meetings.isMicMuted ? "Unmute your microphone" : "Mute your microphone in this recording. System audio keeps recording.")
                    }
                    if meetings.phase == .recording {
                        Button { meetings.pause() } label: { Label("Pause", systemImage: "pause.fill") }.buttonStyle(TBDButtonStyle(.secondary))
                    } else {
                        Button { meetings.resume() } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(TBDButtonStyle(.secondary))
                    }
                    Button { meetings.showPanel() } label: { Label("Pop out", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(TBDButtonStyle(.secondary)).help("Open the live panel in a floating window")
                    TBDStopConfirmButton(labeled: true) { meetings.stop() }
                case .processing(let stage):
                    ProgressView().controlSize(.small)
                    Text(stage).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                default: EmptyView()
                }
            }
            TBDMeetingLivePanes(meetings: meetings, database: context.env.database, height: 260)
        }
        .tbdCard(padding: TBDTokens.Space.md)
    }

    private var upcomingPanel: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel("Upcoming")
            ForEach(meetings.upcoming.prefix(3)) { meeting in
                HStack {
                    Text(meeting.start.formatted(date: .omitted, time: .shortened)).font(TBDFonts.mono(12))
                        .foregroundStyle(TBDColor.muted)
                    Text(meeting.title).font(TBDTokens.Typography.body).foregroundStyle(TBDColor.ink)
                    if context.env.preferences.calendarAutoStart, meetings.isSkipped(meeting) {
                        Text("Won't auto-record").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                    }
                    Spacer()
                    Button("Record") { meetings.begin(title: meeting.title) }.buttonStyle(TBDButtonStyle(.quiet))
                }
                .contextMenu {
                    if meetings.isSkipped(meeting) {
                        Button(meeting.recurring ? "Auto-record this repeating meeting again" : "Auto-record again") { meetings.unskip(meeting) }
                    } else {
                        Button("Don't auto-record this meeting") { meetings.skip(meeting, series: false) }
                        if meeting.recurring {
                            Button("Don't auto-record this repeating meeting") { meetings.skip(meeting, series: true) }
                        }
                    }
                }
            }
        }
        .tbdCard(padding: TBDTokens.Space.md)
    }
}
