//
//  TimelineReviewSummaryCard.swift
//  Dayflow
//
//  Review summary card that links to timeline swiping.
//

import SwiftUI
import TBDDesign

struct TimelineReviewSummarySnapshot {
  let hasData: Bool
  let lastReviewedAt: Date?
  let distractedRatio: Double
  let neutralRatio: Double
  let productiveRatio: Double
  let distractedDuration: TimeInterval
  let neutralDuration: TimeInterval
  let productiveDuration: TimeInterval

  static let placeholder = TimelineReviewSummarySnapshot(
    hasData: false,
    lastReviewedAt: nil,
    distractedRatio: 1.0 / 3.0,
    neutralRatio: 1.0 / 3.0,
    productiveRatio: 1.0 / 3.0,
    distractedDuration: 0,
    neutralDuration: 0,
    productiveDuration: 0
  )
}

struct TimelineReviewSummaryCard: View {
  let summary: TimelineReviewSummarySnapshot
  let cardsToReviewCount: Int
  var onReviewTap: (() -> Void)? = nil

  private enum Design {
    static let sectionSpacing: CGFloat = 12
    static let headerSpacing: CGFloat = 2
    static let contentSpacing: CGFloat = 16

    static var linkColor: Color { TBDColor.link }

    static let barHeight: CGFloat = 39
    static let barStrokeWidth: CGFloat = TBDKit.hair
    static let barSpacing: CGFloat = 4

    static let legendSpacing: CGFloat = 28
    static let legendRowSpacing: CGFloat = 2
    static let legendIconWidth: CGFloat = 10.667
    static let legendIconHeight: CGFloat = 8
    static let legendStrokeWidth: CGFloat = TBDKit.hair
  }

  private struct ReviewMetric: Identifiable {
    let id: String
    let label: String
    let ratio: CGFloat
    let durationText: String
    let style: ReviewMetricStyle
  }

  private struct ReviewMetricStyle {
    let barFill: Color
    let barStroke: Color
    let legendFill: Color
    let legendStroke: Color
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Design.sectionSpacing) {
      header

      VStack(alignment: .leading, spacing: Design.contentSpacing) {
        barRow
        legendRow
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Design.headerSpacing) {
      Text("Your review")
        .font(TBDTokens.Typography.title)
        .foregroundColor(TBDColor.ink)

      subtitle
        .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
        .lineSpacing(2)
        .onTapGesture {
          guard cardsToReviewCount > 0 else { return }
          onReviewTap?()
        }
        .hoverScaleEffect(
          enabled: cardsToReviewCount > 0,
          scale: 1.02
        )
        .pointingHandCursorOnHover(
          enabled: cardsToReviewCount > 0,
          reassertOnPressEnd: true
        )
        .opacity(cardsToReviewCount > 0 ? 1 : 0.9)
    }
  }

  private var subtitle: Text {
    let baseText =
      summary.hasData
      ? String(localized: "Last reviewed at \(formattedLastReviewedAt).")
      : String(localized: "No reviews yet.")
    var composed = Text(baseText)
      .foregroundColor(TBDColor.muted)

    guard cardsToReviewCount > 0 else {
      return composed
    }

    composed =
      composed
      + Text(" Review \(cardsToReviewCount) cards to update your data.")
      .foregroundColor(Design.linkColor)

    return composed
  }

  private var barRow: some View {
    GeometryReader { proxy in
      let metrics = reviewMetrics
      let spacing = Design.barSpacing
      let totalSpacing = spacing * CGFloat(max(metrics.count - 1, 0))
      let availableWidth = max(proxy.size.width - totalSpacing, 0)

      HStack(spacing: spacing) {
        ForEach(metrics) { metric in
          TBDBrickShape()
            .fill(metric.style.barFill)
            .frame(width: availableWidth * metric.ratio, height: Design.barHeight)
            .overlay(
              TBDBrickShape()
                .strokeBorder(metric.style.barStroke, lineWidth: Design.barStrokeWidth)
            )
        }
      }
      .frame(width: proxy.size.width, height: Design.barHeight, alignment: .leading)
    }
    .frame(height: Design.barHeight)
  }

