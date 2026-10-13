import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// The floating meeting pill (v1 `MeetingRecordingPillController`): a small non-activating panel that stays over
/// other apps while a meeting records. It starts flush at the right screen edge, vertically centred, and can be
/// dragged anywhere. Its face follows the meeting: starting, recording or paused with the controls, saving, saved.
/// Hiding it with the setting remembers its place for the next show.
@MainActor
final class TBDMeetingPill {
    private unowned let meetings: TBDMeetingController
    private var panel: NSPanel?
    private var preservedFrame: CGRect?

    init(meetings: TBDMeetingController) { self.meetings = meetings }

    var isVisible: Bool { panel != nil }

    /// Brings the pill in line with the meeting: shows, resizes for the face, or hides.
    func sync(face: TBDMeetingPillFace, showSetting: Bool) {
        if TBDMeetingPillRules.isVisible(face, showSetting: showSetting) {
            show(face: face)
        } else {
            // A hidden setting keeps the place; the end of a meeting forgets it.
            hide(keepPlace: face != .hidden && !showSetting)
        }
    }

    private func show(face: TBDMeetingPillFace) {
        let size = TBDMeetingPillRules.size(for: face)
        if let panel {
            panel.setFrame(TBDMeetingPillRules.resized(frame: panel.frame, to: size), display: true)
            panel.orderFront(nil)
            return
        }
        let panel = TBDMeetingPillPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingView(rootView: TBDMeetingPillView(meetings: meetings))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        if let preservedFrame {
            let screen = NSScreen.screens.first { $0.frame.intersects(preservedFrame) } ?? NSScreen.main
            let frame = screen.map { TBDMeetingPillRules.clamped(preservedFrame, into: $0.visibleFrame) } ?? preservedFrame
            panel.setFrame(TBDMeetingPillRules.resized(frame: frame, to: size), display: false)
            self.preservedFrame = nil
        } else if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(TBDMeetingPillRules.defaultOrigin(in: visible, size: size))
        }
        panel.orderFront(nil)
        self.panel = panel
    }

    func hide(keepPlace: Bool = false) {
        preservedFrame = keepPlace ? panel?.frame ?? preservedFrame : nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Never takes focus, so a click on a button does not pull the person out of the app they are using.
private final class TBDMeetingPillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct TBDMeetingPillView: View {
    @ObservedObject var meetings: TBDMeetingController

    var body: some View {
        content
            .padding(.horizontal, TBDTokens.Space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(TBDDesign.recordingSurface, in: RoundedRectangle(cornerRadius: TBDTokens.Radius.base + 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base + 6, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .contextMenu { menu }
    }

    @ViewBuilder private var content: some View {
        switch meetings.pillFace {
        case .hidden: EmptyView()
        case .starting:
            HStack(spacing: TBDTokens.Space.sm) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Starting…").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            }
        case .recording, .paused: running
        case .saving:
            HStack(spacing: TBDTokens.Space.sm) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Saving…").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            }
        case .saved:
            HStack(spacing: TBDTokens.Space.sm) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            }
        }
    }

    private var running: some View {
        HStack(spacing: TBDTokens.Space.sm) {
            Circle().fill(meetings.pillFace == .paused ? Color.orange : Color.red).frame(width: 8, height: 8)
            Text(TBDPillClock.text(meetings.elapsedMs))
                .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            if meetings.warning != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                    .help(meetings.warning ?? "")
            }
            TBDMeetingLevels(meetings: meetings, onDark: true)
            Spacer(minLength: 0)
            TBDMeetingIconControls(meetings: meetings, onDark: true)
            Button { meetings.showPanel() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: TBDTokens.Radius.sm))
            }
            .buttonStyle(.plain).help("Open the live meeting panel").accessibilityLabel("Open live meeting panel")
        }
    }

    @ViewBuilder private var menu: some View {
        switch meetings.pillFace {
        case .recording, .paused:
            Text(meetings.statusText)
            Divider()
            Button(meetings.pillFace == .paused ? "Resume Recording" : "Pause Recording") {
                if meetings.pillFace == .paused { meetings.resume() } else { meetings.pause() }
            }
            Button("End & Transcribe") { meetings.stop() }
            Button("Open Live Panel") { meetings.showPanel() }
            Button("Open TBD") { meetings.openApp() }
            Divider()
            Button("Discard Recording") { meetings.confirmDiscard() }
        case .starting, .saving, .saved:
            Button("Open TBD") { meetings.openApp() }
        case .hidden:
            EmptyView()
        }
    }
}
