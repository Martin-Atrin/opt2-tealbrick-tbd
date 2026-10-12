import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// Five-second countdown before a calendar meeting is recorded automatically. Start now records
/// at once; dismissing skips this occurrence.
@MainActor
final class TBDMeetingCountdown: ObservableObject {
    enum Outcome { case completed, startNow, dismissed, replaced }
    static let seconds: Double = 5

    @Published private(set) var title = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var remaining = Int(seconds)
    private var panel: NSPanel?
    private var timer: Timer?
    private var started = Date()
    private var completion: ((Outcome) -> Void)?

    var isShowing: Bool { completion != nil }

    func show(_ meeting: TBDCalendarMonitor.Meeting, completion: @escaping (Outcome) -> Void) {
        finish(.replaced)
        title = meeting.title
        progress = 0
        remaining = Int(Self.seconds)
        started = Date()
        self.completion = completion
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func startNow() { finish(.startNow) }
    func dismiss() { finish(.dismissed) }

    private func tick() {
        let elapsed = Date().timeIntervalSince(started)
        progress = min(1, elapsed / Self.seconds)
        remaining = max(0, Int((Self.seconds - elapsed).rounded(.up)))
        if elapsed >= Self.seconds { finish(.completed) }
    }

    private func finish(_ outcome: Outcome) {
        timer?.invalidate()
        timer = nil
        guard let completion else { return }
        self.completion = nil
        panel?.orderOut(nil)
        completion(outcome)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 76),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: TBDMeetingCountdownView(model: self))
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 16))
    }
}

struct TBDMeetingCountdownView: View {
    @ObservedObject var model: TBDMeetingCountdown

    var body: some View {
        HStack(spacing: TBDTokens.Space.md) {
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 3)
                Circle().trim(from: 0, to: model.progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(model.remaining)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(TBDTokens.Typography.control).foregroundStyle(.white).lineLimit(1)
                Text("Auto-recording").font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
            Button("Start now") { model.startNow() }
                .buttonStyle(.plain).font(TBDTokens.Typography.control).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4).background(.white.opacity(0.18), in: Capsule())
                .keyboardShortcut(.return, modifiers: [])
            Button { model.dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: []).help("Don't record this meeting")
            .accessibilityLabel("Cancel auto-start")
        }
        .padding(.horizontal, TBDTokens.Space.lg)
        .frame(width: 320, height: 64)
        .background(TBDDesign.recordingSurface, in: RoundedRectangle(cornerRadius: TBDTokens.Radius.sm + 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.sm + 10, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
