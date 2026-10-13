import SwiftUI
import CoreGraphics
import AppKit
import TBDDesign

/// Minimal local setup. No vendor intro, account requirement, or automatic capture.
struct TBDCompanionSetup: View {
  @AppStorage("didOnboard") private var completed = false
  @State private var screenAccess = CGPreflightScreenCaptureAccess()
  @State private var step = 0

  var body: some View {
    VStack(alignment: .leading, spacing: TBDKit.s5) {
      Text("Companion setup").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
      TBDStepFlow(steps: steps, current: $step, size: CGSize(width: 600, height: 380)) { openCompanion() }
        .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
        .clipShape(TBDBrickShape())
    }
    .padding(TBDKit.s10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      screenAccess = CGPreflightScreenCaptureAccess()
    }
  }

  /// Step 1 shows the screen-access state live (optional: capture stays paused, access can be granted later); step 2 opens the app.
  private var steps: [TBDStep] {
    [
      TBDStep("Screen access", optional: true, skipLabel: "Skip, allow it later") {
        VStack(alignment: .leading, spacing: TBDKit.s5) {
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
        }
      },
      TBDStep("Open", nextLabel: "Open Companion") {
        Text("Configure the analysis model in Companion Settings. Manage the shared Portal account and macOS permissions in Settings.")
          .font(TBDTokens.Typography.body)
          .foregroundStyle(TBDColor.muted)
      },
    ]
  }

  private func openCompanion() {
    UserDefaults.standard.set(false, forKey: "isRecording")
    AppState.shared.enablePersistence()
    AppState.shared.setRecording(false)
    completed = true
  }
}
