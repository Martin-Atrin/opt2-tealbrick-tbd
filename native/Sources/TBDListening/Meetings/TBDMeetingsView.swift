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

    init(context: TBDListeningContext) {
        self.context = context
        meetings = context.meetings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.lg) {
            if meetings.phase != .idle { livePanel } else if !meetings.upcoming.isEmpty { upcomingPanel }
            if let warning = meetings.warning {
                Text(warning).font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.alert)
            }
            TBDLibraryView(context: context, kind: .meeting)
        }
    }

    private var livePanel: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            HStack(spacing: TBDTokens.Space.md) {
                TBDChip(meetings.statusText, color: meetings.phase == .recording ? TBDTokens.alert : TBDTokens.muted)
                VStack(alignment: .leading, spacing: 2) {
                    TBDLabel("You")
                    TBDLevelBars(levels: [meetings.micLevel], color: TBDTokens.accent).frame(width: 60, height: 10)
                }
                VStack(alignment: .leading, spacing: 2) {
                    TBDLabel("Others")
                    TBDLevelBars(levels: [meetings.systemLevel], color: TBDTokens.accent).frame(width: 60, height: 10)
                }
                Spacer()
                switch meetings.phase {
                case .recording:
                    Button { meetings.pause() } label: { Label("Pause", systemImage: "pause.fill") }.buttonStyle(TBDButtonStyle(.secondary))
                    Button { meetings.stop() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(TBDButtonStyle(.destructive))
                case .paused:
                    Button { meetings.resume() } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(TBDButtonStyle(.secondary))
                    Button { meetings.stop() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(TBDButtonStyle(.destructive))
                case .processing(let stage):
                    ProgressView().controlSize(.small)
                    Text(stage).foregroundStyle(TBDTokens.muted)
                default: EmptyView()
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                        if meetings.preview.isEmpty {
                            Text("Live preview appears here as people speak.").foregroundStyle(TBDTokens.muted)
                        }
                        ForEach(meetings.preview) { line in
                            HStack(alignment: .firstTextBaseline, spacing: TBDTokens.Space.sm) {
                                Text(TBDExport.clock(line.startMs)).font(.system(size: 11, design: .monospaced)).foregroundStyle(TBDTokens.muted)
                                Text(line.source == .me ? "Me" : "Others").font(TBDTokens.Typography.label).foregroundStyle(TBDTokens.accent)
                                Text(line.text).font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.ink).textSelection(.enabled)
                            }
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .onChange(of: meetings.preview.count) { _, _ in
                    if let last = meetings.preview.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .tbdCard(padding: TBDTokens.Space.md)
    }

    private var upcomingPanel: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel("Upcoming")
            ForEach(meetings.upcoming.prefix(3)) { meeting in
                HStack {
                    Text(meeting.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TBDTokens.muted)
                    Text(meeting.title).font(TBDTokens.Typography.body)
                    Spacer()
                    Button("Record") { meetings.begin(title: meeting.title) }.buttonStyle(TBDButtonStyle(.quiet))
                }
            }
        }
        .tbdCard(padding: TBDTokens.Space.md)
    }
}
