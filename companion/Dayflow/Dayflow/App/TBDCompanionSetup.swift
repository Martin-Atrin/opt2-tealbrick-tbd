import SwiftUI
import CoreGraphics
import AppKit
import TBDDesign

/// Minimal local setup. No vendor intro, account requirement, or automatic capture.
struct TBDCompanionSetup: View {
  @AppStorage("didOnboard") private var completed = false
  @State private var screenAccess = CGPreflightScreenCaptureAccess()

  var body: some View {
    VStack(alignment: .leading, spacing: TBDKit.s5) {
      Text("Companion setup").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
      Text("Your screen-activity timeline and Daily recap. Capture stays paused until you enable it.")
        .font(TBDTokens.Typography.body)
        .foregroundStyle(TBDColor.muted)
      HStack {
        Label(screenAccess ? "Screen access granted" : "Screen access not granted", systemImage: screenAccess ? "checkmark.circle" : "display")
          .font(TBDTokens.Typography.control)
          .foregroundStyle(screenAccess ? TBDColor.tealInk : TBDColor.ink)
        Spacer()
        if !screenAccess {
          Button("Screen recording settings") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
          }
          .buttonStyle(TBDButtonStyle(.secondary))
        }
      }
      Text("Configure the analysis model in Companion Settings. Manage the shared Portal account and macOS permissions in Settings.")
        .font(TBDTokens.Typography.body)
        .foregroundStyle(TBDColor.muted)
      Button("Open Companion") {
        UserDefaults.standard.set(false, forKey: "isRecording")
        AppState.shared.enablePersistence()
        AppState.shared.setRecording(false)
        completed = true
      }
      .buttonStyle(TBDButtonStyle(.primary, size: .large))
    }
    .padding(TBDKit.s10)
    .frame(maxWidth: 680)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      screenAccess = CGPreflightScreenCaptureAccess()
    }
  }
}
