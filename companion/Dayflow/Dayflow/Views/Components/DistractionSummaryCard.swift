//
//  DistractionSummaryCard.swift
//  Dayflow
//
//  Summary block showing captured vs distracted time and a distraction pattern note
//

import SwiftUI
import TBDDesign

struct DistractionSummaryCard: View {
  let totalCaptured: String
  let totalDistracted: String
  let distractedRatio: Double
  let patternTitle: String
  let patternDescription: String

  init(
    totalCaptured: String,
    totalDistracted: String,
    distractedRatio: Double,
    patternTitle: String = String(localized: "Main distraction pattern"),
    patternDescription: String
  ) {
    self.totalCaptured = totalCaptured
    self.totalDistracted = totalDistracted
    self.distractedRatio = distractedRatio
    self.patternTitle = patternTitle
    self.patternDescription = patternDescription
  }

  private enum Design {
    static let contentWidth: CGFloat = 293
    static let sectionSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 27
    static let statsSpacing: CGFloat = 24
    static let statsWidth: CGFloat = 130

    static let donutSize: CGFloat = 136
    static let donutInnerMaxSize: CGFloat = 136
    static let donutInnerBottomInset: CGFloat = 4.868

    static var distractedTextColor: Color { TBDColor.brickInk }

    static var labelFont: Font { TBDTokens.Typography.tag }
    static var valueFont: Font { TBDTokens.Typography.title }
    static var patternTitleFont: Font { TBDTokens.Typography.label }
    static var patternBodyFont: Font { TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody) }
  }

  var body: some View {
    let showPattern = !patternDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    VStack(alignment: .center, spacing: showPattern ? Design.sectionSpacing : 0) {
      HStack(alignment: .center, spacing: Design.rowSpacing) {
        donut
        statsBlock
      }

      if showPattern {
        patternBlock
      }
    }
    .frame(width: Design.contentWidth, alignment: .center)
  }

  private var donut: some View {
    let clampedRatio = min(max(distractedRatio, 0), 1)
    let innerDiameter = Design.donutInnerMaxSize * sqrt(clampedRatio)
    let innerX = (Design.donutSize - innerDiameter) / 2
    let innerY = Design.donutSize - Design.donutInnerBottomInset - innerDiameter

    return ZStack(alignment: .topLeading) {
      Circle()
        .fill(TBDColor.plate)
        .overlay(
          Circle()
            .strokeBorder(TBDColor.line, lineWidth: TBDKit.hair)
        )
        .frame(width: Design.donutSize, height: Design.donutSize)

      if innerDiameter > 0.5 {
        Circle()
          .fill(TBDColor.brick)
          .frame(width: innerDiameter, height: innerDiameter)
          .rotationEffect(.degrees(90))
          .offset(x: innerX, y: innerY)
      }
    }
    .frame(width: Design.donutSize, height: Design.donutSize)
  }

  private var statsBlock: some View {
    VStack(alignment: .leading, spacing: Design.statsSpacing) {
      statText(
        title: String(localized: "Total time captured"),
        value: totalCaptured,
        color: TBDColor.muted
      )

      statText(
        title: String(localized: "Total time distracted"),
        value: totalDistracted,
        color: Design.distractedTextColor
      )
    }
    .frame(width: Design.statsWidth, alignment: .leading)
  }

  private func statText(title: String, value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(Design.labelFont)
        .foregroundColor(color)
      Text(value)
        .font(Design.valueFont)
        .foregroundColor(color)
    }
    .lineSpacing(2)
  }

  private var patternBlock: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 2) {
        Image("DistractionSummaryIcon")
          .resizable()
          .frame(width: 16, height: 16)

        Text(patternTitle)
          .font(Design.patternTitleFont)
          .foregroundColor(TBDColor.ink)
      }

      Text(patternDescription)
        .font(Design.patternBodyFont)
        .foregroundColor(TBDColor.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(width: Design.contentWidth, alignment: .leading)
  }
}

#Preview("Distraction Summary Card") {
  DistractionSummaryCard(
    totalCaptured: "8 hours 49 minutes",
    totalDistracted: "2 hours 7 minutes",
    distractedRatio: 0.24,
    patternDescription:
      "YouTube recommendations pull attention from one video to the next for extended periods."
  )
  .padding(24)
  .background(TBDColor.paper)
}
