import SwiftUI

// Brick primitives (C125/C126): you act, commit or read content in a BRICK (one 6pt radius).
// Every state is a token pair (fill + on-fill, C128) from TBDColor; values are generated from the toolkit tokens.

/// Forced visual state for specimen sheets and the screenshot/contrast check only (like the kit's `.is-hover`).
public enum TBDControlState: Sendable { case normal, hover, pressed, focus }

private struct TBDForcedStateKey: EnvironmentKey { static let defaultValue: TBDControlState? = nil }
public extension EnvironmentValues {
    var tbdForcedState: TBDControlState? {
        get { self[TBDForcedStateKey.self] }
        set { self[TBDForcedStateKey.self] = newValue }
    }
}

/// The brick shape. Use this, never a literal corner radius.
public struct TBDBrickShape: InsettableShape {
    var inset: CGFloat = 0
    public init() {}
    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return RoundedRectangle(cornerRadius: max(0, TBDKit.radiusBrick - inset), style: .continuous).path(in: r)
    }
    public func inset(by amount: CGFloat) -> TBDBrickShape { var s = self; s.inset += amount; return s }
}

public extension View {
    /// The one focus ring: 3pt teal-ink, `offset` outside the shape (kit --tb-focus-*).
    func tbdFocusRing(_ visible: Bool, offset: CGFloat = TBDKit.focusOffset, pill: Bool = false) -> some View {
        overlay {
            if visible {
                let grow = offset + TBDKit.focusWidth / 2
                Group {
                    if pill { TBDPillEdge(TBDKit.focusWidth).fill(TBDColor.focus, style: FillStyle(eoFill: true)).padding(-TBDKit.focusWidth / 2) }
                    else { RoundedRectangle(cornerRadius: TBDKit.radiusBrick + grow, style: .continuous).stroke(TBDColor.focus, lineWidth: TBDKit.focusWidth) }
                }
                .padding(-grow)
                .allowsHitTesting(false)
            }
        }
    }
}

public enum TBDButtonRole: Sendable { case primary, secondary, quiet, destructive, destructiveConfirm, icon }
public enum TBDButtonSize: Sendable { case regular, large }

/// Brick button: primary (ink, teal-deep hover), secondary (ink ring), quiet (line-strong ring), destructive
/// (brick ring; `.destructiveConfirm` fills brick red for the confirm step) and icon (square). Label centred.
public struct TBDButtonStyle: ButtonStyle {
    let role: TBDButtonRole
    let size: TBDButtonSize
    public init(_ role: TBDButtonRole = .secondary, size: TBDButtonSize = .regular) { self.role = role; self.size = size }
    public func makeBody(configuration: Configuration) -> some View {
        TBDButtonBody(role: role, size: size, configuration: configuration)
    }
}

/// Fill, on-fill and edge of one control state.
public struct TBDPair: Sendable {
    public let fill: Color
    public let on: Color
    public let edge: Color?
    public init(_ fill: Color, _ on: Color, _ edge: Color? = nil) { self.fill = fill; self.on = on; self.edge = edge }
}

