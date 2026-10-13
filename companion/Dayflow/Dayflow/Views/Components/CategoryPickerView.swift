//
//  CategoryPickerView.swift
//  Dayflow
//

import SwiftUI
import TBDDesign

struct CategoryPickerView: View {
  let currentCategory: String
  let categories: [TimelineCategory]
  var onCategorySelected: (TimelineCategory) -> Void
  var onNavigateToEditor: () -> Void

  var body: some View {
    GeometryReader { geometry in
      VStack(alignment: .leading, spacing: 0) {
        // Category pills section - wrap to as many rows as needed
        WrappingHStack(categories, spacing: 4, width: geometry.size.width - 16) { category in
          CategoryPill(
            category: category,
            isSelected: isCategorySelected(category),
            onTap: { onCategorySelected(category) }
          )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)

        // Divider - using a custom line with specific styling
        Rectangle()
          .fill(TBDColor.line)
          .frame(height: TBDKit.hair)

        // Helper text section
        VStack(alignment: .leading, spacing: 10) {
          ZStack(alignment: .topLeading) {
            // Main text
            HStack(alignment: .top, spacing: 0) {
              Text(
                "To help Tealbrick organize your activities more accurately, try adding more details to the descriptions in your categories "
              )
              .font(TBDFonts.nunito(10, TBDKit.weightNav))
              .foregroundStyle(helperTextColor)

              Button(action: onNavigateToEditor) {
                Text("here")
                  .font(TBDFonts.nunito(10, TBDKit.weightNav))
                  .foregroundStyle(TBDColor.tealInk)
                  .underline()
              }
              .buttonStyle(.plain)
              .pointingHandCursor()

              Text(".")
                .font(TBDFonts.nunito(10, TBDKit.weightNav))
                .foregroundStyle(helperTextColor)
            }
            .padding(.leading, 2.188)

            // Lightbulb icon overlaid
            Image(systemName: "lightbulb.fill")
              .font(TBDFonts.symbol(7, TBDKit.weightBody))
              .foregroundStyle(TBDColor.muted)
              .offset(x: 0, y: 2)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .tbdFloating()
    .overlay(alignment: .topTrailing) {
      // Done button in the top right corner (kit icon button, 36pt hit area)
      Button(action: {}) {
        Image(systemName: "checkmark")
          .font(TBDFonts.symbol(11, TBDKit.weightLabel))
      }
      .buttonStyle(TBDButtonStyle(.icon))
      .accessibilityLabel("Done")
    }
  }

  private var helperTextColor: Color {
    TBDColor.muted
  }

  private func isCategorySelected(_ category: TimelineCategory) -> Bool {
    let currentNormalized = currentCategory.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let categoryNormalized = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return currentNormalized == categoryNormalized
  }
}

struct CategoryPill: View {
  let category: TimelineCategory
  let isSelected: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 4) {
        // Colored dot
        Circle()
          .fill(categoryColor)
          .frame(width: 8, height: 8)

        // Category name - no line limit, text can wrap if needed
        Text(category.name)
          .font(TBDFonts.nunito(10, TBDKit.weightNav))
          .foregroundStyle(isSelected ? TBDColor.tealInk : TBDColor.ink)
          .fixedSize(horizontal: false, vertical: true)
          .lineLimit(nil)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(isSelected ? TBDColor.tealWash : TBDColor.tile, in: Capsule())
      .tbdPillEdge(isSelected ? TBDColor.tealWashLine : (category.isIdle ? Color.clear : TBDColor.line))
      .overlay {
        if category.isIdle && !isSelected {
          // Dashed edge for the Idle category
          Capsule().strokeBorder(
            TBDColor.lineStrong, style: StrokeStyle(lineWidth: TBDKit.hair, dash: [4, 3]))
        }
      }
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  private var categoryColor: Color {
    if let nsColor = NSColor(hex: category.colorHex) {
      return Color(nsColor: nsColor)
    }
    return TBDColor.toneStone
  }
}
