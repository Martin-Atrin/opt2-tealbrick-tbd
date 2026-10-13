import SwiftUI

/// Native counterparts of Companion's SidebarMetrics and DayflowTheme.
public enum TBDRailMetrics {
    public static let width: CGFloat = 80
    public static let topInset: CGFloat = 15
    public static let row: CGFloat = 62
    public static let gap: CGFloat = 5.25
    public static let iconBox: CGFloat = 37
    public static let icon: CGFloat = 18
    public static let label: CGFloat = 12
}

public enum TBDDesign {
    // Recording overlays keep a dark surface in both appearances so white source/status
    // indicators remain readable over arbitrary desktop content.
    public static var recordingSurface: Color { TBDColor.overlayFill }
    public static let sidebarWidth: CGFloat = TBDRailMetrics.width
    public static var canvas: Color { TBDTokens.canvas }
    public static var paper: Color { TBDTokens.paper }
    public static let sidebar = Color.clear
    public static var ink: Color { TBDTokens.ink }
    public static var muted: Color { TBDTokens.muted }
    public static var border: Color { TBDTokens.border }
    public static var selected: Color { TBDTokens.selected }
    public static var hover: Color { TBDTokens.hover }
    public static var onPrimary: Color { TBDTokens.onPrimary }
    public static var primaryFill: Color { TBDTokens.fill }

}

public struct TBDRailHeader: View {
    let title: String
    public init(_ title: String) { self.title = title }
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tealbrick").font(TBDFonts.nunito(TBDKit.textH2, TBDKit.weightHead)).tracking(TBDTokens.Typography.displayTracking)
            Rectangle().fill(TBDColor.ink).frame(height: TBDKit.hair)
            Text(title).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
        }
        .foregroundStyle(TBDDesign.ink)
        .padding(.horizontal, 18).padding(.top, 26).padding(.bottom, 14)
    }
}

public struct TBDRailRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let badge: Bool
    let action: () -> Void
    public init(_ title: String, symbol: String, selected: Bool, badge: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.selected = selected; self.badge = badge; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .resizable()
                        .scaledToFit()
                        .frame(width: TBDRailMetrics.icon, height: TBDRailMetrics.icon)
                        .frame(width: TBDRailMetrics.iconBox, height: TBDRailMetrics.iconBox)
                        .background { if selected { TBDRailSelection() } }
                    if badge { Capsule().fill(TBDColor.countFill).frame(width: 8, height: 8).tbdPillEdge(TBDColor.paper) }
                }
                Text(title).font(TBDFonts.nunito(TBDRailMetrics.label, selected ? TBDKit.weightLabel : TBDKit.weightNav)).lineLimit(1).minimumScaleFactor(0.65)
            }
            .frame(width: TBDRailMetrics.row, height: TBDRailMetrics.row).contentShape(Rectangle())
        }
        .foregroundStyle(selected ? TBDColor.tealInk : TBDColor.muted)
        .buttonStyle(.plain)
        .help(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct TBDRailButtonStyle: ButtonStyle {
    let selected: Bool
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(TBDDesign.ink)
            .background(selected ? TBDDesign.selected : hovered || configuration.isPressed ? TBDDesign.hover : .clear, in: TBDBrickShape())
            .onHover { hovered = $0 }
    }
}

public struct TBDActionStyle: ButtonStyle {
    let prominent: Bool
    let destructive: Bool
    let subtle: Bool
    public init(prominent: Bool = false, destructive: Bool = false, subtle: Bool = false) {
        self.prominent = prominent; self.destructive = destructive; self.subtle = subtle
    }
    /// Kept for existing call sites; renders the brick button.
    public func makeBody(configuration: Configuration) -> some View {
        TBDButtonStyle(destructive ? .destructive : prominent ? .primary : subtle ? .quiet : .secondary).makeBody(configuration: configuration)
    }
}
