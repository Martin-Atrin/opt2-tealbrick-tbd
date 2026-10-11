import MacParakeet
import SwiftUI

enum WeeklyAccessNotificationState: Equatable {
  case idle
  case requesting
  case scheduled
  case denied
  case failed

  var buttonTitle: String {
    switch self {
    case .idle:
      return String(localized: "Notify me when ready")
    case .requesting:
      return String(localized: "Setting reminder...")
    case .scheduled:
      return String(localized: "We'll notify you")
    case .denied:
      return String(localized: "Open notification settings")
    case .failed:
      return String(localized: "Try again")
    }
  }

  var isButtonDisabled: Bool {
    switch self {
    case .requesting, .scheduled:
      return true
    case .idle, .denied, .failed:
      return false
    }
  }
}

struct WeeklyAccessProgressSnapshot: Equatable {
  static let batchDurationMinutes = 15
  static let batchesPerRecordedHour = 4
  static let recordedHourTarget = 30
  static let completedBatchTarget = recordedHourTarget * batchesPerRecordedHour

  let completedBatchCount: Int

  var progress: Double {
    Double(cappedCompletedBatchCount) / Double(Self.completedBatchTarget)
  }

  var isComplete: Bool {
    completedBatchCount >= Self.completedBatchTarget
  }

  var remainingBatchCount: Int {
    max(Self.completedBatchTarget - completedBatchCount, 0)
  }

  var recordedTimeText: String {
    let minutes = cappedCompletedBatchCount * Self.batchDurationMinutes
    let hours = minutes / 60
    let remainingMinutes = minutes % 60

    if minutes == 0 {
      return String(localized: "0h / 30h")
    }

    if hours == 0 {
      return String(localized: "\(remainingMinutes)m / 30h")
    }

    if remainingMinutes == 0 {
      return String(localized: "\(hours)h / 30h")
    }

    return String(localized: "\(hours)h \(remainingMinutes)m / 30h")
  }

  func estimatedUnlockDate(from date: Date) -> Date {
    date.addingTimeInterval(TimeInterval(remainingBatchCount * Self.batchDurationMinutes * 60))
  }

  private var cappedCompletedBatchCount: Int {
    min(max(completedBatchCount, 0), Self.completedBatchTarget)
  }
}

struct WeeklyAccessLockedView: View {
  let accessProgress: WeeklyAccessProgressSnapshot
  let notificationState: WeeklyAccessNotificationState
  let onNotify: () -> Void

  private var clampedProgress: Double {
    min(max(accessProgress.progress, 0), 1)
  }

  var body: some View {
    GeometryReader { geometry in
      let cardScale = cardScale(for: geometry.size)

      ZStack {
        WeeklyAccessPreviewBackground()
        WeeklyAccessLockedBackground()

        lockCard
          .frame(width: 485, height: 276)
          .scaleEffect(cardScale, anchor: .center)
          .frame(width: 485 * cardScale, height: 276 * cardScale)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }
    }
  }

  private var lockCard: some View {
    WeeklyAccessLockCard(
      recordedTimeText: accessProgress.recordedTimeText,
      isReady: accessProgress.isComplete,
      progress: clampedProgress,
      notificationState: notificationState,
      onNotify: onNotify
    )
  }

  private func cardScale(for size: CGSize) -> CGFloat {
    let availableWidth = max(1, size.width - 64)
    let availableHeight = max(1, size.height - 64)
    return min(1, max(0.66, min(availableWidth / 485, availableHeight / 276)))
  }

}

private struct WeeklyAccessLockCard: View {
  @Environment(\.dayflowTheme) private var theme
  let recordedTimeText: String
  let isReady: Bool
  let progress: Double
  let notificationState: WeeklyAccessNotificationState
  let onNotify: () -> Void

  private var buttonTitle: String {
    isReady ? String(localized: "View Weekly") : notificationState.buttonTitle
  }

