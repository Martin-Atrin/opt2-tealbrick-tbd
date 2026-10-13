import AppKit
import Foundation
import TBDDesign
import SwiftUI
import UserNotifications

extension DailyView {
  var canFinishDailyProviderOnboarding: Bool {
    guard !(isRefreshingProviderAvailability && providerAvailability.isEmpty) else {
      return false
    }

    return selectedProviderAvailability.isAvailable
  }
  var selectedProviderAvailability: DailyRecapProviderAvailability {
    providerAvailability[dailyRecapProvider]
      ?? DailyRecapProviderAvailability(
        isAvailable: true,
        detail: dailyRecapProvider.pickerSubtitle
      )
  }
  var canRegenerateStandup: Bool {
    dailyRecapProvider.canGenerate
      && selectedProviderAvailability.isAvailable
      && standupRegenerateState != .regenerating
  }
  var regenerateButtonHelpText: String {
    if !dailyRecapProvider.canGenerate {
      return DailyStandupPlaceholder.noProviderSelectedMessage
    }

    if !selectedProviderAvailability.isAvailable {
      return selectedProviderAvailability.detail
    }

    return String(localized: "Regenerate standup highlights")
  }
  func dailyProviderButton(scale: CGFloat) -> some View {
    Button {
      if !isShowingProviderPicker {
        refreshProviderAvailability()
      }
      isShowingProviderPicker.toggle()
    } label: {
      Image(systemName: "gearshape.fill")
        .font(TBDFonts.symbol(13 * scale, .bold))
    }
    .buttonStyle(TBDButtonStyle(.secondary))
    .disabled(standupRegenerateState == .regenerating)
    .pointingHandCursorOnHover(
      enabled: standupRegenerateState != .regenerating,
      reassertOnPressEnd: true
    )
    .accessibilityLabel(Text("Choose daily recap provider"))
    .help("Daily recap provider: \(dailyRecapProvider.selectionLabel)")
    .popover(isPresented: $isShowingProviderPicker, arrowEdge: .bottom) {
      dailyProviderPicker(scale: scale)
        .padding(16)
        .frame(width: 312)
        .resolveDayflowTheme()
    }
  }
  func dailyProviderPicker(scale: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 12 * scale) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2 * scale) {
          Text("Daily recap provider")
            .font(TBDTokens.Typography.title)
            .foregroundStyle(TBDColor.ink)

          Text("Choose how Daily generates this recap, or turn generation off.")
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
            .foregroundStyle(TBDColor.muted)
        }

        Spacer(minLength: 0)

        if isRefreshingProviderAvailability {
          ProgressView()
            .controlSize(.small)
            .tint(TBDColor.tealInk)
        }
      }

      VStack(spacing: 8 * scale) {
        ForEach(DailyRecapProvider.allCases, id: \.self) { provider in
          let availability =
            providerAvailability[provider]
            ?? DailyRecapProviderAvailability(isAvailable: true, detail: provider.pickerSubtitle)
          let isSelected = dailyRecapProvider == provider

          Button {
            selectDailyRecapProvider(provider)
          } label: {
            HStack(alignment: .top, spacing: 10 * scale) {
              VStack(alignment: .leading, spacing: 2 * scale) {
                Text(provider.displayName)
                  .font(TBDTokens.Typography.label)
                  .foregroundStyle(TBDColor.ink)

                Text(availability.detail)
                  .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
                  .foregroundStyle(TBDColor.muted)
                  .multilineTextAlignment(.leading)
              }

              Spacer(minLength: 0)

              Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(TBDFonts.symbol(14 * scale, .bold))
                .foregroundStyle(isSelected ? TBDColor.tealInk : TBDColor.muted)
            }
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 10 * scale)
            .background(isSelected ? TBDColor.tealWash : TBDColor.tile, in: TBDBrickShape())
            .overlay(
              TBDBrickShape()
                .strokeBorder(isSelected ? TBDColor.tealWashLine : TBDColor.line, lineWidth: TBDKit.hair)
            )
            .contentShape(TBDBrickShape())
          }
          .buttonStyle(.plain)
          .disabled(!availability.isAvailable)
          .pointingHandCursorOnHover(enabled: availability.isAvailable, reassertOnPressEnd: true)
        }
      }
    }
  }
  func selectDailyRecapProvider(_ provider: DailyRecapProvider) {
    let previousProvider = dailyRecapProvider
    guard previousProvider != provider else {
      isShowingProviderPicker = false
      return
    }

    dailyRecapProvider = provider
    DailyRecapGenerator.shared.persistSelectedProvider(provider)
    isShowingProviderPicker = false
    standupRegenerateResetTask?.cancel()
    standupRegenerateResetTask = nil
    standupRegenerateState = .idle
    loadedStandupDraftDay = nil
    loadedStandupFallbackSourceDay = nil


    refreshWorkflowData()
  }
  func refreshProviderAvailability() {
    providerAvailabilityTask?.cancel()
    isRefreshingProviderAvailability = true

    providerAvailabilityTask = Task.detached(priority: .utility) {
      let snapshot = DailyRecapGenerator.shared.availabilitySnapshot()
      guard !Task.isCancelled else { return }

      await MainActor.run {
        providerAvailability = snapshot
        isRefreshingProviderAvailability = false
        providerAvailabilityTask = nil
      }
    }
  }
}
