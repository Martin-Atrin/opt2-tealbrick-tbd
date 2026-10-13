//
//  DayGoalHeader.swift
//  Dayflow
//
//  Top-of-right-rail target progress header for the timeline summary.
//

import AppKit
import TBDDesign
import SwiftUI

struct TargetCategoryProgress: Equatable, Identifiable {
  let id: String
  let name: String
  let colorHex: String
  let duration: TimeInterval

  var color: Color {
    Color(hex: colorHex)  // design-guard: allow (user category colour)
  }
}

struct DayGoalHeader: View {
  let focusTargetDuration: TimeInterval
  let focusDuration: TimeInterval
  let focusCategories: [TargetCategoryProgress]
  let distractionLimitDuration: TimeInterval
  let distractedDuration: TimeInterval
  let showsDisabledState: Bool
  let recordingControlMode: RecordingControlMode
  let onSetGoals: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var hasInitializedDisplayedProgress = false
  @State private var isAppActive = NSApplication.shared.isActive
  @State private var displayedFocusDuration: TimeInterval = 0
  @State private var displayedFocusCategories: [TargetCategoryProgress] = []
  @State private var displayedDistractedDuration: TimeInterval = 0
  @State private var focusAnimationTask: Task<Void, Never>?
  @State private var distractionCleanupTask: Task<Void, Never>?
  @State private var distractionImpactToken: CGFloat = 0
  @State private var distractionLoss: DistractionLossSnapshot?

  private struct ProgressInputs: Equatable {
    let focusTargetDuration: TimeInterval
    let focusDuration: TimeInterval
    let focusCategories: [TargetCategoryProgress]
    let distractionLimitDuration: TimeInterval
    let distractedDuration: TimeInterval
    let showsDisabledState: Bool
  }

  private enum Design {
    static var distraction: Color { TBDColor.brick }
    static var focusText: Color { TBDColor.tealInk }
    static var distractionText: Color { TBDColor.brickInk }
    static let focusLegendContentWidth: CGFloat = 211.94
    static let focusLegendItemSpacing: CGFloat = 6
  }

  /// "Focus" / "Distraction budget" captions.
  private var labelColor: Color { TBDColor.muted }

  private var distractionFill: Color { Design.distraction }

  private var inactiveTail: Color { TBDColor.plate }

  private var distractionUsedRatio: Double {
    guard distractionLimitDuration > 0 else { return 0 }
    return min(max(renderedDistractedDuration / distractionLimitDuration, 0), 1)
  }

  private var isFocusPastTarget: Bool {
    focusTargetDuration > 0 && renderedFocusDuration > focusTargetDuration
  }

  private var isDistractionPastBudget: Bool {
    distractionLimitDuration > 0 && renderedDistractedDuration > distractionLimitDuration
  }

  private var renderedFocusDuration: TimeInterval {
    hasInitializedDisplayedProgress ? displayedFocusDuration : focusDuration
  }

  private var renderedFocusCategories: [TargetCategoryProgress] {
    hasInitializedDisplayedProgress ? displayedFocusCategories : focusCategories
  }

  private var renderedDistractedDuration: TimeInterval {
    hasInitializedDisplayedProgress ? displayedDistractedDuration : distractedDuration
  }

  private var progressInputs: ProgressInputs {
    ProgressInputs(
      focusTargetDuration: focusTargetDuration,
      focusDuration: focusDuration,
      focusCategories: focusCategories,
      distractionLimitDuration: distractionLimitDuration,
      distractedDuration: distractedDuration,
      showsDisabledState: showsDisabledState
    )
  }

