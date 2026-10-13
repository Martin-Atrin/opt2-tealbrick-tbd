import SwiftUI
import TBDDesign

/// Settings block for checking and installing TBD updates. The user starts every install.
struct TBDUpdatesSection: View {
  @ObservedObject private var updater = TBDUpdater.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Updates")
        .font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightLabel))
        .foregroundStyle(TBDColor.ink)
      Text("Version \(updater.currentVersion)")
        .font(TBDTokens.Typography.body)
        .foregroundStyle(TBDColor.ink)
      HStack(spacing: 12) {
        Button("Check for updates") { Task { await updater.check() } }
          .buttonStyle(TBDButtonStyle(.secondary))
          .disabled(isBusy)
        if case .available = updater.state {
          Button("Download and install") { Task { await updater.downloadAndInstall() } }
            .buttonStyle(TBDButtonStyle(.primary))
        }
      }
      switch updater.state {
      case .downloading(let progress):
        ProgressView(value: progress)
          .tint(TBDColor.tealInk)
        Text("Downloading \(Int(progress * 100))%")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      case .readyToInstall:
        ProgressView()
        Text("Installing. TBD restarts when done.")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      default:
        if let text = statusText {
          if isFailure {
            TBDNotice(text, tone: .needsYou)
          } else {
            Text(text).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
          }
        }
      }
      Text("Updates are checked once a day against a signed list. Nothing else is sent.")
        .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
    }
  }

  private var isBusy: Bool {
    switch updater.state {
    case .checking, .downloading, .readyToInstall: return true
    default: return false
    }
  }

  private var isFailure: Bool {
    if case .failed = updater.state { return true }
    return false
  }

  private var statusText: String? {
    switch updater.state {
    case .idle: return nil
    case .checking: return "Checking…"
    case .upToDate: return "TBD is up to date."
    case .available(let version): return "Version \(version) is available."
    case .failed(let message): return message
    case .downloading, .readyToInstall: return nil
    }
  }
}
