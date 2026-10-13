//
//  DayflowButton.swift
//  Dayflow
//
//  Custom button component with Dayflow branding
//

import AppKit
import SwiftUI
import TBDDesign

struct DayflowButton: View {
  let title: String
  let action: () -> Void
  var width: CGFloat = 160
  var fontSize: CGFloat = 16
  var isSubtle: Bool = false

  var body: some View {
    Button(action: {
      // Haptic feedback on macOS 11+
      if #available(macOS 11.0, *) {
        NSHapticFeedbackManager.defaultPerformer.perform(
          .levelChange,
          performanceTime: .default
        )
      }

      // Call the action after a short press delay
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        action()
      }
    }) {
      Text(title)
        .font(TBDFonts.nunito(fontSize, TBDKit.weightLabel))
        .frame(width: width, alignment: .center)
    }
    .buttonStyle(TBDButtonStyle(isSubtle ? .secondary : .primary, size: .large))
    .pointingHandCursor()
  }
}

struct DayflowButton_Previews: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 20) {
      DayflowButton(title: String(localized: "Start"), action: {})
      DayflowButton(title: String(localized: "Continue"), action: {}, width: 200)
      DayflowButton(title: String(localized: "Next"), action: {}, width: 120, fontSize: 14)
      DayflowButton(title: String(localized: "Subtle"), action: {}, isSubtle: true)
    }
    .padding(40)
    .background(TBDColor.paper)
  }
}