  private var statusText: String {
    switch recordingControlMode {
    case .active:
      return String(localized: "Tracking progress from your focus and distraction categories.")
    case .pausedTimed, .pausedIndefinite:
      return String(localized: "Tealbrick is paused. Resume to continue tracking your progress.")
    case .stopped:
      return String(localized: "Start Tealbrick to continue tracking your progress.")
    }
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      ZStack(alignment: .topLeading) {
        TBDColor.tile
        activeContent
      }
      .opacity(showsDisabledState ? 0 : 1)
      .animation(nil, value: showsDisabledState)
      .allowsHitTesting(!showsDisabledState)
      .accessibilityHidden(showsDisabledState)

      ZStack(alignment: .topLeading) {
        TBDColor.tile
        disabledContent
      }
      .opacity(showsDisabledState ? 1 : 0)
      .animation(nil, value: showsDisabledState)
      .allowsHitTesting(showsDisabledState)
      .accessibilityHidden(!showsDisabledState)
    }
    .frame(width: 360, height: 213, alignment: .topLeading)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .frame(height: 213)
    .clipped()
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(TBDColor.line)
        .frame(height: TBDKit.hair)
    }
    .accessibilityElement(children: .contain)
    .onAppear {
      initializeDisplayedProgressIfNeeded()
      if isAppActive {
        animateDisplayedProgressToCurrentValues()
      }
    }
    .onDisappear {
      focusAnimationTask?.cancel()
      focusAnimationTask = nil
      distractionCleanupTask?.cancel()
      distractionCleanupTask = nil
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      isAppActive = true
      animateDisplayedProgressToCurrentValues()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
    ) { _ in
      isAppActive = false
    }
    .onChange(of: progressInputs) { _, _ in
      handleProgressInputsChanged()
    }
  }

  @ViewBuilder
  private var activeContent: some View {
    Text("Today’s targets")
      .font(TBDTokens.Typography.title)
      .foregroundColor(TBDColor.ink)
      .lineLimit(1)
      .fixedSize()
      .offset(x: 17, y: 18.96)

    // Figma: once goals exist, the header shows a small edit circle instead
    // of the "Set goals" pill.
    CategoryEditCircleButton(
      action: onSetGoals,
      diameter: 20,
      accessibilityLabel: String(localized: "Edit goals")
    )
    .offset(x: 323, y: 22.25)

    Text(statusText)
      .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
      .foregroundColor(TBDColor.muted)
      .lineLimit(2)
      .frame(width: 310, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .offset(x: 17, y: 55.68)

    focusLabels
      .offset(x: 0, y: 88)

    FocusTargetProgressBar(
      categories: renderedFocusCategories,
      targetDuration: focusTargetDuration,
      actualDuration: renderedFocusDuration
    )
    .frame(width: 269, height: 14)
    .offset(x: 39, y: 106.04)

    focusLegend
      .offset(x: 38, y: 120)

    TargetIconBubble(kind: .focus)
      .frame(width: 36, height: 36)
      .offset(x: 11, y: 102)

    distractionRow
      .modifier(
        GoalTrackerImpactShake(
          travelDistance: reduceMotion ? 0 : 1.5,
          shakes: 3,
          animatableData: distractionImpactToken
        )
      )
      .offset(x: 0, y: 158)
  }

  private var distractionRow: some View {
    ZStack(alignment: .topLeading) {
      distractionLabels
        .offset(x: 57.08, y: 0)

      DistractionLimitBar(
        usedRatio: distractionUsedRatio,
        color: distractionFill,
        loss: distractionLoss
      )
      .frame(width: 259, height: 14)
      .offset(x: 57.25, y: 19.04)

      TargetIconBubble(kind: .distraction)
        .frame(width: 36, height: 36)
        .offset(x: 305.25, y: 3.08)
    }
    .frame(width: 360, height: 56, alignment: .topLeading)
  }

  private var distractionLabels: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      GoalMetricSummaryText(
        value: distractionSummaryValue,
        suffix: distractionSummarySuffix,
        accent: Design.distractionText,
        isProminent: isDistractionPastBudget
      )
      .contentTransition(.numericText())
      .lineLimit(1)
      .layoutPriority(0)

      Spacer(minLength: 12)

      Text("Distraction budget")
        .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
        .foregroundColor(labelColor)
        .lineLimit(1)
        .fixedSize()
        .layoutPriority(1)
    }
    .frame(width: 236, alignment: .leading)
    .clipped()
  }

  @ViewBuilder
  private var disabledContent: some View {
    Text("Set today’s goals")
      .font(TBDTokens.Typography.title)
      .foregroundColor(TBDColor.ink)
      .lineLimit(1)
      .fixedSize()
      .offset(x: 17, y: 18.96)

    setGoalsButton
      .offset(x: 268, y: 18.96)

    Text("Set your goals for today to activate the progress bars below.")
      .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
      .foregroundColor(TBDColor.muted)
      .lineLimit(1)
      .fixedSize()
      .offset(x: 17, y: 61.98)

    InactiveGoalTrack(
      width: 269,
      height: 12,
      fillWidth: 260.089,
      fillOffsetX: 0,
      fillOffsetY: 3
    )
    .offset(x: 39, y: 98.04)

    TargetLegendTail()
      .fill(inactiveTail)
      .frame(width: 236.213, height: 14)
      .offset(x: 34.06, y: 112)

    TargetIconBubble(kind: .focus, tint: TBDColor.muted)
      .frame(width: 36, height: 36)
      .offset(x: 11, y: 94)

    InactiveGoalTrack(
      width: 259,
      height: 14,
      fillWidth: 245.979,
      fillOffsetX: 8.71,
      fillOffsetY: 4
    )
    .offset(x: 57.25, y: 141.65)

    TargetLegendTail()
      .fill(inactiveTail)
      .frame(width: 236.213, height: 14)
      .scaleEffect(x: -1, y: 1)
      .offset(x: 80.04, y: 157.62)

    TargetIconBubble(kind: .distraction, tint: TBDColor.muted)
      .frame(width: 36, height: 36)
      .offset(x: 305.25, y: 137.65)
  }

  private var setGoalsButton: some View {
    Button(action: onSetGoals) {
      Text("Set goals")
        .lineLimit(1)
        .fixedSize()
    }
    .buttonStyle(TBDButtonStyle(.primary))
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .accessibilityLabel("Set goals")
  }

  private var focusLabels: some View {
    ZStack(alignment: .topLeading) {
      Text("Focus")
        .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
        .foregroundColor(labelColor)
        .lineLimit(1)
        .fixedSize()
        .offset(x: 49, y: 2.5)

      GoalMetricSummaryText(
        value: focusSummaryValue,
        suffix: focusSummarySuffix,
        accent: Design.focusText,
        isProminent: isFocusPastTarget
      )
      .contentTransition(.numericText())
      .lineLimit(1)
      .fixedSize()
      .offset(x: 222.15, y: 0)
    }
  }

  private var focusLegend: some View {
    ZStack(alignment: .leading) {
      TargetLegendTail()
        .fill(inactiveTail)
        .frame(width: 232.277, height: 14)

      HStack(spacing: Design.focusLegendItemSpacing) {
        ForEach(visibleFocusLegendCategories) { category in
          TargetLegendItem(category: category)
        }
      }
      .padding(.leading, 13.06)
      .frame(width: 225, alignment: .leading)
      .clipped()
    }
    .frame(width: 232.277, height: 14)
  }

  private var visibleFocusLegendCategories: [TargetCategoryProgress] {
    var visibleCategories: [TargetCategoryProgress] = []
    var usedWidth: CGFloat = 0

    for category in focusCategories {
      let itemWidth = legendItemWidth(for: category)
      let nextWidth =
        visibleCategories.isEmpty
        ? itemWidth
        : usedWidth + Design.focusLegendItemSpacing + itemWidth

      guard nextWidth <= Design.focusLegendContentWidth else { break }
      visibleCategories.append(category)
      usedWidth = nextWidth
    }

    return visibleCategories
  }

  private func legendItemWidth(for category: TargetCategoryProgress) -> CGFloat {
    // Measure with the kit face at the legend size (13pt bold); a margin covers the variable-font default instance.
    TBDFonts.register()
    let base = NSFont(name: TBDFonts.family, size: TBDKit.textHint) ?? NSFont.systemFont(ofSize: TBDKit.textHint)  // design-guard: allow (AppKit text measurement of the kit face)
    let font = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    let textWidth = ceil((category.name as NSString).size(withAttributes: [.font: font]).width * 1.1)
    return 4 + 2 + textWidth + 2
  }

  private var focusSummaryValue: String {
    formatCompactHours(renderedFocusDuration)
  }

  private var focusSummarySuffix: String {
    String(localized: "/ \(formatCompactHours(focusTargetDuration)) hr fulfilled")
  }

  private var distractionSummaryValue: String {
    if isDistractionPastBudget {
      return formatUsedDuration(renderedDistractedDuration)
    }
    let remaining = max(0, distractionLimitDuration - renderedDistractedDuration)
    return formatUsedDuration(remaining)
  }

  private var distractionSummarySuffix: String {
    if isDistractionPastBudget {
      return "/ \(formatLimitDuration(distractionLimitDuration)) used"
    }
    return "/ \(formatLimitDuration(distractionLimitDuration))"
  }

  private func formatCompactHours(_ duration: TimeInterval) -> String {
    let hours = duration / 3600
    if abs(hours.rounded() - hours) < 0.01 {
      return "\(Int(hours.rounded()))"
    }
    return hours.formatted(.number.precision(.fractionLength(1)))
  }

  private func formatUsedDuration(_ duration: TimeInterval) -> String {
    LocalizedDuration.string(duration, style: .abbreviated)
  }

  private func formatLimitDuration(_ duration: TimeInterval) -> String {
    LocalizedDuration.string(duration, style: .abbreviated)
  }

  private func initializeDisplayedProgressIfNeeded() {
    guard !hasInitializedDisplayedProgress else { return }
    displayedFocusDuration = focusDuration
    displayedFocusCategories = focusCategories
    displayedDistractedDuration = distractedDuration
    hasInitializedDisplayedProgress = true
  }

  private func handleProgressInputsChanged() {
    guard hasInitializedDisplayedProgress else {
      initializeDisplayedProgressIfNeeded()
      return
    }

    guard !showsDisabledState else {
      setDisplayedProgressImmediately()
      return
    }

    guard isAppActive else { return }
    animateDisplayedProgressToCurrentValues()
  }

  private func setDisplayedProgressImmediately() {
    focusAnimationTask?.cancel()
    focusAnimationTask = nil
    distractionCleanupTask?.cancel()
    distractionCleanupTask = nil
    displayedFocusDuration = focusDuration
    displayedFocusCategories = focusCategories
    displayedDistractedDuration = distractedDuration
    distractionLoss = nil
  }

  private func animateDisplayedProgressToCurrentValues() {
    initializeDisplayedProgressIfNeeded()

    guard !showsDisabledState else {
      setDisplayedProgressImmediately()
      return
    }

    if reduceMotion {
      setDisplayedProgressImmediately()
      return
    }

    let previousDistractedDuration = displayedDistractedDuration

    animateFocusProgressToCurrentValues()
    animateDistractionProgress(
      from: previousDistractedDuration,
      to: distractedDuration
    )

    withAnimation(TBDMotion.quick) {
      displayedFocusDuration = focusDuration
    }
  }

  private func animateFocusProgressToCurrentValues() {
    focusAnimationTask?.cancel()

    let previousByID = Dictionary(
      uniqueKeysWithValues: displayedFocusCategories.map { ($0.id, $0) }
    )
    displayedFocusCategories = focusCategories.map { category in
      TargetCategoryProgress(
        id: category.id,
        name: category.name,
        colorHex: category.colorHex,
        duration: previousByID[category.id]?.duration ?? 0
      )
    }

    focusAnimationTask = Task { @MainActor in
      for (index, category) in focusCategories.enumerated() {
        if Task.isCancelled { return }
        let delayMilliseconds = index == 0 ? 80 : 260
        try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
        if Task.isCancelled { return }

        withAnimation(TBDMotion.gentle) {
          displayedFocusCategories = displayedFocusCategories.map { current in
            current.id == category.id ? category : current
          }
        }
      }
    }
  }

  private func animateDistractionProgress(
    from previousDuration: TimeInterval, to nextDuration: TimeInterval
  ) {
    let limit = max(distractionLimitDuration, 1)
    let previousRatio = min(max(previousDuration / limit, 0), 1)
    let nextRatio = min(max(nextDuration / limit, 0), 1)
    let didSpendDistractionTime = nextDuration > previousDuration + 1

    if didSpendDistractionTime {
      distractionLoss = DistractionLossSnapshot(
        startRatio: previousRatio,
        endRatio: nextRatio,
        token: UUID()
      )
      withAnimation(.linear(duration: 0.42)) {
        distractionImpactToken += 1
      }
    }

    withAnimation(TBDMotion.quick) {
      displayedDistractedDuration = nextDuration
    }

    if didSpendDistractionTime {
      let token = distractionLoss?.token
      distractionCleanupTask?.cancel()
      distractionCleanupTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 760_000_000)
        guard !Task.isCancelled else { return }
        guard token == distractionLoss?.token else { return }
        distractionLoss = nil
        distractionCleanupTask = nil
      }
    }
  }
}

