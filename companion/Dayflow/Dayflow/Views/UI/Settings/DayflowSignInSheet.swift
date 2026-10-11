import MacParakeet
import SwiftUI

struct DayflowSignInSheet: View {
  let onDismiss: () -> Void
  var body: some View {
    VStack {
      SettingsAccountSection()
      Button("Close", action: onDismiss)
        .buttonStyle(TBDButtonStyle(.secondary))
    }
    .padding(20)
    // Brick: a sheet is a floating element — hard offset shadow, no blur.
    .tbdFloating()
  }
}
