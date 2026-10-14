import SwiftUI
import TBDDesign

// Figma: 20pt circle, 0.75pt border, soft inner glow, 12pt pencil.
struct CategoryEditCircleButton: View {
  @Environment(\.dayflowTheme) private var theme

  let action: () -> Void
  var diameter: CGFloat = 20
  var iconSize: CGFloat? = nil
  var accessibilityLabel: String = String(localized: "Edit categories")

  var body: some View {
    let resolvedIconSize = iconSize ?? diameter * 0.6

    Button(action: action) {
      // Kit: an action is a brick (C125); ink glyph on the tile with a line-strong edge (the earlier white glyph on
      // a light fill was invisible). The visual stays 20pt so fixed layouts keep their places; the hit area is 36pt.
      Image("CategoryEditButton")
        .resizable()
        .renderingMode(.template)
        .scaledToFit()
        .foregroundColor(TBDColor.ink)
        .frame(width: resolvedIconSize, height: resolvedIconSize)
        .frame(width: diameter, height: diameter)
        .background(TBDColor.tile, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(TBDColor.lineStrong, lineWidth: TBDKit.hair))
        .padding(8).contentShape(Rectangle()).padding(-8)
    }
    .buttonStyle(DayflowPressScaleButtonStyle(pressedScale: 0.97))
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .accessibilityLabel(accessibilityLabel)
  }
}
