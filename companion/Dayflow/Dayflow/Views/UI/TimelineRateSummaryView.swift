//
//  TimelineRateSummaryView.swift
//  Dayflow
//
//  Lightweight footer for rating a generated summary.
//

import TBDDesign
import SwiftUI

enum TimelineRatingDirection: String, Codable, Sendable {
  case up
  case down
}

private enum TimelineDeleteButtonState: Equatable {
  case idle
  case confirming
  case deleting
}

struct ThumbRatingButtons: View {
  var selectedDirection: TimelineRatingDirection?
  var isEnabled: Bool = true
  var onRate: (TimelineRatingDirection) -> Void

  var body: some View {
    // 22pt glyph boxes with a 36pt hit area each (7pt hit margin, 14pt pitch gap).
    HStack(spacing: 14) {
      rateButton(for: .up)
      rateButton(for: .down)
    }
  }

  @ViewBuilder
  private func rateButton(for direction: TimelineRatingDirection) -> some View {
    let isSelected = selectedDirection == direction
    Button(action: {
      guard isEnabled else { return }
      onRate(direction)
    }) {
      Image("ThumbsUp")
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 14, height: 14)
        .scaleEffect(x: direction == .down ? -1 : 1, y: direction == .down ? -1 : 1)
        .foregroundStyle(isSelected ? TBDColor.tealInk : TBDColor.muted)
        .padding(4)
        .frame(width: 22, height: 22)
        .background(
          TBDBrickShape()
            .fill(isSelected ? TBDColor.tealWash : Color.clear)
        )
        .contentShape(Rectangle().inset(by: -7))
    }
    .buttonStyle(.plain)
    .pointingHandCursorOnHover(enabled: isEnabled, reassertOnPressEnd: true)
    .accessibilityLabel(direction == .up ? Text("Thumbs up") : Text("Thumbs down"))
  }
}

struct TimelineRateSummaryView: View {

  var title: String = String(localized: "Rate this summary")
  var isEnabled: Bool = true
  var activityID: String? = nil
  var onRate: ((TimelineRatingDirection) -> Void)? = nil
  var onDelete: (() -> Void)? = nil

  @State private var selectedDirection: TimelineRatingDirection? = nil
  @State private var deleteButtonState: TimelineDeleteButtonState = .idle
  @State private var deleteResetTask: Task<Void, Never>? = nil

  private var canDelete: Bool {
    isEnabled && onDelete != nil && deleteButtonState != .deleting
  }

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      HStack(spacing: 8) {
        Text(title)
          .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav))
          .foregroundStyle(TBDColor.muted)

        ThumbRatingButtons(selectedDirection: selectedDirection, isEnabled: isEnabled) {
          direction in
          withAnimation(TBDMotion.spring) {
            selectedDirection = direction
          }
          onRate?(direction)
        }
      }

      Spacer(minLength: 0)

      if onDelete != nil {
        deleteButton
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(TBDColor.tile)
    .overlay(alignment: .top) {
      Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
    }
    .opacity(isEnabled ? 1 : 0.6)
    .onChange(of: activityID) {
      selectedDirection = nil
      deleteResetTask?.cancel()
      deleteButtonState = .idle
    }
    .onDisappear {
      deleteResetTask?.cancel()
    }
  }

  private var deleteButton: some View {
    let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.5))
    let idleText = TBDColor.dangerInk
    let confirmBackground = TBDColor.dangerConfirmFill
    let isConfirmVisualState = deleteButtonState != .idle

    return Button(action: handleDeleteTap) {
      ZStack {
        if deleteButtonState == .deleting {
          ProgressView()
            .scaleEffect(0.55)
            .progressViewStyle(CircularProgressViewStyle(tint: TBDColor.dangerConfirmOn))
            .transition(transition)
        } else if deleteButtonState == .confirming {
          Text("Confirm")
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav))
            .transition(transition)
        } else {
          Text("Delete")
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav))
            .transition(transition)
        }
      }
      .padding(.horizontal, isConfirmVisualState ? 9 : 0)
      .frame(height: 18)
      .foregroundStyle(isConfirmVisualState ? TBDColor.dangerConfirmOn : idleText)
      .background(
        TBDBrickShape()
          .fill(isConfirmVisualState ? confirmBackground : Color.clear)
      )
      // Keep the visual compact while expanding the click target.
      .contentShape(Rectangle().inset(by: -6))
    }
    .frame(height: 22, alignment: .center)
    .buttonStyle(.plain)
    .disabled(!canDelete)
    .pointingHandCursorOnHover(enabled: canDelete, reassertOnPressEnd: true)
    .animation(TBDMotion.quick, value: deleteButtonState)
    .accessibilityLabel(
      Text(
        deleteButtonState == .confirming
          ? String(localized: "Confirm delete activity card")
          : String(localized: "Delete activity card")
      )
    )
  }

  private func handleDeleteTap() {
    guard onDelete != nil, isEnabled else { return }

    deleteResetTask?.cancel()

    switch deleteButtonState {
    case .idle:
      withAnimation(TBDMotion.quick) {
        deleteButtonState = .confirming
      }
      deleteResetTask = Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard deleteButtonState == .confirming else { return }
          withAnimation(TBDMotion.quick) {
            deleteButtonState = .idle
          }
        }
      }
    case .confirming:
      withAnimation(TBDMotion.quick) {
        deleteButtonState = .deleting
      }
      onDelete?()
      deleteResetTask = Task {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard deleteButtonState == .deleting else { return }
          withAnimation(TBDMotion.quick) {
            deleteButtonState = .idle
          }
        }
      }
    case .deleting:
      break
    }
  }

}

#Preview("TimelineRateSummaryView", traits: .sizeThatFitsLayout) {
  TimelineRateSummaryView()
    .padding()
}
