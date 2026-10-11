import TBDDesign
import SwiftUI

struct WeeklyHeader: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter
  let title: String
  let canNavigateForward: Bool
  let onPrevious: () -> Void
  let onNext: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      WeeklyNavigationButton(assetName: "LeftArrow") {
        onPrevious()
      }

      // Brick: this range title is the Weekly screen's top-level page title, so it
      // takes the serif display voice (docs/design-language.md).
      Text(title)
        .font(.custom("Georgia", size: stylePreviewAfter ? 28 : 20))
        .tracking(TBDTokens.Typography.displayTracking)
        .foregroundStyle(stylePreviewAfter && theme.isDark ? Color.white : Color.black)
        .multilineTextAlignment(.center)
        .frame(width: stylePreviewAfter ? 448 : 344)

      WeeklyNavigationButton(assetName: "RightArrow", isEnabled: canNavigateForward) {
        onNext()
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: stylePreviewAfter ? 34 : 29)
  }
}

private struct WeeklyNavigationButton: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter
  let assetName: String
  var isEnabled = true
  let action: () -> Void

  @State private var isHovering = false

  private let arrowSize: CGFloat = 24
  // Brick: square hover mark, not a rounded pill highlight.
  private let hoverBoxSize: CGFloat = 30

  var body: some View {
    Button {
      guard isEnabled else { return }
      action()
    } label: {
      ZStack {
        RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
          .fill(TBDTokens.hover)
          .frame(width: hoverBoxSize, height: hoverBoxSize)
          .opacity(isHovering && isEnabled ? 1 : 0)

        Image(assetName)
          .resizable()
          .renderingMode(stylePreviewAfter && theme.isDark ? .template : .original)
          .scaledToFit()
          .foregroundStyle(.white)
          .frame(width: arrowSize, height: arrowSize)
          .opacity(isEnabled ? 1 : 0.35)
      }
      .frame(width: hoverBoxSize, height: hoverBoxSize)
      .contentShape(Rectangle())
    }
    .buttonStyle(TBDButtonStyle(.quiet))
    .frame(width: hoverBoxSize, height: hoverBoxSize)
    .disabled(!isEnabled)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = isEnabled && hovering
      }
    }
    .onChange(of: isEnabled) { _, enabled in
      if !enabled {
        isHovering = false
      }
    }
    .pointingHandCursorOnHover(enabled: isEnabled, reassertOnPressEnd: true)
  }
}
