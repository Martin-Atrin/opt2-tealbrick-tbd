//
//  DayflowSurfaceButton.swift
//  Dayflow
//
//  Generic content button with unified Emil‑style hover/press interactions
//

import SwiftUI
import TBDDesign

struct DayflowSurfaceButton<Content: View>: View {
  let action: () -> Void
  @ViewBuilder let content: () -> Content

  var background: Color = .white
  var foreground: Color = .black
  var borderColor: Color = .black.opacity(0.15)
  var cornerRadius: CGFloat = 0
  var horizontalPadding: CGFloat = 18
  var verticalPadding: CGFloat = 12
  var minWidth: CGFloat? = nil
  var fixedHeight: CGFloat? = nil  // Fixed button height (vertical padding still applies to content)
  var showShadow: Bool = true
  var showOverlayStroke: Bool = false  // New parameter for white overlay stroke
  var isSecondaryStyle: Bool = false  // New parameter for white/secondary buttons
  var innerGlowColor: Color? = nil  // Soft inset glow (Figma "inset box-shadow")

  @State private var isHovered = false
  @State private var isPressed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let hoverAnim = TBDMotion.spring
  private let pressAnim = TBDMotion.spring

  var body: some View {
    Button(action: {
      withAnimation(pressAnim) { isPressed = true }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        withAnimation(pressAnim) { isPressed = false }
        action()
      }
    }) {
      HStack(spacing: 10) {
        content()
          .foregroundColor(foreground.opacity(0.85))
      }
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .frame(minWidth: minWidth)
      .frame(height: fixedHeight)
      // Brick (TBD/docs/design-language.md): square regardless of `cornerRadius`,
      // 1pt rule, hover lifts onto a hard offset shadow, press seats it. No glow or blur.
      .background(background)
      .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(isSecondaryStyle ? TBDTokens.ink : (isHovered ? borderColor.opacity(1) : borderColor), lineWidth: TBDTokens.Stroke.hairline))
      .background(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).fill(TBDTokens.ink.opacity(showShadow && isHovered && !isPressed ? 0.18 : 0)).offset(x: 3, y: 3))
      .offset(x: reduceMotion || isPressed ? 0 : (isHovered ? -1 : 0), y: reduceMotion || isPressed ? 0 : (isHovered ? -1 : 0))
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(hoverAnim) { isHovered = hovering }
    }
    .pointingHandCursor()
  }
}
