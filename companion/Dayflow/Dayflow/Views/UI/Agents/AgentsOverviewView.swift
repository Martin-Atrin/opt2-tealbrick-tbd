//
//  AgentsOverviewView.swift
//  Dayflow
//
//  Stage 1 of the Agents flow: "Today, July 6" — one soft blob per
//  workstream carrying live status chips, plus a totals legend and the
//  user-initiated generate/refresh control.
//

import SwiftUI
import TBDDesign

struct AgentsOverviewView: View {
  let recap: AgentsDayRecap
  let isRefreshing: Bool
  let refreshError: String?
  /// Nearest days with a recap on disk, for the ‹ › toggles (nil disables).
  let previousDay: String?
  let nextDay: String?
  let onSelectDay: (String) -> Void
  let onRefresh: () -> Void
  let onSelectWorkstream: (Int) -> Void
  let onStartReview: () -> Void

  // Loose scatter echoing the Figma layout; fractions of the available area.
  private static let blobAnchors: [CGPoint] = [
    CGPoint(x: 0.30, y: 0.30),
    CGPoint(x: 0.62, y: 0.22),
    CGPoint(x: 0.82, y: 0.44),
    CGPoint(x: 0.30, y: 0.68),
    CGPoint(x: 0.58, y: 0.72),
    CGPoint(x: 0.82, y: 0.80),
    CGPoint(x: 0.14, y: 0.50),
  ]

  var body: some View {
    ZStack(alignment: .topLeading) {
      GeometryReader { geo in
        ForEach(Array(recap.workstreams.enumerated()), id: \.element.id) { index, workstream in
          blob(for: workstream, index: index)
            .position(blobPosition(index: index, in: geo.size))
        }
      }
      .padding(.top, 70)
      .padding(.bottom, 60)

      header
        .padding(.top, 28)
        .padding(.horizontal, 32)

      legend
        .padding(.top, 92)
        .padding(.leading, 32)
    }
    .overlay(alignment: .bottom) {
      startReviewButton
        .padding(.bottom, 26)
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .top) {
      HStack(spacing: 10) {
        dayToggle(systemName: "chevron.left", day: previousDay)
        Text(dayHeading)
          .font(TBDTokens.Typography.display)
          .tracking(TBDTokens.Typography.displayTracking)
          .foregroundColor(.black.opacity(0.85))
        dayToggle(systemName: "chevron.right", day: nextDay)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 5) {
        refreshButton
        if refreshError != nil {
          Text("Last refresh failed — try again")
            .font(.custom("Switzer", size: 11))
            .foregroundColor(TBDTokens.alert)
        } else if let generatedText = generatedAtText {
          Text(generatedText)
            .font(.custom("Switzer", size: 11))
            .foregroundColor(.black.opacity(0.35))
        }
      }
    }
  }

  private func dayToggle(systemName: String, day: String?) -> some View {
    Button(action: { if let day { onSelectDay(day) } }) {
      Image(systemName: systemName)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(.black.opacity(day == nil ? 0.12 : 0.45))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(day == nil)
    .pointingHandCursor()
  }

  /// Month and day in the current locale's order and script (e.g. "July 6", "6. Juli", "7月6日").
  private static let dayHeadingFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMMd")
    return formatter
  }()

  private var dayHeading: String {
    guard let date = DateFormatter.yyyyMMdd.date(from: recap.day) else {
      return String(localized: "Today")
    }
    let dayText = Self.dayHeadingFormatter.string(from: date)
    if Calendar.current.isDateInToday(date) {
      return String(localized: "Today, \(dayText)")
    }
    return dayText
  }

  private var isViewingToday: Bool {
    guard let date = DateFormatter.yyyyMMdd.date(from: recap.day) else { return true }
    return Calendar.current.isDateInToday(date)
  }

  private var generatedAtText: String? {
    let iso = ISO8601DateFormatter()
    guard let date = iso.date(from: recap.generatedAt) else { return nil }
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return String(
      localized: "Generated \(formatter.string(from: date))",
      comment:
        "Caption under the refresh button. The argument is a clock time such as 3:45 PM, i.e. 'Generated at 3:45 PM'."
    )
  }

