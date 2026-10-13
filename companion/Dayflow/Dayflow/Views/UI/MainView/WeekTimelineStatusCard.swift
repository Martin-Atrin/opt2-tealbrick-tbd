import SwiftUI
import TBDDesign

// The "Next card... / Paused / Resume" pill shown in today's column of the
// Week view. The parent grid positions it; this view only renders the pill.
// Colors mirror the Day view's status cards so both views flip together.
struct WeekRecordingStatusCard: View {
  let mode: RecordingControlMode
  let width: CGFloat
  let height: CGFloat

  private var compact: Bool {
    height < 24
  }

  private var isActive: Bool {
    if case .active = mode { return true }
    return false
  }

  var body: some View {
    HStack(spacing: 0) {
      label
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .frame(
      width: width,
      height: height,
      alignment: .leading
    )
    .background(
      TBDBrickShape()
        .fill(isActive ? TBDColor.statusLiveFill : TBDColor.statusIdleFill)
    )
    .overlay(
      TBDBrickShape()
        .strokeBorder(
          isActive ? TBDColor.statusLiveEdge : TBDColor.statusIdleEdge, lineWidth: TBDKit.hair)
    )
  }

  @ViewBuilder
  private var label: some View {
    switch mode {
    case .active:
      HStack(spacing: 6) {
        TimelineThinkingSpinner(config: spinnerConfig, visualScale: 0.4)
        if !compact {
          Text("Next card...")
            .font(TBDFonts.nunito(10, TBDKit.weightNav))
            .foregroundStyle(TBDColor.statusLiveOn)
            .lineLimit(1)
        }
      }
    case .pausedTimed, .pausedIndefinite:
      Label("Paused", systemImage: "pause.fill")
        .font(TBDFonts.nunito(10, TBDKit.weightNav))
        .foregroundStyle(TBDColor.statusIdleOn)
    case .stopped:
      Label("Resume", systemImage: "play.fill")
        .font(TBDFonts.nunito(10, TBDKit.weightNav))
        .foregroundStyle(TBDColor.statusIdleOn)
    }
  }

  private var spinnerConfig: TimelineSpinnerConfig {
    var config = TimelineSpinnerConfig.reference
    config.gap = 1.0
    // Kit teal ramp (teal-deep, teal, teal-ink dark) for the thinking spinner.
    config.colorDim = .init(0.043, 0.396, 0.388)
    config.colorMid = .init(0.043, 0.584, 0.580)
    config.colorHot = .init(0.435, 0.827, 0.812)
    return config
  }
}
