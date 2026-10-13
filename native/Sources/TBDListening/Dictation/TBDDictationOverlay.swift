import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// State shown by the floating recording pill.
@MainActor
final class TBDOverlayModel: ObservableObject {
    enum Phase: Equatable {
        case hidden, recording(handsFree: Bool), processing(String), message(String), prompt(String, action: String)
        /// A cancelled dictation that can still be brought back.
        case undo(remaining: Int, total: Int)
    }
    @Published var phase: Phase = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: 24)
    @Published var elapsedMs = 0
    /// Live preview text while recording (display only; the pasted text comes from the final pass).
    @Published var partial = ""
    /// Screen edge (Settings > Pill position): a top pill puts the live preview below it.
    @Published var placement = TBDOverlayPlacement.bottom
    @Published var previewSize = TBDPreviewTextSize.medium
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onUndo: (() -> Void)?
    /// Prompt buttons (calendar reminder).
    var onAccept: (() -> Void)?
    var onDismissPrompt: (() -> Void)?
}

/// Floating, non-activating pill near the bottom of the active screen. Never takes focus,
/// so paste targets stay frontmost.
@MainActor
final class TBDDictationOverlay {
    let model = TBDOverlayModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let preferences = TBDListeningPreferences()
    private let idle = TBDIdlePill()
    private var screenObserver: NSObjectProtocol?

    /// Click on the idle pill: start dictating hands-free.
    var onIdleClick: (() -> Void)? {
        get { idle.onClick }
        set { idle.onClick = newValue }
    }

    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    /// Re-reads pill position, preview size and the idle-pill switch and moves what is on screen.
    func settingsChanged() {
        model.placement = preferences.dictationOverlayPlacement
        model.previewSize = preferences.dictationPreviewTextSize
        if let panel, model.phase != .hidden { position(panel) }
        refreshIdle()
    }

    /// Shows the idle pill when it is on and nothing else is on screen; hides it otherwise.
    func refreshIdle() {
        if preferences.showIdlePill, model.phase == .hidden {
            idle.show(placement: preferences.dictationOverlayPlacement, hotkeyName: (preferences.hotkey(for: .pushToTalk) ?? preferences.hotkey(for: .handsFree))?.displayName)
        } else {
            idle.hide()
        }
    }

    func show(_ phase: TBDOverlayModel.Phase) {
        hideWork?.cancel()
        idle.hide()
        if case .recording = phase {} else { model.partial = "" }
        model.placement = preferences.dictationOverlayPlacement
        model.previewSize = preferences.dictationPreviewTextSize
        model.phase = phase
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        if case .message = phase { hide(after: 2.8) }
        if case .prompt = phase { hide(after: 90) }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.model.phase = .hidden
            self?.model.partial = ""
            self?.refreshIdle()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func update(partial: String) {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.partial != text { model.partial = text }
    }

    func update(levels: [Float], elapsedMs: Int) {
        let count = model.levels.count
        let tail = Array(levels.suffix(count))
        model.levels = Array(repeating: 0, count: max(0, count - tail.count)) + tail
        model.elapsedMs = elapsedMs
    }

    private func makePanel() -> NSPanel {
        // Tall enough for two lines of live preview above the pill; the empty area is transparent.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 132),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: TBDRecordingPill(model: model))
        model.onDismissPrompt = { [weak self] in self?.hide() }
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let usable = TBDDictationOverlayLayout.usableFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                                           topInset: max(NSStatusBar.system.thickness, screen.safeAreaInsets.top))
        panel.setFrameOrigin(TBDDictationOverlayLayout.origin(in: usable, panelSize: panel.frame.size, placement: preferences.dictationOverlayPlacement))
    }
}

/// The pill: dark recording surface, live level bars, status and controls, with the live
/// preview text in a bubble above it while recording.
struct TBDRecordingPill: View {
    @ObservedObject var model: TBDOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsPartial: Bool {
        if case .recording = model.phase { return !model.partial.isEmpty }
        return false
    }