  private var isButtonDisabled: Bool {
    !isReady && notificationState.isButtonDisabled
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      WeeklyAccessCardBackground()

      VStack(spacing: 4) {
        // Brick: top-level Weekly page title takes the serif display voice.
        Text("Unlock Weekly")
          .font(.custom("Georgia", size: 22))
          .tracking(TBDTokens.Typography.displayTracking)
          .foregroundStyle(WeeklyPalette.text)
          .multilineTextAlignment(.center)
          .lineLimit(1)
          .minimumScaleFactor(0.76)
          .frame(width: 333, height: 26.4)

        Text("Weekly unlocks after 30 hours of recorded timeline data")
          .font(.custom("Switzer-Regular", size: 14))
          .foregroundStyle(WeeklyPalette.secondaryText)
          .multilineTextAlignment(.center)
          .lineLimit(1)
          .minimumScaleFactor(0.76)
          .frame(width: 333, height: 16.8)
      }
      .frame(width: 333, height: 47.2)
      .position(x: 241.5, y: 48.9)

      WeeklyAccessCountdownPill(text: recordedTimeText)
        .frame(width: 166, height: 60)
        .position(x: 244.39, y: 120.49)

      WeeklyAccessProgressBar(progress: progress)
        .position(x: 246.82, y: 171.6)

      Button(action: onNotify) {
        Text(buttonTitle)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .frame(width: 140)
      }
      .buttonStyle(TBDButtonStyle(.primary))
      .disabled(isButtonDisabled)
      .pointingHandCursorOnHover(enabled: !isButtonDisabled)
      .position(x: 247.94, y: 229)
    }
    .frame(width: 485, height: 276)
    .clipShape(RoundedRectangle(cornerRadius: TBDTokens.Radius.base))
    .overlay(
      RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
        .strokeBorder(WeeklyPalette.cardInnerStroke, lineWidth: TBDTokens.Stroke.hairline)
    )
  }
}

private struct WeeklyAccessCardBackground: View {
  @Environment(\.dayflowTheme) private var theme
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
        .fill(theme.panelSolid)
        .overlay {
          RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
            .fill(WeeklyPalette.cardFillStrong)
        }

      WeeklyAccessGlowCircle(size: 287, colors: [CompanionPalette.accent, CompanionPalette.accent])
        .position(x: 185.4, y: -160.4)

      WeeklyAccessGlowCircle(size: 127, colors: [CompanionPalette.soft, CompanionPalette.accent])
        .position(x: 286.1, y: -219.2)

      WeeklyAccessGlowCircle(size: 115, colors: [CompanionPalette.soft, CompanionPalette.accent])
        .position(x: 318.7, y: -172.7)

      WeeklyAccessGlowCircle(size: 112, colors: [CompanionPalette.soft, CompanionPalette.accent])
        .position(x: 265.6, y: 437.1)

      WeeklyAccessGlowCircle(size: 73, colors: [CompanionPalette.soft, CompanionPalette.accent])
        .position(x: 96.1, y: 415.5)
    }
  }
}

private struct WeeklyAccessGlowCircle: View {
  let size: CGFloat
  let colors: [Color]

  var body: some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [
            colors.first?.opacity(0.44) ?? Color.white.opacity(0.44),
            colors.last?.opacity(0.22) ?? CompanionPalette.accent.opacity(0.22),
            Color.clear,
          ],
          center: .center,
          startRadius: 0,
          endRadius: size / 2
        )
      )
      .frame(width: size, height: size)
      .rotationEffect(.degrees(105))
      .blur(radius: 1.5)
  }
}

private struct WeeklyAccessCountdownPill: View {
  @Environment(\.dayflowTheme) private var theme
  let text: String

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
        .fill(WeeklyPalette.highlightChipFill)
        .overlay(
          RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
            .strokeBorder(CompanionPalette.accent.opacity(0.5), lineWidth: TBDTokens.Stroke.hairline)
        )

      Ellipse()
        .fill(
          RadialGradient(
            colors: [
              Color.white.opacity(0.34),
              Color.white.opacity(0.11),
              Color.clear,
            ],
            center: .center,
            startRadius: 0,
            endRadius: 72
          )
        )
        .frame(width: 134, height: 39)

      RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
        .fill(Color.white.opacity(0.06))

      Text(text)
        .font(.custom("Switzer-Medium", size: 20.5))
        .foregroundStyle(theme.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .frame(width: 142, height: 27, alignment: .center)
        .offset(y: -0.8)
    }
  }
}

