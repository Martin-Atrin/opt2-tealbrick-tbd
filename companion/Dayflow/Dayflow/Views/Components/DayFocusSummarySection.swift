//
//  DayFocusSummarySection.swift
//  Dayflow
//
//  Focus section for the Day Summary right rail.
//

import SwiftUI
import TBDDesign

struct DayFocusSummarySection: View {
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter

  let totalFocusText: String
  let focusBlocks: [FocusBlock]
  let isSelectionEmpty: Bool
  let categories: [TimelineCategory]
  let selectedCategoryIDs: Set<UUID>
  let isEditingCategories: Bool
  var onEditCategories: () -> Void
  var onToggleCategory: (TimelineCategory) -> Void
  var onDoneEditing: () -> Void

  private enum Design {
    static let sectionSpacing: CGFloat = 12
    static let cardsSpacing: CGFloat = 8
    static let editButtonSize: CGFloat = 20
    static let editorWidth: CGFloat = 358
    static let editorOffsetX: CGFloat = -18
    static let editorOffsetY: CGFloat = 28
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Design.sectionSpacing) {
      header

      if isSelectionEmpty {
        Text("Edit categories to calculate focus.")
          .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
          .foregroundColor(TBDColor.muted)
      }

      VStack(spacing: Design.cardsSpacing) {
        TotalFocusCard(value: totalFocusText)

        LongestFocusCard(focusBlocks: focusBlocks)
      }
      .opacity(isSelectionEmpty ? 0.45 : 1)
    }
    .overlay(alignment: .topLeading) {
      if isEditingCategories {
        DayCategorySelectionEditor(
          categories: categories,
          selectedCategoryIDs: selectedCategoryIDs,
          helperText: String(localized: "Pick the categories that count towards Focus"),
          onToggle: onToggleCategory,
          onDone: onDoneEditing
        )
        .frame(width: Design.editorWidth, alignment: .leading)
        .offset(x: Design.editorOffsetX, y: Design.editorOffsetY)
        .onTapGesture {}
      }
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 6) {
      Text("Your focus")
        .font(TBDTokens.Typography.title)
        .foregroundColor(TBDColor.ink)

      if !stylePreviewAfter {
        Image(systemName: "info.circle")
          .font(TBDFonts.symbol(12, .regular))
          .foregroundColor(TBDColor.muted)
      }

      Spacer()

      CategoryEditCircleButton(
        action: onEditCategories,
        diameter: Design.editButtonSize
      )
    }
  }
}

private struct TotalFocusCard: View {
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter

  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text("Total focus time")
          .font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightNav))
          .foregroundColor(TBDColor.ink)

        if !stylePreviewAfter {
          Image(systemName: "info.circle")
            .font(TBDFonts.symbol(12, .regular))
            .foregroundColor(TBDColor.muted)
        }

        Spacer()
      }

      Text(value)
        .font(TBDTokens.Typography.display)
        .foregroundColor(TBDColor.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .daySummaryCard()
  }
}

// Summary card: tile, brick, hair line ring, flat (shared by the focus cards).
struct DaySummaryCardModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(TBDColor.tile, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }
}

extension View {
  func daySummaryCard() -> some View {
    modifier(DaySummaryCardModifier())
  }
}