  private var legendRow: some View {
    let metrics = reviewMetrics
    return HStack(spacing: Design.legendSpacing) {
      ForEach(metrics) { metric in
        VStack(alignment: .leading, spacing: Design.legendRowSpacing) {
          HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: TBDKit.radiusSwatch, style: .continuous)
              .fill(metric.style.legendFill)
              .frame(width: Design.legendIconWidth, height: Design.legendIconHeight)
              .overlay(
                RoundedRectangle(cornerRadius: TBDKit.radiusSwatch, style: .continuous)
                  .strokeBorder(metric.style.legendStroke, lineWidth: Design.legendStrokeWidth)
              )

            Text(metric.label)
              .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
              .foregroundColor(TBDColor.muted)
          }

          if summary.hasData {
            Text(metric.durationText)
              .font(TBDTokens.Typography.label)
              .foregroundColor(TBDColor.ink)
              .padding(.leading, 14)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private var reviewMetrics: [ReviewMetric] {
    let placeholder = summary.hasData == false
    let distracted = ReviewMetric(
      id: "distracted",
      label: String(localized: "Distracted"),
      ratio: max(CGFloat(summary.distractedRatio), 0),
      durationText: durationText(summary.distractedDuration),
      style: metricStyle(
        baseColor: TBDColor.toneBrick,
        legendFill: TBDColor.toneBrick.opacity(0.4),
        legendStroke: TBDColor.toneBrick,
        placeholder: placeholder
      )
    )

    let neutral = ReviewMetric(
      id: "neutral",
      label: String(localized: "Neutral"),
      ratio: max(CGFloat(summary.neutralRatio), 0),
      durationText: durationText(summary.neutralDuration),
      style: metricStyle(
        baseColor: TBDColor.toneStone,
        legendFill: TBDColor.toneStone.opacity(0.4),
        legendStroke: TBDColor.toneStone,
        placeholder: placeholder
      )
    )

    let productive = ReviewMetric(
      id: "productive",
      label: String(localized: "Focused"),
      ratio: max(CGFloat(summary.productiveRatio), 0),
      durationText: durationText(summary.productiveDuration),
      style: metricStyle(
        baseColor: TBDColor.toneTeal,
        legendFill: TBDColor.toneTeal.opacity(0.4),
        legendStroke: TBDColor.toneTeal,
        placeholder: placeholder
      )
    )

    return [distracted, neutral, productive]
  }

  private func metricStyle(
    baseColor: Color,
    legendFill: Color,
    legendStroke: Color,
    placeholder: Bool
  ) -> ReviewMetricStyle {
    let barColor = placeholder ? TBDColor.plate : baseColor

    return ReviewMetricStyle(
      barFill: barColor,
      barStroke: placeholder ? TBDColor.line : barColor,
      legendFill: legendFill,
      legendStroke: legendStroke
    )
  }

  private func durationText(_ duration: TimeInterval) -> String {
    let totalMinutes = Int(duration / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0 && minutes > 0 {
      return String(localized: "\(hours)h \(minutes)m")
    } else if hours > 0 {
      return String(localized: "\(hours)h")
    } else {
      return String(localized: "\(minutes)m")
    }
  }

  private var formattedLastReviewedAt: String {
    guard let last = summary.lastReviewedAt else { return "—" }
    return Self.timeFormatter.string(from: last)
  }

  private var reviewCountText: String {
    String(localized: "\(cardsToReviewCount) cards")
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter
  }()
}

#Preview("Timeline Review Summary Card") {
  VStack(spacing: 24) {
    TimelineReviewSummaryCard(
      summary: TimelineReviewSummarySnapshot(
        hasData: true,
        lastReviewedAt: Date(),
        distractedRatio: 0.22,
        neutralRatio: 0.4,
        productiveRatio: 0.38,
        distractedDuration: 4200,
        neutralDuration: 3000,
        productiveDuration: 7200
      ),
      cardsToReviewCount: 4
    )
    .frame(width: 322)

    TimelineReviewSummaryCard(
      summary: .placeholder,
      cardsToReviewCount: 0
    )
    .frame(width: 322)
  }
  .padding(24)
  .background(TBDColor.paper)
}
