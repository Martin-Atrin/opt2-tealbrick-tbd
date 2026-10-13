import TBDDesign
import SwiftUI

struct GoalReviewCard: View {
  let kind: DayGoalCategoryKind
  let title: String
  let subtitle: String
  let targetDuration: TimeInterval
  let actualDuration: TimeInterval
  let categories: [DayGoalCategoryResult]

  private var accent: Color {
    kind == .focus ? TBDColor.teal : TBDColor.brick
  }

  private var iconName: String {
    kind == .focus ? "DayGoalFocus" : "DayGoalDistraction"
  }

  private var succeeded: Bool {
    switch kind {
    case .focus:
      return actualDuration >= targetDuration
    case .distraction:
      return actualDuration <= targetDuration
    }
  }

  private var progressRatio: Double {
    guard targetDuration > 0 else { return 0 }
    return min(max(actualDuration / targetDuration, 0), 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
          Text(subtitle)
        }
        .font(TBDTokens.Typography.body)
        .foregroundColor(TBDColor.ink)

        Spacer()

        resultBadge
      }

      HStack(spacing: 8) {
        if kind == .focus {
          GoalIconBubble(kind: kind)
        }

        GeometryReader { geometry in
          ZStack(alignment: kind == .focus ? .leading : .trailing) {
            TBDBrickShape()
              .fill(TBDColor.plate)

            TBDBrickShape()
              .fill(accent)
              .frame(width: barWidth(availableWidth: geometry.size.width), height: 8)
          }
        }
        .frame(height: 14)

        if kind == .distraction {
          GoalIconBubble(kind: kind)
        }
      }

      if kind == .focus {
        GoalCategoryBreakdown(categories: categories)
          .frame(height: 92)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, kind == .focus ? 18 : 18)
    .frame(width: 388, height: kind == .focus ? 236 : 123, alignment: .topLeading)
    .background(TBDColor.tile, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }

  private var resultBadge: some View {
    TBDTag(
      succeeded ? String(localized: "NAILED IT") : String(localized: "MISSED"),
      status: succeeded ? .live : .needsYou)
  }

  private func barWidth(availableWidth: CGFloat) -> CGFloat {
    let width = availableWidth * progressRatio
    if kind == .distraction {
      return max(0, width)
    }
    return max(0, width)
  }
}

private struct GoalCategoryBreakdown: View {
  let categories: [DayGoalCategoryResult]

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      if categories.isEmpty {
        Text("No focus categories tracked")
          .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
          .foregroundColor(TBDColor.muted)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        ForEach(categories.prefix(4)) { category in
          HStack(spacing: 9) {
            Text(category.name)
              .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
              .foregroundColor(TBDColor.ink)
              .lineLimit(1)
              .frame(width: 74, alignment: .leading)

            TBDBrickShape()
              .fill(category.color)
              .frame(width: barWidth(for: category), height: 6)

            Text(formatDuration(category.duration))
              .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
              .foregroundColor(TBDColor.ink)
              .lineLimit(1)

            Spacer(minLength: 0)
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .background(TBDColor.paper, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }

  private func barWidth(for category: DayGoalCategoryResult) -> CGFloat {
    guard let maxDuration = categories.map(\.duration).max(), maxDuration > 0 else { return 0 }
    return max(18, CGFloat(category.duration / maxDuration) * 86)
  }

  private func formatDuration(_ duration: TimeInterval) -> String {
    let totalMinutes = Int(duration / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 && minutes > 0 {
      return "\(hours)h \(minutes)m"
    }
    if hours > 0 {
      return "\(hours)h"
    }
    return "\(minutes)m"
  }
}

private struct GoalIconBubble: View {
  let kind: DayGoalCategoryKind

  var body: some View {
    ZStack {
      TBDBrickShape()
        .fill(TBDColor.plate)
        .overlay(TBDBrickShape().strokeBorder(accent, lineWidth: TBDKit.hair))

      Image(kind == .focus ? "DayGoalFocus" : "DayGoalDistraction")
        .resizable()
        .scaledToFit()
        .frame(width: 24, height: 24)
    }
    .frame(width: 36, height: 36)
  }

  private var accent: Color {
    kind == .focus ? TBDColor.teal : TBDColor.brick
  }
}
