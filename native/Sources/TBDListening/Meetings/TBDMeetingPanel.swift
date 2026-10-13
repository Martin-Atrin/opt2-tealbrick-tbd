import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// The expanded live meeting window (v1 `MeetingRecordingPanelController`): floats over other apps and hosts the
/// live panes (notes, transcript, ask). Closing it only hides it; the recording goes on. It is built on demand
/// from the pill or the Meetings page and closed when the recording stops.
@MainActor
final class TBDMeetingPanel {
    private unowned let meetings: TBDMeetingController
    private let database: () -> TBDListeningDatabase?
    private var panel: NSPanel?
    private var delegate: TBDMeetingPanelDelegate?

    init(meetings: TBDMeetingController, database: @escaping () -> TBDListeningDatabase?) {
        self.meetings = meetings
        self.database = database
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if panel == nil { build() }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { panel?.orderOut(nil) }

    func close() {
        panel?.delegate = nil
        panel?.close()
        panel = nil
        delegate = nil
    }

    private func build() {
        let panel = TBDMeetingPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Meeting recording"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 320)
        panel.contentView = NSHostingView(rootView: TBDMeetingPanelView(meetings: meetings, database: database()))
        if !panel.setFrameUsingName("TBDMeetingPanel"), let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(TBDMeetingPillRules.panelOrigin(in: frame, size: panel.frame.size))
        }
        panel.setFrameAutosaveName("TBDMeetingPanel")
        let delegate = TBDMeetingPanelDelegate { [weak self] in self?.hide() }
        panel.delegate = delegate
        self.panel = panel
        self.delegate = delegate
    }
}

private final class TBDMeetingPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class TBDMeetingPanelDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onClose(); return false }
}

/// Header controls and the live panes.
struct TBDMeetingPanelView: View {
    @ObservedObject var meetings: TBDMeetingController
    let database: TBDListeningDatabase?

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            HStack(spacing: TBDTokens.Space.md) {
                TBDChip(meetings.statusText, color: meetings.phase == .recording ? TBDTokens.alert : TBDTokens.muted)
                TBDMeetingLevels(meetings: meetings)
                Spacer()
                TBDMeetingIconControls(meetings: meetings, onDark: false)
            }
            if let warning = meetings.warning {
                Text(warning).font(.system(size: 12)).foregroundStyle(TBDTokens.alert)
            }
            if meetings.isRecording {
                TBDMeetingLivePanes(meetings: meetings, database: database, height: nil)
            } else {
                Text(meetings.statusText).foregroundStyle(TBDTokens.muted)
                Spacer()
            }
        }
        .padding(.horizontal, TBDTokens.Space.lg).padding(.bottom, TBDTokens.Space.lg).padding(.top, TBDTokens.Space.xxl)
        .frame(minWidth: 360, minHeight: 320)
        .background(TBDTokens.canvas)
    }
}

/// Notes, transcript and ask for the meeting being recorded. Shared by the Meetings page and the floating panel.
struct TBDMeetingLivePanes: View {
    @ObservedObject var meetings: TBDMeetingController
    let database: TBDListeningDatabase?
    /// Fixed height on the page; nil fills the floating panel.
    var height: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
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
                case .transcript: preview
                case .ask:
                    TBDAskView(model: meetings.liveAsk, starters: TBDAskPrompts.starters(database),
                               followUps: TBDAskPrompts.followUps(database), showsHistory: false)
                }
            }
            .frame(height: height)
            .frame(maxHeight: height == nil ? .infinity : nil)
        }
    }

    private var preview: some View {
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
}

/// Microphone and system level bars. A source the recording does not capture is left out; a muted microphone reads empty.
struct TBDMeetingLevels: View {
    @ObservedObject var meetings: TBDMeetingController
    var onDark = false

    var body: some View {
        HStack(spacing: TBDTokens.Space.md) {
            if meetings.captureSource.capturesMicrophone {
                bars("You", level: meetings.micLevel)
            }
            if meetings.captureSource.capturesSystemAudio {
                bars("Others", level: meetings.systemLevel)
            }
        }
    }

    private func bars(_ title: String, level: Float) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if onDark { Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.6)) } else { TBDLabel(title) }
            TBDLevelBars(levels: [level], color: onDark ? .white : TBDTokens.accent).frame(width: 46, height: 10)
        }
    }
}

/// Mute, pause or resume, and stop as icons (floating panel and pill).
struct TBDMeetingIconControls: View {
    @ObservedObject var meetings: TBDMeetingController
    var onDark: Bool

    var body: some View {
        HStack(spacing: TBDTokens.Space.xs) {
            if meetings.canMuteMic {
                iconButton(meetings.isMicMuted ? "mic.slash.fill" : "mic.fill", tint: meetings.isMicMuted ? Color.red : nil,
                           help: meetings.isMicMuted ? "Unmute your microphone" : "Mute your microphone in this recording. System audio keeps recording.",
                           label: meetings.isMicMuted ? "Unmute microphone" : "Mute microphone") { meetings.toggleMute() }
            }
            switch meetings.phase {
            case .recording:
                iconButton("pause.fill", help: "Pause recording", label: "Pause recording") { meetings.pause() }
            case .paused:
                iconButton("play.fill", help: "Resume recording", label: "Resume recording") { meetings.resume() }
            default: EmptyView()
            }
            if meetings.phase == .recording || meetings.phase == .paused {
                TBDStopConfirmButton(onDark: onDark) { meetings.stop() }
            }
        }
    }

    private func iconButton(_ symbol: String, tint: Color? = nil, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint ?? (onDark ? .white : TBDTokens.ink))
                .frame(width: 26, height: 26)
                .background((onDark ? Color.white : TBDTokens.ink).opacity(0.1), in: RoundedRectangle(cornerRadius: TBDTokens.Radius.sm))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(label)
    }
}

/// Stop with a second step (v1 `StopRecordingButton`): the first press shows "End now", a second press within
/// three seconds stops, and then the button falls back.
struct TBDStopConfirmButton: View {
    var labeled = false
    var onDark = false
    let action: () -> Void
    @State private var confirmation = TBDStopConfirmation()
    @State private var armed = false
    @State private var revert: Task<Void, Never>?

    var body: some View {
        Button(action: press) {
            if armed {
                Text("End now").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: TBDTokens.Radius.sm))
            } else if labeled {
                Label("Stop", systemImage: "stop.fill")
            } else {
                Image(systemName: "stop.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(onDark ? Color.white : Color.red)
                    .frame(width: 26, height: 26)
                    .background((onDark ? Color.white : TBDTokens.ink).opacity(0.1), in: RoundedRectangle(cornerRadius: TBDTokens.Radius.sm))
            }
        }
        .modifier(StopStyle(labeled: labeled && !armed))
        .help(armed ? "End the recording now" : "End recording")
        .accessibilityLabel(armed ? "Confirm ending recording" : "End recording")
        .onDisappear { revert?.cancel() }
    }

    private func press() {
        if confirmation.press(now: Date()) {
            revert?.cancel()
            armed = false
            action()
        } else {
            armed = true
            revert?.cancel()
            revert = Task { @MainActor in
                try? await Task.sleep(for: .seconds(TBDStopConfirmation.window))
                guard !Task.isCancelled else { return }
                confirmation.reset()
                armed = false
            }
        }
    }

    private struct StopStyle: ViewModifier {
        let labeled: Bool
        func body(content: Content) -> some View {
            if labeled { content.buttonStyle(TBDButtonStyle(.destructive)) } else { content.buttonStyle(.plain) }
        }
    }
}
