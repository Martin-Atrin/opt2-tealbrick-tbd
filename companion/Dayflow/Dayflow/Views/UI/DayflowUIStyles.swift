//
//  DayflowUIStyles.swift
//  Dayflow
//
//  Reusable styling components for the new UI
//

import SwiftUI
import TBDDesign

extension View {
  /// Brick surface (TBD/docs/design-language.md): square with a 1pt rule.
  /// `cornerRadius` is kept for source compatibility and ignored.
  func dayflowStyle(
    cornerRadius: CGFloat = 0,
    backgroundColor: Color = .white
  ) -> some View {
    self
      .background(backgroundColor == .white ? TBDTokens.paper : backgroundColor)
      .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline))
  }

  /// Brick icon surface: square with a 1pt rule (was a circle).
  func dayflowCircleStyle(backgroundColor: Color = .white) -> some View {
    self
      .background(backgroundColor == .white ? TBDTokens.paper : backgroundColor)
      .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline))
  }
}

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
      ZStack {
        RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
          .fill(TBDTokens.paper)
          .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline))

        content()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: size.width, height: size.height)
      .contentShape(Rectangle())
    }
    .buttonStyle(
      DayflowPressScaleButtonStyle(pressedScale: pressedScale, animation: pressAnimation)
    )
    .contentShape(Rectangle())
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
    font: Font = .custom("Switzer-Medium", size: 18),
    foregroundColor: Color = Color(red: 0.2, green: 0.2, blue: 0.2),
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
      .foregroundColor(foregroundColor)
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
