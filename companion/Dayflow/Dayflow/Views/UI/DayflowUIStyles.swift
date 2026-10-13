//
//  DayflowUIStyles.swift
//  Dayflow
//
//  Reusable styling components for the new UI
//

import SwiftUI
import TBDDesign

extension View {
  /// Brick surface: tile fill and a hairline ring on the 6pt brick.
  /// `cornerRadius` is kept for source compatibility and ignored.
  func dayflowStyle(
    cornerRadius: CGFloat = 0,
    backgroundColor: Color? = nil
  ) -> some View {
    self
      .background(backgroundColor ?? TBDColor.tile, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }

  /// Brick icon surface: tile fill and a hairline ring on the 6pt brick.
  func dayflowCircleStyle(backgroundColor: Color? = nil) -> some View {
    self
      .background(backgroundColor ?? TBDColor.tile, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }
}

/// Icon button on the kit's icon style (36pt brick). `pressedScale` and `pressAnimation`
/// are kept for source compatibility; the kit style owns the press feedback.
struct DayflowCircleButton<Content: View>: View {
  let action: () -> Void
  let size: CGSize
  let pressedScale: CGFloat
  let pressAnimation: Animation
  @ViewBuilder let content: () -> Content

  init(
    width: CGFloat = 31.40301,
    height: CGFloat = 30.4514,
    pressedScale: CGFloat = 0.97,
    pressAnimation: Animation = TBDMotion.spring,
    action: @escaping () -> Void,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.size = CGSize(width: width, height: height)
    self.pressedScale = pressedScale
    self.pressAnimation = pressAnimation
    self.action = action
    self.content = content
  }

  var body: some View {
    Button(action: action) {
      content()
        .frame(minWidth: max(size.width, 36), minHeight: max(size.height, 36))
        .contentShape(Rectangle())
    }
    .buttonStyle(TBDButtonStyle(.icon))
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }
}

struct DayflowPillButton: View {
  let text: String
  let font: Font
  let foregroundColor: Color
  let horizontalPadding: CGFloat
  let height: CGFloat
  let fixedWidth: CGFloat?

  init(
    text: String,
    font: Font = TBDFonts.nunito(TBDKit.textLede, TBDKit.weightNav),
    foregroundColor: Color = TBDColor.ink,
    horizontalPadding: CGFloat = 11.77829,
    height: CGFloat = 30.4514,
    fixedWidth: CGFloat? = nil
  ) {
    self.text = text
    self.font = font
    self.foregroundColor = foregroundColor
    self.horizontalPadding = horizontalPadding
    self.height = height
    self.fixedWidth = fixedWidth
  }

  var body: some View {
    Text(text)
      .font(font)
      .foregroundStyle(foregroundColor)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .if(fixedWidth != nil) { view in
        view.frame(width: fixedWidth!, height: height)
      }
      .if(fixedWidth == nil) { view in
        view.padding(.horizontal, horizontalPadding)
          .frame(height: height)
      }
      .dayflowStyle()
  }
}
