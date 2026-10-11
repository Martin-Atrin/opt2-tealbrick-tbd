//
//  SetupContinueButton.swift
//  Dayflow
//
//  Continue button for setup flow with exact Figma styling
//

import SwiftUI
import MacParakeet

struct SetupContinueButton: View {
  let title: String
  let isEnabled: Bool
  let action: () -> Void

  @Environment(\.dayflowTheme) private var theme
  @State private var isPressed = false
  @State private var isHovered = false

  init(
    title: String = String(localized: "Continue"), isEnabled: Bool = true,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.isEnabled = isEnabled
    self.action = action
  }

  var body: some View {
    Button(action: isEnabled ? action : {}) {
      HStack(alignment: .center, spacing: 6) {
        Text(title)
          .font(.custom("Switzer", size: 14))
          .fontWeight(.regular)
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .medium))
      }
      .foregroundColor(TBDTokens.onPrimary)
      .padding(.leading, 28)
      .padding(.trailing, 24)
      .frame(height: 44)
      .background(TBDTokens.fill)
      // Brick: square, lifts onto a hard offset shadow on hover, seats on press.
      .background(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).fill(TBDTokens.ink.opacity(isHovered && isEnabled && !isPressed ? 0.18 : 0)).offset(x: 3, y: 3))
      .offset(x: isHovered && isEnabled && !isPressed ? -1 : 0, y: isHovered && isEnabled && !isPressed ? -1 : 0)
      .opacity(isEnabled ? 1.0 : 0.4)
    }
    .buttonStyle(.plain)
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isPressed)
    .animation(.easeOut(duration: 0.2), value: isHovered)
    .onHover { hovering in
      if isEnabled {
        isHovered = hovering
      }
    }
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          if isEnabled {
            isPressed = true
          }
        }
        .onEnded { _ in
          isPressed = false
        }
    )
    .disabled(!isEnabled)
    .pointingHandCursor(enabled: isEnabled)
  }
}
