//
//  SetupContinueButton.swift
//  Dayflow
//
//  Continue button for setup flow with exact Figma styling
//

import SwiftUI
import TBDDesign

struct SetupContinueButton: View {
  let title: String
  let isEnabled: Bool
  let action: () -> Void

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
        Image(systemName: "chevron.right")
          .font(TBDFonts.symbol(12, .bold))
      }
    }
    .buttonStyle(TBDButtonStyle(.primary, size: .large))
    .disabled(!isEnabled)
    .pointingHandCursor(enabled: isEnabled)
  }
}
