import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// The small pill parked on the chosen screen edge while nothing records (the "Show dictation pill at all times"
/// setting, v1 idle pill). It grows on hover and a click starts dictating. Only the visible pill takes mouse
/// events; the rest of its panel lets clicks through to the app below.
@MainActor
final class TBDIdlePill {
    private static let panelSize = NSSize(width: 350, height: 90)
    /// Hover and click zones hug the anchored edge (v1: the 48x10 nub plus slack, and the grown pill with its tip).
    static let collapsedZone = NSSize(width: 60, height: 24)
    static let expandedZone = NSSize(width: 320, height: 80)

    private let model = TBDIdlePillModel()
    private var panel: NSPanel?
    private var tracker: TBDIdleTrackingView?
    var onClick: (() -> Void)?

    func show(placement: TBDOverlayPlacement, hotkeyName: String?) {
        model.anchorsToTop = placement.anchorsToTop
        model.hotkeyName = hotkeyName
        let panel = self.panel ?? makePanel()
        self.panel = panel
        tracker?.anchorsToTop = placement.anchorsToTop
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let usable = TBDDictationOverlayLayout.usableFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                                           topInset: max(NSStatusBar.system.thickness, screen.safeAreaInsets.top))
        panel.setFrameOrigin(TBDDictationOverlayLayout.origin(in: usable, panelSize: Self.panelSize, placement: placement))
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        model.isHovered = false
        tracker?.reset()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let container = TBDIdleTrackingView(frame: NSRect(origin: .zero, size: Self.panelSize))
        let hosting = NSHostingView(rootView: TBDIdlePillView(model: model))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.onHover = { [weak self] hovered in self?.model.isHovered = hovered }
        container.onClick = { [weak self] in self?.onClick?() }
        tracker = container
        panel.contentView = container
        return panel
    }
}

@MainActor
final class TBDIdlePillModel: ObservableObject {
    @Published var isHovered = false
    @Published var anchorsToTop = false
    @Published var hotkeyName: String?
}

/// Receives hover and clicks only inside the pill's zone.
final class TBDIdleTrackingView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var anchorsToTop = false
    private var inside = false

    func reset() { inside = false }

    private var zone: NSRect {
        let size = inside ? TBDIdlePill.expandedZone : TBDIdlePill.collapsedZone
        return NSRect(x: (bounds.width - size.width) / 2, y: anchorsToTop ? bounds.height - size.height : 0, width: size.width, height: size.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let now = zone.contains(convert(event.locationInWindow, from: nil))
        if now != inside { inside = now; onHover?(now) }
    }

    override func mouseExited(with event: NSEvent) {
        if inside { inside = false; onHover?(false) }
    }

    override func mouseDown(with event: NSEvent) {
        if zone.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { zone.contains(convert(point, from: superview)) ? self : nil }
}

struct TBDIdlePillView: View {
    @ObservedObject var model: TBDIdlePillModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            if model.anchorsToTop { pill; tip } else { tip; pill }
        }
        .padding(model.anchorsToTop ? .top : .bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.anchorsToTop ? .top : .bottom)
        .allowsHitTesting(false)
    }

    private var pill: some View {
        Capsule()
            .fill(TBDColor.overlayFill.opacity(model.isHovered ? 1 : 0.9))
            .tbdPillEdge(TBDColor.overlayOn.opacity(model.isHovered ? 0.3 : 0.15))
            .frame(width: model.isHovered ? 148 : 48, height: model.isHovered ? 30 : 10)
            .overlay {
                if model.isHovered {
                    HStack(spacing: 4) { ForEach(0..<12, id: \.self) { _ in Circle().fill(TBDColor.overlayOn.opacity(0.25)).frame(width: 3, height: 3) } }
                }
            }
            .animation(TBDMotion.animation(TBDMotion.spring, reduce: reduceMotion), value: model.isHovered)
    }

    private var tip: some View {
        Text(model.hotkeyName.map { "Click, or hold \($0) to dictate" } ?? "Click to start dictating")
            .font(TBDTokens.Typography.label)
            .foregroundStyle(TBDColor.overlayOn.opacity(0.9))
            .padding(.horizontal, TBDKit.s4).padding(.vertical, TBDKit.s2)
            .background(TBDColor.overlayFill, in: TBDBrickShape())
            .opacity(model.isHovered ? 1 : 0)
            .scaleEffect(model.isHovered ? 1 : 0.9)
            .animation(TBDMotion.animation(TBDMotion.quick, reduce: reduceMotion), value: model.isHovered)
    }
}
