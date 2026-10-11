import SwiftUI

// Brick primitives. Spec: TBD/docs/design-language.md. Values come from TBDTokens only.

public enum TBDButtonRole: Sendable { case primary, secondary, quiet, destructive, icon }

/// Square brick button. Hover lifts it onto a hard offset shadow; press seats it.
public struct TBDButtonStyle: ButtonStyle {
    let role: TBDButtonRole
    public init(_ role: TBDButtonRole = .secondary) { self.role = role }
    public func makeBody(configuration: Configuration) -> some View {
        TBDButtonBody(role: role, configuration: configuration)
    }
}

private struct TBDButtonBody: View {
    let role: TBDButtonRole
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        let lifted = enabled && hovered && !configuration.isPressed && role != .quiet && role != .icon
        let shadow = TBDTokens.Shadow.brickSm
        configuration.label
            .font(TBDTokens.Typography.control)
            .lineLimit(1)
            .padding(.horizontal, role == .icon ? 0 : TBDTokens.Control.paddingX)
            .frame(minWidth: role == .icon ? 32 : nil, minHeight: role == .icon ? 32 : TBDTokens.Control.minHeight)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(borderColor, lineWidth: TBDTokens.Stroke.hairline))
            .underline(role == .quiet && hovered && enabled)
            .background(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).fill(TBDTokens.ink.opacity(lifted ? shadow.opacity * 2 : 0)).offset(x: shadow.x, y: shadow.y))
            .offset(x: lifted ? -1 : 0, y: lifted ? -1 : 0)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.08), value: lifted)
    }
    private var foreground: Color {
        switch role {
        case .primary: TBDTokens.onPrimary
        case .destructive: TBDTokens.alert
        case .secondary, .quiet, .icon: TBDTokens.ink
        }
    }
    private var background: Color {
        switch role {
        case .primary: TBDTokens.fill
        case .secondary, .destructive: TBDTokens.paper
        case .quiet: .clear
        case .icon: hovered || configuration.isPressed ? TBDTokens.hover : .clear
        }
    }
    private var borderColor: Color {
        switch role {
        case .primary: TBDTokens.fill
        case .destructive: TBDTokens.alert
        case .secondary: TBDTokens.border
        case .quiet: .clear
        case .icon: hovered && enabled ? TBDTokens.border : .clear
        }
    }
}

public extension View {
    /// Flat ruled surface for cards and sections. No shadow: flat content never floats.
    func tbdCard(padding: CGFloat = TBDTokens.Space.lg) -> some View {
        self.padding(padding)
            .background(TBDTokens.paper)
            .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline))
    }
    /// Hard zero-blur offset shadow for menus, popovers, modals and the composer.
    func tbdFloating(_ shadow: TBDTokens.HardShadow = TBDTokens.Shadow.brickMd) -> some View {
        self.background(TBDTokens.paper)
            .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline))
            .background(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).fill(TBDTokens.ink.opacity(shadow.opacity)).offset(x: shadow.x, y: shadow.y))
    }
    /// Square field chrome for text fields and pickers.
    func tbdField(focused: Bool = false) -> some View {
        self.textFieldStyle(.plain)
            .font(TBDTokens.Typography.body)
            .padding(.horizontal, 10).frame(minHeight: TBDTokens.Control.minHeight)
            .background(TBDTokens.paper)
            .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(focused ? TBDTokens.accent : TBDTokens.border, lineWidth: focused ? TBDTokens.Stroke.bar : TBDTokens.Stroke.hairline))
    }
}

/// Small uppercase mono label for sections and metadata.
public struct TBDLabel: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(TBDTokens.Typography.label)
            .tracking(TBDTokens.Typography.labelTracking)
            .foregroundStyle(TBDTokens.muted)
    }
}

/// Editorial page header: optional mono section label, serif display title, rule below.
public struct TBDPageHeader<Trailing: View>: View {
    let label: String?
    let title: String
    let trailing: Trailing
    public init(_ title: String, label: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.label = label; self.trailing = trailing()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            if let label { TBDLabel(label) }
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(TBDTokens.Typography.display)
                    .tracking(TBDTokens.Typography.displayTracking)
                    .foregroundStyle(TBDTokens.ink)
                Spacer(minLength: TBDTokens.Space.lg)
                trailing
            }
            RoundedRectangle(cornerRadius: TBDTokens.Radius.base).fill(TBDTokens.border).frame(height: TBDTokens.Stroke.hairline)
        }
    }
}

/// Ruled settings row: label and help on the left, control on the right, divider below.
public struct TBDSettingsRow<Control: View>: View {
    let title: String
    let help: String?
    let control: Control
    public init(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.help = help; self.control = control()
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: TBDTokens.Space.xl) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(TBDTokens.Typography.control).foregroundStyle(TBDTokens.ink)
                    if let help { Text(help).font(.custom("Switzer", size: 12)).foregroundStyle(TBDTokens.muted).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: TBDTokens.Space.lg)
                control
            }
            .padding(.vertical, TBDTokens.Space.md)
            RoundedRectangle(cornerRadius: TBDTokens.Radius.base).fill(TBDTokens.border).frame(height: TBDTokens.Stroke.hairline)
        }
    }
}

/// Square status chip with a 6pt square marker.
public struct TBDChip: View {
    let text: String
    let color: Color
    public init(_ text: String, color: Color = TBDTokens.accent) { self.text = text; self.color = color }
    public var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: TBDTokens.Radius.base).fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(TBDTokens.ink)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.xs).strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline))
    }
}

/// Soft rail selection (operator correction 2026-09-27): gentle rounded tint with a
/// short, low-contrast accent marker — never a harsh full-height ink bar.
public struct TBDRailSelection: View {
    public init() {}
    public var body: some View {
        RoundedRectangle(cornerRadius: TBDTokens.Radius.sm + 4, style: .continuous)
            .fill(TBDTokens.selected.opacity(0.85))
            .overlay(alignment: .leading) {
                Capsule().fill(TBDTokens.accent.opacity(0.55)).frame(width: 3, height: 14).offset(x: -1.5)
            }
    }
}