public extension TBDButtonRole {
    /// The token pair for a state of this role (the same pairs as the web kit's .tb-btn).
    func pair(_ state: TBDControlState, enabled: Bool = true) -> TBDPair {
        guard enabled else { return TBDPair(TBDColor.disabledFill, TBDColor.disabledOn) }
        let hover = state == .hover, pressed = state == .pressed
        switch self {
        case .primary:
            return pressed ? TBDPair(TBDColor.primaryActiveFill, TBDColor.primaryActiveOn)
                : hover ? TBDPair(TBDColor.primaryHoverFill, TBDColor.primaryHoverOn) : TBDPair(TBDColor.primaryFill, TBDColor.primaryOn)
        case .secondary:
            return pressed ? TBDPair(TBDColor.secondaryActiveFill, TBDColor.secondaryActiveOn, TBDColor.secondaryEdge)
                : hover ? TBDPair(TBDColor.secondaryHoverFill, TBDColor.secondaryHoverOn, TBDColor.secondaryEdge)
                : TBDPair(TBDColor.secondaryFill, TBDColor.secondaryOn, TBDColor.secondaryEdge)
        case .quiet, .icon:
            return pressed ? TBDPair(TBDColor.quietActiveFill, TBDColor.quietActiveOn, TBDColor.quietEdge)
                : hover ? TBDPair(TBDColor.quietHoverFill, TBDColor.quietHoverOn, TBDColor.quietEdge)
                : TBDPair(TBDColor.quietFill, self == .icon ? TBDColor.secondaryOn : TBDColor.quietOn, TBDColor.quietEdge)
        case .destructive:
            return hover || pressed ? TBDPair(TBDColor.dangerHoverFill, TBDColor.dangerHoverOn, TBDColor.dangerEdge)
                : TBDPair(TBDColor.dangerFill, TBDColor.dangerOn, TBDColor.dangerEdge)
        case .destructiveConfirm:
            return hover || pressed ? TBDPair(TBDColor.dangerConfirmHoverFill, TBDColor.dangerConfirmHoverOn)
                : TBDPair(TBDColor.dangerConfirmFill, TBDColor.dangerConfirmOn)
        }
    }
}

private struct TBDButtonBody: View {
    let role: TBDButtonRole
    let size: TBDButtonSize
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.tbdForcedState) private var forced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var state: TBDControlState {
        if let forced { return forced }
        return configuration.isPressed ? .pressed : hovered ? .hover : .normal
    }
    var body: some View {
        let pair = role.pair(state == .focus ? .normal : state, enabled: enabled)
        let height = size == .large ? TBDTokens.Control.largeHeight : TBDTokens.Control.minHeight
        configuration.label
            .font(TBDTokens.Typography.control)
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, role == .icon ? 0 : size == .large ? TBDKit.controlPad : TBDTokens.Control.paddingX)
            .frame(minWidth: role == .icon ? height : nil, minHeight: height)
            .foregroundStyle(pair.on)
            .background(pair.fill, in: TBDBrickShape())
            .overlay { if let edge = pair.edge, enabled { TBDBrickShape().strokeBorder(edge, lineWidth: TBDKit.hair) } }
            .contentShape(TBDBrickShape())
            .offset(y: state == .pressed && enabled ? 1 : 0)
            .tbdFocusRing(enabled && (focused || state == .focus))
            .onHover { hovered = $0 }
            .animation(TBDMotion.animation(TBDMotion.color, reduce: reduceMotion), value: state)
    }
}

public extension View {
    /// Card: tile, brick, 1.5pt line ring, flat (padding 20 = --tb-s5).
    func tbdCard(padding: CGFloat = TBDKit.s5) -> some View {
        self.padding(padding)
            .background(TBDColor.tile, in: TBDBrickShape())
            .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
    }
    /// Tinted panel: teal wash with its wash-line ring. At most one per screen.
    func tbdPanelTint(padding: CGFloat = TBDKit.s6) -> some View {
        self.padding(padding)
            .background(TBDColor.tealWash, in: TBDBrickShape())
            .overlay(TBDBrickShape().strokeBorder(TBDColor.tealWashLine, lineWidth: TBDKit.hair))
    }
    /// Floating surfaces only (menus, popovers, toasts, sheets): tile, brick, hair ring and the ONE float shadow.
    /// The argument is ignored (the hard offset shadows are gone, One Lift Rule); kept for existing call sites.
    func tbdFloating(_ shadow: TBDTokens.HardShadow = TBDTokens.Shadow.brickMd) -> some View {
        self.background(TBDColor.tile, in: TBDBrickShape())
            .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
            .shadow(color: TBDColor.shadowInk, radius: TBDKit.floatShadowRadius, y: TBDKit.floatShadowY)
    }
    /// Field chrome for an existing TextField/SecureField/Picker: tile, brick, line-strong ring; focus = the focus ring.
    func tbdField(focused: Bool = false, invalid: Bool = false) -> some View {
        self.textFieldStyle(.plain)
            .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightBody))
            .foregroundStyle(TBDColor.fieldOn)
            .padding(.horizontal, TBDTokens.Control.paddingX).frame(minHeight: TBDTokens.Control.minHeight)
            .background(TBDColor.fieldFill, in: TBDBrickShape())
            .overlay(TBDBrickShape().strokeBorder(invalid ? TBDColor.fieldInvalidEdge : TBDColor.fieldEdge, lineWidth: invalid ? 2 : TBDKit.hair))
            .tbdFocusRing(focused, offset: TBDKit.focusOffsetTight)
    }
}

