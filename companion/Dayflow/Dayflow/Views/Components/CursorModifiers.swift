import SwiftUI

#if os(macOS)

  struct DayflowPressScaleButtonStyle: ButtonStyle {
    let enabled: Bool
    let pressedScale: CGFloat
    let animation: Animation

    init(
      enabled: Bool = true,
      pressedScale: CGFloat = 0.97,
      animation: Animation = .spring(response: 0.24, dampingFraction: 0.82)
    ) {
      self.enabled = enabled
      self.pressedScale = pressedScale
      self.animation = animation
    }

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        // Brick: presses seat the control instead of shrinking it.
        .opacity(configuration.isPressed && enabled ? 0.8 : 1)
    }
  }

  private struct HoverScaleModifier: ViewModifier {
    let enabled: Bool
    let scale: CGFloat
    let animation: Animation
    @State private var isHovering = false

    func body(content: Content) -> some View {
      content
        .scaleEffect(isHovering ? scale : 1)
        .animation(animation, value: isHovering)
        .onHover { hovering in
          isHovering = enabled ? hovering : false
        }
        .onChange(of: enabled) { _, isEnabled in
          if !isEnabled {
            isHovering = false
          }
        }
    }
  }

  extension View {
    // Uses native SwiftUI pointer style on macOS 15+.
    // For macOS 14, this is intentionally a no-op.
    @ViewBuilder
    func pointingHandCursor(enabled: Bool = true) -> some View {
      if enabled {
        if #available(macOS 15.0, *) {
          self.pointerStyle(.link)
        } else {
          self
        }
      } else {
        self
      }
    }

    // Kept for API compatibility with existing call sites.
    func pointingHandCursorOnHover(enabled: Bool = true, reassertOnPressEnd: Bool = false)
      -> some View
    {
      _ = reassertOnPressEnd
      return pointingHandCursor(enabled: enabled)
    }

    func hoverScaleEffect(
      enabled: Bool = true,
      scale: CGFloat = 1.02,
      animation: Animation = .spring(response: 0.24, dampingFraction: 0.82)
    ) -> some View {
      // Brick: no scale bounce on hover (TBD/docs/design-language.md).
      modifier(HoverScaleModifier(enabled: false, scale: 1, animation: animation))
    }

    func dayflowPressScale(
      _ isPressed: Bool,
      enabled: Bool = true,
      pressedScale: CGFloat = 0.97,
      animation: Animation = .spring(response: 0.24, dampingFraction: 0.82)
    ) -> some View {
      scaleEffect(enabled && isPressed ? pressedScale : 1)
        .animation(animation, value: isPressed)
    }

    func pointingHandCursorWithHoverScale(
      enabled: Bool = true,
      scale: CGFloat = 1.01,
      animation: Animation = .spring(response: 0.24, dampingFraction: 0.82),
      reassertOnPressEnd: Bool = true
    ) -> some View {
      _ = reassertOnPressEnd
      return hoverScaleEffect(enabled: enabled, scale: scale, animation: animation)
        .pointingHandCursor(enabled: enabled)
    }
  }
#endif
