//
//  SetupSidebarView.swift
//  Dayflow
//
//  Sidebar navigation for LLM provider setup flow
//

import TBDDesign
import SwiftUI

struct SetupSidebarView: View {
  let steps: [SetupStep]
  let currentStepId: String
  let onStepSelected: (String) -> Void

  @Namespace private var selectionNamespace

  var body: some View {
    // Just the steps list - no extra VStack or ScrollView
    VStack(alignment: .leading, spacing: 24) {
      ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
        SetupSidebarItem(
          title: step.title,
          isSelected: step.id == currentStepId,
          isCompleted: isStepCompleted(step: step, currentId: currentStepId, in: steps),
          namespace: selectionNamespace,
          onTap: {
            onStepSelected(step.id)
          }
        )
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func isStepCompleted(step: SetupStep, currentId: String, in steps: [SetupStep]) -> Bool {
    guard let currentIndex = steps.firstIndex(where: { $0.id == currentId }),
      let stepIndex = steps.firstIndex(where: { $0.id == step.id })
    else {
      return false
    }
    return stepIndex < currentIndex || step.isCompleted
  }
}

struct SetupSidebarItem: View {
  let title: String
  let isSelected: Bool
  let isCompleted: Bool
  let namespace: Namespace.ID
  let onTap: () -> Void

  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: onTap) {
      Group {
        if isSelected {
          HStack(alignment: .center, spacing: 8) {
            Image(systemName: "chevron.right")
              .font(TBDFonts.symbol(15, .bold))
              .foregroundColor(TBDColor.ink)
              .frame(width: 20, height: 20)

            itemLabel

            Spacer(minLength: 0)
          }
          .padding(.leading, 10)
          .padding(.trailing, 16)
          .padding(.vertical, 10)
          .background(selectedBackground)
        } else if isCompleted {
          HStack(alignment: .center, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .font(TBDFonts.symbol(15, .bold))
              .foregroundColor(TBDColor.tealInk)
              .frame(width: 16, height: 16)

            itemLabel
          }
          .padding(.leading, 14)
        } else {
          // Upcoming step: bare label aligned with the other labels (10+20+8 / 14+16+8 = 38)
          itemLabel
            .padding(.leading, 38)
        }
      }
      .frame(maxWidth: .infinity, minHeight: TBDTokens.Control.minHeight, alignment: .leading)
      .background(isHovered && !isSelected ? TBDColor.plate : Color.clear, in: TBDBrickShape())
      .contentShape(TBDBrickShape())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .animation(TBDMotion.animation(TBDMotion.spring, reduce: reduceMotion), value: isSelected)
    .animation(TBDMotion.animation(TBDMotion.quick, reduce: reduceMotion), value: isHovered)
    .onHover { hovering in
      isHovered = hovering
    }
  }

  private var itemLabel: some View {
    Text(title)
      .font(TBDFonts.nunito(TBDKit.textLabel, isSelected ? TBDKit.weightLabel : TBDKit.weightNav))
      .foregroundColor(isSelected || isCompleted ? TBDColor.ink : TBDColor.muted)
  }

  private var selectedBackground: some View {
    // Selection: a soft brick in teal wash (the kit rail selection).
    TBDRailSelection()
      .matchedGeometryEffect(id: "selection", in: namespace)
  }
}