private struct GoalMetricSummaryText: View {
  let value: String
  let suffix: String
  let accent: Color
  let isProminent: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 2) {
      Text(value)
        .font(isProminent ? TBDTokens.Typography.control : TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
        .foregroundColor(accent)

      Text(suffix)
        .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
        .foregroundColor(TBDColor.muted)
    }
    .lineLimit(1)
  }
}

private struct FocusTargetProgressBar: View {
  let categories: [TargetCategoryProgress]
  let targetDuration: TimeInterval
  let actualDuration: TimeInterval

  private let leadingInset: CGFloat = 3
  private let segmentSpacing: CGFloat = 2.55
  private let trailingGap: CGFloat = 3

  private var isFulfilled: Bool {
    targetDuration > 0 && actualDuration >= targetDuration
  }

  var body: some View {
    GeometryReader { geometry in
      let segments = visibleSegments
      let fillFrameWidth = max(0, geometry.size.width - trailingGap)
      let contentWidth = max(0, fillFrameWidth - leadingInset)
      let totalSpacing = segmentSpacing * CGFloat(max(segments.count - 1, 0))
      let availableSegmentWidth = max(0, contentWidth - totalSpacing)

      ZStack(alignment: .leading) {
        trackShape
          .fill(TBDColor.plate)
          .overlay(
            trackShape
              .stroke(
                isFulfilled ? TBDColor.teal.opacity(0.9) : TBDColor.line,
                lineWidth: 0.5
              )
          )

        HStack(spacing: segmentSpacing) {
          ForEach(segments) { category in
            FocusTargetProgressSegment(
              color: category.color,
              isFulfilled: isFulfilled
            )
            .frame(
              width: segmentWidth(for: category, availableWidth: availableSegmentWidth), height: 8)
          }
        }
        .frame(height: 8)
        .padding(.vertical, 3)
        .padding(.leading, leadingInset)
        .frame(width: fillFrameWidth, alignment: .leading)
      }
    }
  }

