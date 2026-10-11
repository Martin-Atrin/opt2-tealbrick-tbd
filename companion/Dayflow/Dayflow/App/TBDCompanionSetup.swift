import SwiftUI
import CoreGraphics
import AppKit

/// Minimal local setup. No vendor intro, account requirement, or automatic capture.
struct TBDCompanionSetup: View {
  @AppStorage("didOnboard") private var completed = false
  @Environment(\.dayflowTheme) private var theme
  @State private var screenAccess = CGPreflightScreenCaptureAccess()

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Companion setup").font(.title2)
      Text("Timeline, focus sessions and nudges. Capture stays paused until you enable it.")
        .foregroundStyle(theme.textSecondary)
      HStack {
        Label(screenAccess ? "Screen access granted" : "Screen access not granted", systemImage: screenAccess ? "checkmark.circle" : "display")
        Spacer()
        if !screenAccess {
          Button("Screen recording settings") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
          }
        }
      }
      Text("Configure the analysis model in Companion Settings. Manage the shared Portal account and macOS permissions in Settings.")
        .foregroundStyle(theme.textSecondary)
      Button("Open Companion") {
        UserDefaults.standard.set(false, forKey: "isRecording")
        AppState.shared.enablePersistence()
        AppState.shared.setRecording(false)
        completed = true
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(40)
    .frame(maxWidth: 680)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      screenAccess = CGPreflightScreenCaptureAccess()
    }
  }
}