/// Small sentence-case label (13/800, muted). No uppercase, no mono (kit rule 8).
public struct TBDLabel: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(TBDTokens.Typography.label)
            .foregroundStyle(TBDColor.muted)
    }
}

/// Kicker: the one swatch label that opens a page, dialog or card (iso swatch + 15/800 teal-ink).
public struct TBDKicker: View {
    let text: String
    let tone: Color
    public init(_ text: String, tone: Color = TBDColor.teal) { self.text = text; self.tone = tone }
    public var body: some View {
        HStack(spacing: 10) {
            TBDSwatch(tone: tone).frame(width: 18, height: 12)
            Text(text).font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightLabel)).foregroundStyle(TBDColor.tealInk)
        }
    }
}

/// The iso brick swatch (2pt corner, 2pt ink outline, skewed -12°): marks material, never decoration.
public struct TBDSwatch: View {
    let tone: Color
    let open: Bool
    public init(tone: Color = TBDColor.teal, open: Bool = false) { self.tone = tone; self.open = open }
    public var body: some View {
        RoundedRectangle(cornerRadius: TBDKit.radiusSwatch)
            .fill(open ? Color.clear : tone)
            .overlay(RoundedRectangle(cornerRadius: TBDKit.radiusSwatch).strokeBorder(open ? TBDColor.muted : TBDColor.ink, style: StrokeStyle(lineWidth: 2, dash: open ? [3, 2] : [])))
            .transformEffect(CGAffineTransform(a: 1, b: tan(-12 * .pi / 180), c: 0, d: 1, tx: 0, ty: 0))
            .accessibilityHidden(true)
    }
}

/// Page header: optional kicker, 26/900 title, 1.5pt ink rule below (a sequence starts under the ink rule).
public struct TBDPageHeader<Trailing: View>: View {
    let label: String?
    let title: String
    let trailing: Trailing
    public init(_ title: String, label: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.label = label; self.trailing = trailing()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: TBDKit.s2) {
            if let label { TBDKicker(label) }
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(TBDTokens.Typography.display)
                    .tracking(TBDTokens.Typography.displayTracking)
                    .foregroundStyle(TBDColor.ink)
                Spacer(minLength: TBDKit.s4)
                trailing
            }
            Rectangle().fill(TBDColor.ink).frame(height: TBDKit.hair)
        }
    }
}

/// Ruled settings row: title and help on the left, control on the right, hairline below.
public struct TBDSettingsRow<Control: View>: View {
    let title: String
    let help: String?
    let control: Control
    public init(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.help = help; self.control = control()
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: TBDKit.s5) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                    if let help { Text(help).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: TBDKit.s4)
                control
            }
            .padding(.vertical, TBDKit.s3)
            Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
        }
    }
}

/// Rail selection: a soft brick in teal wash (the AppShell nav item shape).
public struct TBDRailSelection: View {
    public init() {}
    public var body: some View {
        TBDBrickShape().fill(TBDColor.tealWash)
            .overlay(TBDBrickShape().strokeBorder(TBDColor.tealWashLine, lineWidth: TBDKit.hair))
    }
}