  private var visibleSegments: [TargetCategoryProgress] {
    categories.filter { $0.duration > 0 }
  }

  private var displayedDuration: TimeInterval {
    let segmentTotal = visibleSegments.reduce(0) { $0 + $1.duration }
    return max(targetDuration, segmentTotal)
  }

  private var trackShape: TBDBrickShape { TBDBrickShape() }

  private func segmentWidth(for category: TargetCategoryProgress, availableWidth: CGFloat)
    -> CGFloat
  {
    guard displayedDuration > 0 else { return 0 }
    let ratio = min(max(category.duration / displayedDuration, 0), 1)
    return max(0, availableWidth * ratio)
  }
}

private struct FocusTargetProgressSegment: View {
  let color: Color
  let isFulfilled: Bool

  var body: some View {
    TBDBrickShape()
      .fill(segmentFill)
  }

  private var segmentFill: LinearGradient {
    LinearGradient(
      colors: [
        color.opacity(isFulfilled ? 0.82 : 1),
        color,
        color.opacity(isFulfilled ? 0.72 : 1),
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
  }
}

private struct DistractionLossSnapshot: Equatable {
  let startRatio: Double
  let endRatio: Double
  let token: UUID
}

private struct DistractionLimitBar: View {
  let usedRatio: Double
  let color: Color
  let loss: DistractionLossSnapshot?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var lossOpacity = 0.0
  @State private var lossScale: CGFloat = 1
  @State private var flashOpacity = 0.0

  var body: some View {
    GeometryReader { geometry in
      let clampedRatio = min(max(usedRatio, 0), 1)
      let fillHeight: CGFloat = 6
      let leadingInset = max(0, (geometry.size.height - fillHeight) / 2)
      let availableWidth = max(0, geometry.size.width - leadingInset)
      let startX = leadingInset + (availableWidth * clampedRatio)
      let remainingWidth = max(0, geometry.size.width - startX)

      ZStack(alignment: .leading) {
        TBDBrickShape()
          .fill(TBDColor.plate)
          .overlay(
            TBDBrickShape()
              .stroke(TBDColor.line, lineWidth: 0.5)
          )

        TBDBrickShape()
          .fill(color)
          .frame(width: remainingWidth, height: fillHeight)
          .offset(x: startX)

        if let loss {
          let lostStartX = leadingInset + (availableWidth * min(max(loss.startRatio, 0), 1))
          let lostEndX = leadingInset + (availableWidth * min(max(loss.endRatio, 0), 1))
          let lostWidth = max(0, lostEndX - lostStartX)

          TBDBrickShape()
            .fill(
              LinearGradient(
                colors: [
                  TBDColor.brick.opacity(0.96),
                  TBDColor.brick.opacity(0.74),
                ],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: lostWidth, height: fillHeight)
            .scaleEffect(x: lossScale, y: 1, anchor: .trailing)
            .opacity(lossOpacity)
            .offset(x: lostStartX)
        }

        TBDBrickShape()
          .fill(TBDColor.brick.opacity(flashOpacity))
      }
      .frame(height: geometry.size.height)
    }
    .onChange(of: loss?.token) {
      playLossAnimationIfNeeded()
    }
  }

  private func playLossAnimationIfNeeded() {
    guard loss != nil, !reduceMotion else {
      lossOpacity = 0
      flashOpacity = 0
      return
    }

    lossOpacity = 1
    lossScale = 1
    flashOpacity = 0.20

    withAnimation(TBDMotion.gentle) {
      flashOpacity = 0
    }

    withAnimation(TBDMotion.gentle.delay(0.09)) {
      lossOpacity = 0
      lossScale = 0.01
    }
  }
}

private struct GoalTrackerImpactShake: GeometryEffect {
  var travelDistance: CGFloat
  var shakes: CGFloat
  var animatableData: CGFloat

  func effectValue(size: CGSize) -> ProjectionTransform {
    let xOffset = travelDistance * sin(animatableData * .pi * shakes)
    return ProjectionTransform(CGAffineTransform(translationX: xOffset, y: 0))
  }
}

private struct InactiveGoalTrack: View {
  let width: CGFloat
  let height: CGFloat
  let fillWidth: CGFloat
  let fillOffsetX: CGFloat
  let fillOffsetY: CGFloat

  var body: some View {
    ZStack(alignment: .topLeading) {
      TBDBrickShape()
        .fill(TBDColor.plate)
        .frame(width: width, height: height)

      TBDBrickShape()
        .fill(TBDColor.line)
        .frame(width: fillWidth, height: 6)
        .offset(x: fillOffsetX, y: fillOffsetY)
    }
    .frame(width: width, height: height, alignment: .topLeading)
  }
}

private struct TargetLegendItem: View {
  let category: TargetCategoryProgress

  var body: some View {
    HStack(spacing: 2) {
      RoundedRectangle(cornerRadius: TBDKit.radiusSwatch)
        .fill(category.color)
        .frame(width: 4, height: 4)

      Text(category.name)
        .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav))
        .foregroundColor(TBDColor.ink)
        .lineLimit(1)
        .fixedSize()
    }
  }
}

private struct TargetIconBubble: View {
  enum Kind {
    case focus
    case distraction
  }

