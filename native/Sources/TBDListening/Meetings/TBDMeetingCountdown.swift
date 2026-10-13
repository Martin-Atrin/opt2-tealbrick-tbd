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
                Circle().stroke(TBDColor.overlayOn.opacity(0.2), lineWidth: 3)
                Circle().trim(from: 0, to: model.progress)
                    .stroke(TBDColor.teal, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(model.remaining)").font(TBDFonts.mono(13, TBDKit.weightNav)).foregroundStyle(TBDColor.overlayOn)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.overlayOn).lineLimit(1)
                Text("Auto-recording").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.overlayOn.opacity(0.75))
            }
            Spacer(minLength: 0)
            // The main action is the inverted brick: light ground, dark ink (the overlay pair turned over).
            Button("Start now") { model.startNow() }
                .buttonStyle(.plain).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.overlayFill)
                .padding(.horizontal, TBDKit.s3).frame(minHeight: 36).background(TBDColor.overlayOn, in: TBDBrickShape())
                .contentShape(TBDBrickShape())
                .keyboardShortcut(.return, modifiers: [])
            Button { model.dismiss() } label: {
                Image(systemName: "xmark").font(TBDFonts.symbol(10, TBDKit.weightHead)).foregroundStyle(TBDColor.overlayOn)
                    .frame(width: 28, height: 28).background(TBDColor.overlayOn.opacity(0.14), in: TBDBrickShape())
                    .frame(minWidth: 36, minHeight: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: []).help("Don't record this meeting")
            .accessibilityLabel("Cancel auto-start")
        }
        .padding(.horizontal, TBDTokens.Space.lg)
        .frame(width: 320, height: 64)
        // Fixed dark ground in both appearances (floats over arbitrary desktop content); the panel's window shadow is the float shadow.
        .background(TBDColor.overlayFill, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(TBDColor.overlayOn.opacity(0.14), lineWidth: TBDKit.hair))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
