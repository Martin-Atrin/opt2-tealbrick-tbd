import AppKit
import SwiftUI
import MacParakeet

struct WeeklySankeySection: View {
  @State private var dataset = WeeklySankeyDataset.timeline
  @State private var randomSeed: Int?

  private let snapshot: WeeklySankeySnapshot?
  private let showsControls: Bool
  private let width: CGFloat

  init(
    snapshot: WeeklySankeySnapshot? = nil,
    showsControls: Bool = true,
    width: CGFloat = WeeklySankeyDesign.cardWidth
  ) {
    self.snapshot = snapshot
    self.showsControls = showsControls
    self.width = width
  }

  private var model: WeeklySankeyModel {
    if let snapshot {
      return WeeklySankeyModelFactory.snapshot(snapshot)
    }

    switch dataset {
    case .timeline:
      return WeeklySankeyModelFactory.timeline()
    case .figma:
      return WeeklySankeyModelFactory.figmaBaseline()
    case .random:
      return WeeklySankeyModelFactory.random(seed: randomSeed ?? 2417)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsControls {
        controls
      }
      WeeklySankeyCard(model: model, width: width)
    }
    .frame(width: width, alignment: .topLeading)
    .background(WeeklyPalette.cardFill)
    .clipShape(RoundedRectangle(cornerRadius: TBDTokens.Radius.base, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: TBDTokens.Radius.base, style: .continuous)
        .stroke(WeeklyPalette.cardBorder, lineWidth: 1)
    )
  }

  private var controls: some View {
    HStack(spacing: 8) {
      Text(model.seedLabel)
        .font(.custom("Switzer-Medium", size: 11))
        .foregroundStyle(WeeklyPalette.title)

      Spacer(minLength: 12)

      controlButton(String(localized: "Timeline data"), dataset: .timeline) {
        dataset = .timeline
      }

      controlButton(String(localized: "Figma baseline"), dataset: .figma) {
        dataset = .figma
      }

      controlButton(String(localized: "Random stress"), dataset: .random) {
        dataset = .random
        randomSeed = nextRandomSeed()
      }
    }
    .padding(.top, 10)
    .padding(.horizontal, 12)
    .frame(height: 33, alignment: .top)
  }

  private func controlButton(
    _ title: String,
    dataset targetDataset: WeeklySankeyDataset,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(.custom("Switzer-Medium", size: 11))
        .foregroundStyle(dataset == targetDataset ? CompanionPalette.accent : CompanionPalette.accent)
        .padding(.horizontal, 9)
        .frame(height: 23)
        .background(
          RoundedRectangle(cornerRadius: TBDTokens.Radius.base, style: .continuous)
            .fill(
              dataset == targetDataset
                ? CompanionPalette.soft.opacity(0.98) : CompanionPalette.soft.opacity(0.72))
        )
        .overlay(
          RoundedRectangle(cornerRadius: TBDTokens.Radius.base, style: .continuous)
            .stroke(
              dataset == targetDataset
                ? CompanionPalette.accent.opacity(0.42)
                : CompanionPalette.soft,
              lineWidth: 1
            )
        )
    }
    .buttonStyle(.plain)
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }

  private func nextRandomSeed() -> Int {
    guard let randomSeed else { return 2417 }
    return ((randomSeed * 48271 + 12_820_163) % 99_991) + 1
  }
}

private enum WeeklySankeyDataset {
  case timeline
  case figma
  case random
}

#Preview("Weekly Sankey", traits: .fixedLayout(width: 958, height: 545)) {
  WeeklySankeySection()
    .padding(24)
    .background(WeeklyPalette.canvas)
}
