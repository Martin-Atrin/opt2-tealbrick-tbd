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
                TBDChip(meetings.statusText, color: meetings.phase == .recording ? TBDColor.brick : TBDColor.muted)
                TBDMeetingLevels(meetings: meetings)
                Spacer()
                TBDMeetingIconControls(meetings: meetings, onDark: false)
            }
            if let notice = meetings.captureNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk)
            }
            if let warning = meetings.warning {
                Text(warning).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk)
            }
            if meetings.isRecording {
                TBDMeetingLivePanes(meetings: meetings, database: database, height: nil)
            } else {
                Text(meetings.statusText).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                Spacer()
            }
        }
        .padding(.horizontal, TBDTokens.Space.lg).padding(.bottom, TBDTokens.Space.lg).padding(.top, TBDTokens.Space.xxl)
        .frame(minWidth: 360, minHeight: 320)
        .background(TBDColor.paper)
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
            TBDSegmented(selection: $meetings.liveTab,
                         options: TBDMeetingController.LiveTab.allCases.map { ($0, $0 == .ask && meetings.liveAsk.streaming ? "Ask •" : $0.title) })
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
                        Text("Live preview appears here as people speak.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                    }
                    ForEach(meetings.preview) { line in
                        HStack(alignment: .firstTextBaseline, spacing: TBDTokens.Space.sm) {
                            Text(TBDExport.clock(line.startMs)).font(TBDFonts.mono(12)).foregroundStyle(TBDColor.muted)
                            Text(line.source == .me ? "Me" : "Others").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.tealInk)
                            Text(line.text).font(TBDTokens.Typography.body).foregroundStyle(TBDColor.ink).textSelection(.enabled)
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
            if onDark { Text(title).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.overlayOn.opacity(0.75)) } else { TBDLabel(title) }
            TBDLevelBars(levels: [level], color: onDark ? TBDColor.teal : TBDColor.tealInk).frame(width: 46, height: 10)
        }
    }
}

/// Mute, pause or resume, and stop as icons (floating panel and pill).
struct TBDMeetingIconControls: View {
    @ObservedObject var meetings: TBDMeetingController
    var onDark: Bool

    var body: some View {
        HStack(spacing: onDark ? 0 : TBDKit.s1) {
            if meetings.canMuteMic {
                iconButton(meetings.isMicMuted ? "mic.slash.fill" : "mic.fill", tint: meetings.isMicMuted ? (onDark ? TBDColor.brick : TBDColor.brickInk) : nil,
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
            let glyph = Image(systemName: symbol).font(TBDFonts.symbol(12, TBDKit.weightNav))
            if onDark {
                // Over the dark floating pill: light glyph on a faint light brick. The pill is 40pt high and fixed in width,
                // so the hit area is 30 x 36 around a 28pt brick.
                glyph.foregroundStyle(tint ?? TBDColor.overlayOn)
                    .frame(width: 28, height: 28)
                    .background(TBDColor.overlayOn.opacity(0.1), in: TBDBrickShape())
                    .frame(width: 30, height: 36)
                    .contentShape(Rectangle())
            } else if let tint {
                glyph.foregroundStyle(tint)
            } else {
                glyph
            }
        }
        .modifier(IconStyle(onDark: onDark)).help(help).accessibilityLabel(label)
    }

    private struct IconStyle: ViewModifier {
        let onDark: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if onDark { content.buttonStyle(.plain) } else { content.buttonStyle(TBDButtonStyle(.icon)) }
        }
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
                // The confirm step is its own filled pair, so it reads the same on the dark pill and on the paper panel.
                Text("End now").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.dangerConfirmOn)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(TBDColor.dangerConfirmFill, in: TBDBrickShape())
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
            } else if labeled {
                Label("Stop", systemImage: "stop.fill")
            } else if onDark {
                Image(systemName: "stop.fill").font(TBDFonts.symbol(11, TBDKit.weightNav))
                    .foregroundStyle(TBDColor.overlayOn)
                    .frame(width: 28, height: 28)
                    .background(TBDColor.overlayOn.opacity(0.1), in: TBDBrickShape())
                    .frame(width: 30, height: 36)
                    .contentShape(Rectangle())
            } else {
                Image(systemName: "stop.fill").font(TBDFonts.symbol(11, TBDKit.weightNav))
                    .foregroundStyle(TBDColor.brickInk)
            }
        }
        .modifier(StopStyle(labeled: labeled && !armed, plain: armed || onDark))
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
        let plain: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if labeled { content.buttonStyle(TBDButtonStyle(.destructive)) }
            else if plain { content.buttonStyle(.plain) }
            else { content.buttonStyle(TBDButtonStyle(.icon)) }
        }
    }
}