  @Environment(\.stylePreviewAfter) private var stylePreviewAfter

  let kind: Kind
  var tint: Color? = nil

  var body: some View {
    ZStack {
      TBDBrickShape()
        .fill(TBDColor.plate)
        .overlay(
          TBDBrickShape()
            .strokeBorder(TBDColor.line, lineWidth: TBDKit.hair)
        )

      switch kind {
      case .focus:
        assetImage("DayGoalFocus")
          .frame(
            width: stylePreviewAfter ? 20 : 25,
            height: stylePreviewAfter ? 20 : 26)

      case .distraction:
        assetImage("DayGoalDistraction")
          .frame(
            width: stylePreviewAfter ? 20 : 23,
            height: stylePreviewAfter ? 20 : 23)
      }
    }
  }

  private func assetImage(_ name: String) -> some View {
    let image = Image(name)
      .resizable()

    return Group {
      if let tint {
        image
          .renderingMode(.template)
          .foregroundStyle(tint)
      } else {
        image
          .renderingMode(.original)
      }
    }
    .scaledToFit()
  }
}

private struct TargetLegendTail: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let slant: CGFloat = min(rect.width * 0.12, 28)

    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - slant, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + 6, y: rect.maxY))
    path.closeSubpath()

    return path
  }
}

#Preview("Day Goal Header") {
  DayGoalHeader(
    focusTargetDuration: 4.5 * 60 * 60,
    focusDuration: 2 * 60 * 60,
    focusCategories: [
      TargetCategoryProgress(
        id: "research",
        name: "Research",
        colorHex: "8BAAFF",
        duration: 52 * 60
      ),
      TargetCategoryProgress(
        id: "coding",
        name: "Coding",
        colorHex: "CF8FFF",
        duration: 46 * 60
      ),
      TargetCategoryProgress(
        id: "code-review",
        name: "Code review",
        colorHex: "90DDF0",
        duration: 28 * 60
      ),
      TargetCategoryProgress(
        id: "debugging",
        name: "Debugging",
        colorHex: "6E66D4",
        duration: 0
      ),
    ],
    distractionLimitDuration: 2 * 60 * 60,
    distractedDuration: 25 * 60,
    showsDisabledState: false,
    recordingControlMode: .active,
    onSetGoals: {}
  )
  .frame(width: 360, height: 213)
}

#Preview("Disabled Day Goal Header") {
  DayGoalHeader(
    focusTargetDuration: 4.5 * 60 * 60,
    focusDuration: 0,
    focusCategories: [],
    distractionLimitDuration: 2 * 60 * 60,
    distractedDuration: 0,
    showsDisabledState: true,
    recordingControlMode: .active,
    onSetGoals: {}
  )
  .frame(width: 360, height: 213)
}
