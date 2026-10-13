//
//  CardsToReviewBadge.swift
//  Dayflow
//
//  Pill badge showing number of cards to review with stacked cards icon
//

import SwiftUI
import TBDDesign

struct CardsToReviewBadge: View {
  let count: Int

  var body: some View {
    HStack(alignment: .center, spacing: 6) {
      // Stacked cards icon with number
      stackedCardsIcon

      // Label text
      Text("Review cards")
        .font(TBDFonts.nunito(10, TBDKit.weightNav))
        .foregroundStyle(TBDColor.primaryOn)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("\(count) cards to review"))
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(TBDColor.primaryFill, in: TBDBrickShape())
  }

  private var stackedCardsIcon: some View {
    ZStack(alignment: .bottom) {
      // Back card (rotated, behind) - 15.75 x 14 (h x w)
      // Positioned so leftmost point pokes out only 3px
      RoundedRectangle(cornerRadius: TBDKit.radiusSwatch)
        .fill(TBDColor.plate)
        .frame(width: 14, height: 15.75)
        .rotationEffect(.degrees(-11.64))
        .offset(x: -3, y: 0)

      // Front card with number - 18 x 14 (h x w)
      ZStack {
        RoundedRectangle(cornerRadius: TBDKit.radiusSwatch)
          .fill(TBDColor.tile)
      }
      .frame(width: 14, height: 18)
      .overlay(
        RoundedRectangle(cornerRadius: TBDKit.radiusSwatch)
          .strokeBorder(TBDColor.brick, lineWidth: 1.25)
      )
      .overlay(
        Text("\(count)")
          .font(TBDFonts.nunito(9, TBDKit.weightLabel))
          .foregroundStyle(TBDColor.brickInk)
      )
      .offset(x: 4, y: 0)
    }
    .frame(width: 21, height: 20)
  }
}

// MARK: - Interactive Button (Emil Kowalski-style)

struct CardsToReviewButton: View {
  let count: Int
  let action: () -> Void

  @State private var isPressed = false
  @State private var isHovered = false

  var body: some View {
    CardsToReviewBadge(count: count)
      .dayflowPressScale(
        isPressed,
        pressedScale: 0.97,
        animation: TBDMotion.spring
      )
      .scaleEffect(isHovered ? 1.02 : 1.0)
      .animation(TBDMotion.spring, value: isHovered)
      .onHover { hovering in
        isHovered = hovering
      }
      .onTapGesture {
        // Haptic-like visual feedback
        withAnimation(TBDMotion.spring) {
          isPressed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          withAnimation(TBDMotion.spring) {
            isPressed = false
          }
          action()
        }
      }
      .onLongPressGesture(
        minimumDuration: .infinity,
        pressing: { pressing in
          withAnimation(TBDMotion.spring) {
            isPressed = pressing
          }
        }, perform: {}
      )
      .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }
}

// MARK: - Preview

#Preview("Cards to Review Badge") {
  CardsToReviewBadgePreview()
}

private struct CardsToReviewBadgePreview: View {
  @State private var count: Int = 10

  var body: some View {
    VStack(spacing: 40) {
      // The badge
      CardsToReviewBadge(count: count)

      // Controls
      VStack(spacing: 16) {
        Text("Count: \(count)")
          .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightNav))
          .foregroundStyle(TBDColor.muted)

        HStack(spacing: 12) {
          Button("1") { count = 1 }
          Button("5") { count = 5 }
          Button("10") { count = 10 }
          Button("99") { count = 99 }
        }
        .buttonStyle(TBDButtonStyle(.secondary))

        Slider(
          value: Binding(
            get: { Double(count) },
            set: { count = Int($0) }
          ), in: 1...99, step: 1
        )
        .frame(width: 200)
      }
      .padding()
      .background(TBDColor.plate, in: TBDBrickShape())
    }
    .padding(60)
    .background(TBDColor.paper)
  }
}
