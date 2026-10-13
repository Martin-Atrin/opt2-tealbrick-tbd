import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// Wires `TBDMeetingAutoStopMonitor` to the running Mac (v1 `MeetingAutoStopCoordinator`): once a second while a
/// meeting records and the setting is on, it reads the running meeting apps and the two channel levels, and
/// shows a 15 second "keep recording" countdown when the meeting looks finished. Only a countdown that runs out
/// while the same reason still holds stops the recording.
@MainActor
final class TBDMeetingAutoStopCoordinator {
    private var monitor = TBDMeetingAutoStopMonitor()
    private let toast = TBDAutoStopToast()
    private let isEnabled: () -> Bool
    private let isPaused: () -> Bool
    private let levels: () -> (mic: Float, system: Float)
    private let stopRecording: () -> Void
    private var timer: Timer?
    private var terminationObserver: NSObjectProtocol?

    init(isEnabled: @escaping () -> Bool, isPaused: @escaping () -> Bool, levels: @escaping () -> (mic: Float, system: Float),
         stopRecording: @escaping () -> Void) {
        self.isEnabled = isEnabled; self.isPaused = isPaused; self.levels = levels; self.stopRecording = stopRecording
    }

    func recordingDidStart() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let bundleID else { return }
                self.monitor.appTerminated(bundleID: bundleID)
                self.tick()
            }
        }
        tick()
    }

    func recordingDidEnd() {
        timer?.invalidate(); timer = nil
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
        monitor.end()
        toast.close()
    }

    private func signals(now: Date = Date()) -> TBDMeetingAutoStopMonitor.Signals {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let levels = levels()
        return .init(now: now, runningApps: running, micLevel: levels.mic, systemLevel: levels.system, isPaused: isPaused())
    }

    private func tick() {
        guard timer != nil else { return }
        guard isEnabled() else {
            if monitor.isActive { monitor.end(); toast.close() }
            return
        }
        let current = signals()
        if !monitor.isActive { monitor.begin(runningApps: current.runningApps, now: current.now) }
        switch monitor.observe(current) {
        case .none: break
        case .closeCountdown: toast.close()
        case .showCountdown(let reason):
            toast.show(title: reason.countdownTitle, duration: TBDMeetingAutoStopMonitor.countdownSeconds) { [weak self] outcome in
                self?.countdownEnded(outcome, reason: reason)
            }
        }
    }

    private func countdownEnded(_ outcome: TBDMeetingAutoStopMonitor.CountdownOutcome, reason: TBDMeetingAutoStopPolicy.StopReason) {
        guard isEnabled(), monitor.countdownEnded(outcome, reason: reason, signals: signals()) else { return }
        stopRecording()
    }
}

/// The countdown toast: top right, the ring is the timer, the close button keeps the recording (v1 toast).
@MainActor
final class TBDAutoStopToast: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var progress: Double = 0
    private var panel: NSPanel?
    private var timer: Timer?
    private var started = Date()
    private var duration: TimeInterval = 15
    private var onOutcome: ((TBDMeetingAutoStopMonitor.CountdownOutcome) -> Void)?

    func show(title: String, duration: TimeInterval, onOutcome: @escaping (TBDMeetingAutoStopMonitor.CountdownOutcome) -> Void) {
        finish(.programmaticClose)
        self.title = title
        self.duration = duration
        self.onOutcome = onOutcome
        progress = 0
        started = Date()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Closes without firing the default action.
    func close() { finish(.programmaticClose) }
    func keepRecording() { finish(.userDismissed) }

    private func tick() {
        progress = min(1, Date().timeIntervalSince(started) / duration)
        if progress >= 1 { finish(.completed) }
    }

    private func finish(_ outcome: TBDMeetingAutoStopMonitor.CountdownOutcome) {
        timer?.invalidate(); timer = nil
        guard let callback = onOutcome else { return }
        onOutcome = nil
        panel?.orderOut(nil)
        callback(outcome)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 76), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: TBDAutoStopToastView(model: self))
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let frame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 16))
    }
}

struct TBDAutoStopToastView: View {
    @ObservedObject var model: TBDAutoStopToast

    var body: some View {
        HStack(spacing: TBDTokens.Space.md) {
            ZStack {
                Circle().stroke(TBDColor.overlayOn.opacity(0.2), lineWidth: 3)
                Circle().trim(from: 0, to: model.progress)
                    .stroke(TBDColor.brick, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "stop.fill").font(TBDFonts.symbol(10, TBDKit.weightNav)).foregroundStyle(TBDColor.overlayOn)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.overlayOn).lineLimit(1)
                Text("Stopping soon").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.overlayOn.opacity(0.75))
            }
            Spacer(minLength: 0)
            Button("Keep recording") { model.keepRecording() }
                .buttonStyle(.plain).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.overlayFill)
                .padding(.horizontal, TBDKit.s3).frame(minHeight: 36).background(TBDColor.overlayOn, in: TBDBrickShape())
                .contentShape(TBDBrickShape())
                .accessibilityLabel("Keep recording")
        }
        .padding(.horizontal, TBDTokens.Space.lg)
        .frame(width: 340, height: 64)
        // Fixed dark ground in both appearances (floats over arbitrary desktop content); the panel's window shadow is the float shadow.
        .background(TBDColor.overlayFill, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(TBDColor.overlayOn.opacity(0.14), lineWidth: TBDKit.hair))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