    var body: some View {
        let top = model.placement.anchorsToTop
        VStack(spacing: TBDTokens.Space.sm) {
            if !top { Spacer(minLength: 0) }
            if top { pill }
            if showsPartial {
                TBDLivePartialBubble(text: model.partial, size: model.previewSize)
                    .transition(.opacity.combined(with: .move(edge: top ? .top : .bottom)))
            }
            if !top { pill }
            if top { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: top ? .top : .bottom)
        .animation(TBDMotion.animation(TBDMotion.quick, reduce: reduceMotion), value: showsPartial)
    }

    private var pill: some View {
        HStack(spacing: TBDTokens.Space.md) {
            switch model.phase {
            case .recording(let handsFree):
                Circle().fill(TBDColor.brick).frame(width: 8, height: 8)
                TBDLevelBars(levels: model.levels).frame(width: 120, height: 24)
                Text(TBDPillClock.text(model.elapsedMs)).font(TBDFonts.mono(12))
                    .foregroundStyle(TBDColor.overlayOn.opacity(0.8))
                if handsFree {
                    pillButton("stop.fill", help: "Stop and paste") { model.onStop?() }
                }
                pillButton("xmark", help: "Cancel (Esc)") { model.onCancel?() }
            case .processing(let text):
                ProgressView().controlSize(.small).tint(TBDColor.overlayOn)
                Text(text).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.overlayOn)
            case .message(let text):
                Text(text).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.overlayOn).lineLimit(2)
            case .prompt(let text, let action):
                Image(systemName: "calendar").foregroundStyle(TBDColor.overlayOn)
                Text(text).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.overlayOn).lineLimit(1)
                // The main action is the inverted brick: light ground, dark ink (the overlay pair turned over).
                Button(action) { model.onAccept?() }
                    .buttonStyle(.plain).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.overlayFill)
                    .padding(.horizontal, TBDKit.s3).frame(minHeight: 32).background(TBDColor.overlayOn, in: TBDBrickShape())
                    .contentShape(TBDBrickShape())
                pillButton("xmark", help: "Dismiss") { model.onDismissPrompt?() }
            case .undo(let remaining, let total):
                Button { model.onCancel?() } label: {
                    ZStack {
                        Circle().stroke(TBDColor.overlayOn.opacity(0.2), lineWidth: 2)
                        Circle().trim(from: 0, to: CGFloat(remaining) / CGFloat(max(1, total)))
                            .stroke(TBDColor.overlayOn, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text("\(remaining)").font(TBDFonts.mono(11, TBDKit.weightNav)).foregroundStyle(TBDColor.overlayOn)
                    }
                    .frame(width: 24, height: 24)
                    .frame(minWidth: 36, minHeight: 36).contentShape(Rectangle())
                    .animation(TBDMotion.animation(TBDMotion.standard, reduce: reduceMotion), value: remaining)
                }
                .buttonStyle(.plain).help("Discard now").accessibilityLabel("Discard cancelled dictation")
                Text("Dictation cancelled").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.overlayOn)
                Button("Undo") { model.onUndo?() }
                    .buttonStyle(.plain).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.overlayOn)
                    .padding(.horizontal, TBDKit.s3).frame(minHeight: 32).background(TBDColor.overlayOn.opacity(0.14), in: TBDBrickShape())
                    .contentShape(TBDBrickShape())
                    .accessibilityLabel("Undo cancel and paste")
            case .hidden:
                EmptyView()
            }
        }
        .padding(.horizontal, TBDTokens.Space.lg)
        .frame(height: 44)
        // The floating status pill: fixed dark ground in both appearances, the one float shadow.
        .background(TBDColor.overlayFill, in: Capsule())
        .tbdPillEdge(TBDColor.overlayOn.opacity(0.14))
        .shadow(color: TBDColor.shadowInk, radius: TBDKit.floatShadowRadius, y: TBDKit.floatShadowY)
        .padding(.bottom, TBDKit.s4)
        .animation(TBDMotion.animation(TBDMotion.instant, reduce: reduceMotion), value: model.phase)
    }

    private func pillButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(TBDFonts.symbol(10, TBDKit.weightHead)).foregroundStyle(TBDColor.overlayOn)
                .frame(width: 28, height: 28).background(TBDColor.overlayOn.opacity(0.14), in: TBDBrickShape())
                .frame(minWidth: 36, minHeight: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

/// The newest words of the live preview, two lines at most, cut at the start so the end of
/// what is being said stays visible.
struct TBDLivePartialBubble: View {
    let text: String
    var size = TBDPreviewTextSize.medium
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Text(text)
            .font(TBDFonts.nunito(size.fontSize, TBDKit.weightBody))
            .lineSpacing(size.lineSpacing)
            .foregroundStyle(TBDColor.overlayOn.opacity(0.92))
            .lineLimit(2)
            .truncationMode(.head)
            .multilineTextAlignment(.center)
            .padding(.horizontal, TBDTokens.Space.md)
            .padding(.vertical, TBDTokens.Space.sm)
            .frame(maxWidth: 420)
            .background(TBDColor.overlayFill.opacity(0.92), in: TBDBrickShape())
            .overlay(TBDBrickShape().strokeBorder(TBDColor.overlayOn.opacity(0.14), lineWidth: TBDKit.hair))
            .animation(TBDMotion.animation(TBDMotion.instant, reduce: reduceMotion), value: text)
            .accessibilityLabel("Live transcript: \(text)")
    }
}

/// Level bars that ease towards the latest values; the single animation style for all recording UI.
struct TBDLevelBars: View {
    let levels: [Float]
    var color: Color = TBDColor.teal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule().fill(color.opacity(0.85))
                        .frame(height: max(3, CGFloat(min(1, level)) * geometry.size.height))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(TBDMotion.animation(TBDMotion.instant, reduce: reduceMotion), value: levels)
        }
    }
}

enum TBDPillClock {
    static func text(_ ms: Int) -> String { String(format: "%d:%02d", ms / 60_000, ms / 1000 % 60) }
}
