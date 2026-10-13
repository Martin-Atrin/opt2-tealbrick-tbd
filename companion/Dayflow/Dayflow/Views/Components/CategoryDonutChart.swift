//
//  CategoryDonutChart.swift
//  Dayflow
//
//  A donut chart showing time breakdown by category using Swift Charts
//

import Charts
import SwiftUI
import TBDDesign

// MARK: - Data Model

struct CategoryTimeData: Identifiable {
  let id: String
  let name: String
  let colorHex: String
  let duration: TimeInterval  // in seconds

  init(id: String? = nil, name: String, colorHex: String, duration: TimeInterval) {
    self.id = id ?? Self.stableFallbackID(name: name, colorHex: colorHex)
    self.name = name
    self.colorHex = colorHex
    self.duration = duration
  }

  init(category: TimelineCategory, duration: TimeInterval) {
    self.id = category.id.uuidString
    self.name = category.name
    self.colorHex = category.colorHex
    self.duration = duration
  }

  private static func stableFallbackID(name: String, colorHex: String) -> String {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedColor = colorHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return "\(normalizedName)|\(normalizedColor)"
  }

  var color: Color {
    if let nsColor = NSColor(hex: colorHex) {
      return Color(nsColor: nsColor)
    }
    return TBDColor.toneStone
  }

  var formattedDuration: String {
    let totalMinutes = Int(duration / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0 && minutes > 0 {
      return "\(hours)h \(minutes)m"
    } else if hours > 0 {
      return "\(hours)h"
    } else {
      return "\(minutes)m"
    }
  }
}

// MARK: - Main View

struct CategoryDonutChart: View {
  let data: [CategoryTimeData]
  let size: CGFloat

  init(data: [CategoryTimeData], size: CGFloat = 205) {
    self.data = data
    self.size = size
  }

  private var totalDuration: TimeInterval {
    data.reduce(0) { $0 + $1.duration }
  }

  private var formattedTotal: (hours: Int, minutes: Int) {
    let totalMinutes = Int(totalDuration / 60)
    return (totalMinutes / 60, totalMinutes % 60)
  }

  var body: some View {
    VStack(spacing: 24) {
      // Donut chart
      donutChart

      // Legend grid
      legendGrid
    }
  }

  // MARK: - Donut Chart

  private var donutChart: some View {
    // Flat kit donut: plate track, flat sectors in the category colours, tile hole.
    let chartSize = size - 4
    let innerRadiusRatio: CGFloat = 0.75
    let innerGap: CGFloat = 6

    return ZStack {
      Circle()
        .fill(TBDColor.plate)
        .overlay(Circle().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
        .frame(width: size, height: size)

      sectorChart()
        .frame(width: chartSize, height: chartSize)

      Circle()
        .fill(TBDColor.tile)
        .frame(
          width: chartSize * innerRadiusRatio - innerGap,
          height: chartSize * innerRadiusRatio - innerGap)

      // Center content
      centerContent
    }
    .frame(width: size, height: size)
  }

  /// The donut's sector geometry.
  private func sectorChart() -> some View {
    Chart(data) { item in
      SectorMark(
        angle: .value("Duration", item.duration),
        innerRadius: .ratio(0.75),
        outerRadius: .automatic,
        angularInset: 1.5
      )
      .cornerRadius(TBDKit.radiusBrick)
      .foregroundStyle(item.color)
    }
    .chartLegend(.hidden)
  }

  private var centerContent: some View {
    VStack(spacing: 4) {
      Text("Total")
        .font(TBDFonts.nunito(12, TBDKit.weightLabel))
        .foregroundStyle(TBDColor.muted)

      VStack(spacing: 0) {
        let total = formattedTotal
        Text("\(total.hours) hours")
          .font(TBDFonts.nunito(TBDKit.textBody, TBDKit.weightNav))
          .foregroundStyle(TBDColor.ink)
        Text("\(total.minutes) minutes")
          .font(TBDFonts.nunito(TBDKit.textBody, TBDKit.weightNav))
          .foregroundStyle(TBDColor.ink)
      }
    }
  }

  // MARK: - Legend Grid

  private var legendGrid: some View {
    let columns = Array(repeating: GridItem(.fixed(84.667), spacing: 14), count: 3)

    return LazyVGrid(columns: columns, spacing: 12) {
      ForEach(data) { item in
        legendItem(for: item)
      }
    }
  }

  private func legendItem(for item: CategoryTimeData) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      // Color indicator + name row
      HStack(spacing: 4) {
        // Colored swatch with border
        RoundedRectangle(cornerRadius: TBDKit.radiusSwatch)
          .fill(item.color)
          .overlay(
            RoundedRectangle(cornerRadius: TBDKit.radiusSwatch)
              .strokeBorder(TBDColor.lineStrong, lineWidth: 1)
          )
          .frame(width: 10.667, height: 8)

        // Category name
        Text(item.name)
          .font(TBDFonts.nunito(10, TBDKit.weightBody))
          .foregroundStyle(TBDColor.inkSoft)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(width: 70, alignment: .leading)
      }

      // Duration
      Text(item.formattedDuration)
        .font(TBDFonts.nunito(12, TBDKit.weightNav))
        .foregroundStyle(TBDColor.ink)
        .padding(.leading, 14)  // Align with text above
    }
    .frame(width: 84.667, alignment: .leading)
  }
}

// MARK: - Preview

#Preview("Category Donut Chart") {
  // Dummy data matching the Figma design
  let previewData: [CategoryTimeData] = [
    CategoryTimeData(name: "Personal", colorHex: "#6AADFF", duration: 92 * 60),  // 1h 32m - blue
    CategoryTimeData(name: "Personal", colorHex: "#FF5950", duration: 45 * 60),  // 45m - red
    CategoryTimeData(name: "Long category title", colorHex: "#88E5DF", duration: 152 * 60),  // 2h 32m - teal
    CategoryTimeData(name: "Learning", colorHex: "#5650FF", duration: 32 * 60),  // 32m - purple
    CategoryTimeData(name: "Personal", colorHex: "#B984FF", duration: 204 * 60),  // 3h 24m - light purple
    CategoryTimeData(name: "Personal", colorHex: "#E2E2E2", duration: 152 * 60),  // 2h 32m - gray
  ]

  CategoryDonutChart(data: previewData)
    .padding(40)
    .background(TBDColor.paper)
}

#Preview("Empty State") {
  CategoryDonutChart(data: [])
    .padding(40)
    .background(TBDColor.paper)
}