private struct WeeklyAccessProgressBar: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var logoRotation = 0.0

  let progress: Double

  private let barWidth: CGFloat = 413.35
  private let barHeight: CGFloat = 8
  private let knobSize: CGFloat = 24

  var body: some View {
    let clampedProgress = min(max(progress, 0), 1)
    let knobOffset = barWidth * clampedProgress

    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
        .fill(WeeklyPalette.rowFill)
        .frame(width: barWidth, height: barHeight)
        .offset(x: knobSize / 2)

      LinearGradient(
        colors: [CompanionPalette.accent.opacity(0.35), CompanionPalette.accent],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: max(0, knobOffset), height: barHeight)
      .offset(x: knobSize / 2)

      Circle()
        .fill(CompanionPalette.accent)
        .frame(width: knobSize, height: knobSize)
        .overlay(
          Image("TealbrickLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color.white)
            .frame(width: 13.5, height: 13.5)
            .rotationEffect(.degrees(reduceMotion ? 0 : logoRotation))
        )
        .offset(x: knobOffset)
    }
    .frame(width: barWidth + knobSize, height: knobSize, alignment: .leading)
    .onAppear {
      startLogoRotationIfNeeded()
    }
    .onChange(of: reduceMotion) { _, shouldReduceMotion in
      if shouldReduceMotion {
        logoRotation = 0
      } else {
        startLogoRotationIfNeeded()
      }
    }
  }

  private func startLogoRotationIfNeeded() {
    guard !reduceMotion, logoRotation == 0 else { return }

    withAnimation(.linear(duration: 22).repeatForever(autoreverses: false)) {
      logoRotation = 360
    }
  }
}

private struct WeeklyAccessLockedBackground: View {
  @Environment(\.dayflowTheme) private var theme
  var body: some View {
    ZStack {
      if theme.isDark {
        theme.panelSolid.opacity(0.78)
      } else {
        CompanionPalette.surface.opacity(0.28)

        LinearGradient(
          colors: [
            Color.white.opacity(0.68),
            CompanionPalette.surface.opacity(0.42),
            CompanionPalette.soft.opacity(0.22),
          ],
          startPoint: .topTrailing,
          endPoint: .bottomLeading
        )
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: TBDTokens.Radius.base))
  }
}

private struct WeeklyAccessPreviewBackground: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isScrolledDown = false

  private static let designWidth: CGFloat = 958
  private static let sectionSpacing: CGFloat = 24
  private static let verticalPadding: CGFloat = 26
  private static let contentHeight: CGFloat =
    verticalPadding * 2
    + 300
    + sectionSpacing
    + 339
    + sectionSpacing
    + 328
    + sectionSpacing
    + 549
    + sectionSpacing
    + 548
    + sectionSpacing
    + 238
    + sectionSpacing
    + 427

  var body: some View {
    GeometryReader { geometry in
      let scale = previewScale(for: geometry.size)
      let scaledHeight = Self.contentHeight * scale
      let travel = scrollTravel(contentHeight: scaledHeight, viewportHeight: geometry.size.height)
      let yOffset =
        reduceMotion
        ? -travel * 0.32
        : (isScrolledDown ? -travel : geometry.size.height * 0.08)

      previewContent
        .frame(width: Self.designWidth, height: Self.contentHeight, alignment: .top)
        .scaleEffect(scale, anchor: .top)
        .frame(width: Self.designWidth * scale, height: scaledHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .center)
        .offset(y: yOffset)
        .opacity(0.46)
        .blur(radius: 2.2)
        .saturation(1.04)
        .allowsHitTesting(false)
        .onAppear {
          startScrollingIfNeeded()
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
          if shouldReduceMotion {
            isScrolledDown = false
          } else {
            startScrollingIfNeeded()
          }
        }
    }
    .clipped()
    .allowsHitTesting(false)
  }

  private var previewContent: some View {
    VStack(spacing: Self.sectionSpacing) {
      WeeklyDonutSection(snapshot: .figmaPreview, isLoading: false, width: Self.designWidth)
        .frame(width: Self.designWidth, height: 300, alignment: .topLeading)

      WeeklyOverviewSection(snapshot: .figmaPreview)
        .frame(width: Self.designWidth, height: 339, alignment: .topLeading)
        .clipped()

      WeeklyTreemapSection(snapshot: .figmaPreview)

      WeeklySankeySection(snapshot: .weeklyAccessPreview, showsControls: false)
        .frame(width: Self.designWidth, height: 548, alignment: .topLeading)
        .clipped()

      WeeklyFocusHeatmapSection(snapshot: .figmaPreview)

      WeeklyContextChartsSection(snapshot: .figmaPreview)
        .frame(width: Self.designWidth, height: 427, alignment: .topLeading)
    }
    .padding(.vertical, Self.verticalPadding)
  }

  private func previewScale(for size: CGSize) -> CGFloat {
    let availableWidth = max(320, size.width - 96)
    return min(0.95, max(0.58, availableWidth / Self.designWidth))
  }

  private func scrollTravel(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
    let availableTravel = contentHeight - viewportHeight + 180
    return max(96, min(availableTravel, 860))
  }

  private func startScrollingIfNeeded() {
    guard !reduceMotion, !isScrolledDown else { return }

    withAnimation(.linear(duration: 26).repeatForever(autoreverses: true)) {
      isScrolledDown = true
    }
  }
}

