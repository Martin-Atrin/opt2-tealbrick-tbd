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
            if let stage = meetings.finalizingStage {
                HStack(spacing: TBDTokens.Space.sm) { ProgressView().controlSize(.small); Text(stage).foregroundStyle(TBDTokens.muted) }
            }
            if let warning = meetings.warning {
                Text(warning).font(TBDTokens.Typography.body).foregroundStyle(TBDTokens.alert)
            }
            HStack {
                Spacer()
                Button { meetings.importMeeting() } label: { Label("Import recording…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(TBDButtonStyle(.quiet)).help("Import an audio or video file as a meeting")
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
            Picker("", selection: $meetings.liveTab) {
                ForEach(TBDMeetingController.LiveTab.allCases) { tab in
                    Text(tab == .ask && meetings.liveAsk.streaming ? "Ask •" : tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Group {
                switch meetings.liveTab {
                case .notes:
                    TBDNotesEditor(text: Binding(get: { meetings.notes }, set: { meetings.editNotes($0) }),
                                   elapsedMs: { meetings.elapsedMs }, footnote: "Auto-saved with the recording. Stays on this Mac.")
                case .transcript: livePreview
                case .ask: TBDAskView(model: meetings.liveAsk, showsHistory: false)
                }
            }
            .frame(height: 260)
        }
        .tbdCard(padding: TBDTokens.Space.md)
    }

    private var livePreview: some View {
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
            .onChange(of: meetings.preview.count) { _, _ in
                if let last = meetings.preview.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var upcomingPanel: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel("Upcoming")
            ForEach(meetings.upcoming.prefix(3)) { meeting in
                HStack {
                    Text(meeting.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TBDTokens.muted)
                    Text(meeting.title).font(TBDTokens.Typography.body)
                    if context.env.preferences.calendarAutoStart, meetings.isSkipped(meeting) {
                        Text("Won't auto-record").font(.system(size: 11)).foregroundStyle(TBDTokens.muted)
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