  private var refreshButton: some View {
    Button(action: onRefresh) {
      HStack(spacing: 6) {
        if isRefreshing {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: "sparkles")
            .font(.system(size: 11, weight: .semibold))
        }
        Text(refreshButtonTitle)
      }
    }
    .buttonStyle(TBDButtonStyle(.secondary))
    .disabled(isRefreshing)
    .pointingHandCursor()
  }

  /// A refresh always regenerates *today's* recap, so make that explicit
  /// whenever a past day is on screen.
  private var refreshButtonTitle: String {
    if isRefreshing { return String(localized: "Refreshing…") }
    return isViewingToday
      ? String(localized: "Refresh recap") : String(localized: "Generate today's recap")
  }

  private func blobPosition(index: Int, in size: CGSize) -> CGPoint {
    let anchor = Self.blobAnchors[index % Self.blobAnchors.count]
    return CGPoint(x: size.width * anchor.x, y: size.height * anchor.y)
  }

  // MARK: - Legend

  private var legend: some View {
    let counts = recap.totalCounts

    return VStack(alignment: .leading, spacing: 6) {
      Text("Total")
        .font(.custom("Switzer", size: 11))
        .fontWeight(.semibold)
        .foregroundColor(.black.opacity(0.55))

      ForEach(AgentThreadStatus.allCases, id: \.self) { status in
        legendRow(status: status, count: counts.count(for: status))
      }
    }
    .padding(12)
    .background(TBDTokens.paper)
    .overlay(
      RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
        .strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline)
    )
  }

  private func legendRow(status: AgentThreadStatus, count: Int) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
        .fill(AgentsPalette.legendDot(for: status))
        .frame(width: 6, height: 6)
      Text("\(count) \(status.displayName)")
        .font(.custom("Switzer", size: 11))
        .foregroundColor(.black.opacity(0.6))
    }
  }

  // MARK: - Blobs

  private func blob(for workstream: AgentWorkstream, index: Int) -> some View {
    let size = blobSize(for: workstream)
    let counts = workstream.counts
    let topChips = chipStatuses(counts).prefix(1)
    let bottomChips = chipStatuses(counts).dropFirst()

    return ZStack {
      Ellipse()
        .fill(AgentsPalette.blobColor(at: index).opacity(0.65))
        .frame(width: size * 1.5, height: size)
        .blur(radius: 34)

      VStack(spacing: 8) {
        chipRow(Array(topChips), counts: counts)

        Text(workstream.name)
          .font(.custom("Switzer", size: 16))
          .fontWeight(.medium)
          .foregroundColor(.black.opacity(0.8))

        if !workstream.summary.isEmpty {
          Text(workstream.summary)
            .font(.custom("Switzer", size: 11.5))
            .foregroundColor(.black.opacity(0.55))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: size * 1.15)
        }

        chipRow(Array(bottomChips), counts: counts)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { onSelectWorkstream(index) }
    .hoverScaleEffect(scale: 1.03)
    .pointingHandCursor()
  }

  private func blobSize(for workstream: AgentWorkstream) -> CGFloat {
    150 + CGFloat(min(workstream.threads.count, 8)) * 12
  }

  private func chipStatuses(_ counts: AgentStatusCounts) -> [AgentThreadStatus] {
    AgentThreadStatus.allCases.filter { counts.count(for: $0) > 0 }
  }

  @ViewBuilder
  private func chipRow(_ statuses: [AgentThreadStatus], counts: AgentStatusCounts) -> some View {
    if statuses.isEmpty {
      EmptyView()
    } else {
      HStack(spacing: 6) {
        ForEach(statuses, id: \.self) { status in
          statusChip(status, count: counts.count(for: status))
        }
      }
    }
  }

  private func statusChip(_ status: AgentThreadStatus, count: Int) -> some View {
    Text("\(count) \(status.displayName)")
      .font(.custom("Switzer", size: 10.5))
      .fontWeight(.medium)
      .foregroundColor(AgentsPalette.chipForeground(for: status))
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(AgentsPalette.chipBackground(for: status))
      .overlay(
        RoundedRectangle(cornerRadius: TBDTokens.Radius.xs)
          .strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline)
      )
      .clipShape(RoundedRectangle(cornerRadius: TBDTokens.Radius.xs))
  }

  // MARK: - Start review

  private var startReviewButton: some View {
    Button(action: onStartReview) {
      HStack(spacing: 6) {
        Text("Start review")
        Image(systemName: "arrow.right")
          .font(.system(size: 11, weight: .semibold))
      }
    }
    .buttonStyle(TBDButtonStyle(.primary))
    .pointingHandCursor()
  }
}