extension WeeklySankeySnapshot {
  fileprivate static let weeklyAccessPreview = WeeklySankeySnapshot(
    id: "weekly-access-preview",
    seedLabel: String(localized: "Weekly preview"),
    sourceName: "Weekly",
    categories: [
      .init(id: "research", name: "Research", minutes: 430, colorHex: "93BCFF"),
      .init(id: "communication", name: "Communication", minutes: 360, colorHex: "6CDACD"),
      .init(id: "design", name: "Design", minutes: 720, colorHex: "DE9DFC"),
      .init(id: "testing", name: "Testing", minutes: 240, colorHex: "FFA189"),
      .init(id: "distractions", name: "Distractions", minutes: 150, colorHex: "FF5950"),
      .init(id: "personal", name: "Personal", minutes: 180, colorHex: "FFC6B7"),
    ],
    apps: [
      .init(id: "chatgpt", name: "ChatGPT", minutes: 320, colorHex: "333333"),
      .init(id: "claude", name: "Claude", minutes: 250, colorHex: "D97757"),
      .init(id: "figma", name: "Figma", minutes: 720, colorHex: "FF7262"),
      .init(id: "slack", name: "Slack", minutes: 260, colorHex: "36C5F0"),
      .init(id: "zoom", name: "Zoom", minutes: 100, colorHex: "4085FD"),
      .init(id: "clickup", name: "ClickUp", minutes: 100, colorHex: "FD1BB9"),
      .init(id: "youtube", name: "YouTube", minutes: 110, colorHex: "FF0000"),
      .init(id: "other", name: "Other", minutes: 220, colorHex: "D9D9D9"),
    ],
    links: [
      .init(id: "research-chatgpt", from: "research", to: "chatgpt", minutes: 180),
      .init(id: "research-claude", from: "research", to: "claude", minutes: 150),
      .init(id: "research-figma", from: "research", to: "figma", minutes: 100),
      .init(id: "communication-slack", from: "communication", to: "slack", minutes: 260),
      .init(id: "communication-zoom", from: "communication", to: "zoom", minutes: 100),
      .init(id: "design-figma", from: "design", to: "figma", minutes: 520),
      .init(id: "design-claude", from: "design", to: "claude", minutes: 100),
      .init(id: "design-chatgpt", from: "design", to: "chatgpt", minutes: 100),
      .init(id: "testing-clickup", from: "testing", to: "clickup", minutes: 100),
      .init(id: "testing-figma", from: "testing", to: "figma", minutes: 100),
      .init(id: "testing-chatgpt", from: "testing", to: "chatgpt", minutes: 40),
      .init(id: "distractions-youtube", from: "distractions", to: "youtube", minutes: 110),
      .init(id: "distractions-other", from: "distractions", to: "other", minutes: 40),
      .init(id: "personal-other", from: "personal", to: "other", minutes: 180),
    ]
  )
}

#Preview("Weekly Access Locked", traits: .fixedLayout(width: 1024, height: 604)) {
  WeeklyAccessLockedView(
    accessProgress: WeeklyAccessProgressSnapshot(completedBatchCount: 34),
    notificationState: .idle,
    onNotify: {}
  )
}
