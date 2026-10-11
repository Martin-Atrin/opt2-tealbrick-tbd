import MacParakeet
import SwiftUI

struct DailyAccessIntroView: View {
  @Environment(\.dayflowTheme) private var theme

  let betaNoticeCopy: String
  let progressText: String
  let canRequestAccess: Bool
  let onRequestAccess: () -> Void
  let onConfettiStart: () -> Void

  @State private var requestState: DailyAccessRequestState = .idle
  @State private var showsSuccessRing = false
  @State private var transitionTask: Task<Void, Never>? = nil

  private var stateChangeAnimation: Animation {
    .easeInOut(duration: 0.26)
  }

  private var successRingAnimation: Animation {
    .easeOut(duration: 0.24)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
      HStack { TBDLabel("Unlocks after 5 hours of analyzed timeline"); Spacer(); TBDChip("Beta", color: TBDTokens.accent) }
      Text("Turn your day into a standup update")
        .font(TBDTokens.Typography.display).tracking(TBDTokens.Typography.displayTracking)
        .foregroundStyle(TBDTokens.ink)
      Text(betaNoticeCopy)
        .font(TBDTokens.Typography.body)
        .foregroundStyle(TBDTokens.muted)
        .fixedSize(horizontal: false, vertical: true)
      Text(progressText)
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .foregroundStyle(TBDTokens.ink)

      DailyAnimatedRequestAccessButton(
        requestState: requestState,
        showsSuccessRing: showsSuccessRing,
        isEnabled: canRequestAccess,
        stateChangeAnimation: stateChangeAnimation,
        successRingAnimation: successRingAnimation,
        onTap: animateRequestGranted
      )
    }
    .frame(maxWidth: 620, alignment: .leading)
    .tbdCard(padding: TBDTokens.Space.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onDisappear {
      transitionTask?.cancel()
      transitionTask = nil
    }
  }

  private func animateRequestGranted() {
    guard canRequestAccess else { return }
    guard requestState == .idle else { return }

    withAnimation(stateChangeAnimation) {
      requestState = .granted
    }

    withAnimation(successRingAnimation) {
      showsSuccessRing = true
    }

    onConfettiStart()

    transitionTask?.cancel()
    transitionTask = Task {
      let delayNanoseconds: UInt64 = 1_120_000_000
      try? await Task.sleep(nanoseconds: delayNanoseconds)

      guard !Task.isCancelled else { return }
      await MainActor.run {
        onRequestAccess()
      }
    }
  }
}

struct DailyNotificationOnboardingView: View {
  @Environment(\.dayflowTheme) private var theme

  let notificationPermissionMessage: String
  let notificationPermissionButtonTitle: String
  let isNotificationPermissionButtonDisabled: Bool
  let isNotificationRecheckButtonDisabled: Bool
  let onNotificationPermissionAction: () -> Void
  let onRecheckPermissions: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      DailyAccessHeaderView()

      DailyNotificationPermissionPanelView(
        notificationPermissionMessage: notificationPermissionMessage,
        notificationPermissionButtonTitle: notificationPermissionButtonTitle,
        isNotificationPermissionButtonDisabled: isNotificationPermissionButtonDisabled,
        isNotificationRecheckButtonDisabled: isNotificationRecheckButtonDisabled,
        onNotificationPermissionAction: onNotificationPermissionAction,
        onRecheckPermissions: onRecheckPermissions
      )
    }
  }
}

struct DailyProviderOnboardingView: View {
  @Environment(\.dayflowTheme) private var theme

  let selectedProvider: DailyRecapProvider
  let providerAvailability: [DailyRecapProvider: DailyRecapProviderAvailability]
  let isRefreshingProviderAvailability: Bool
  let canContinue: Bool
  let onSelectProvider: (DailyRecapProvider) -> Void
  let onContinue: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      DailyAccessHeaderView()

      VStack(spacing: 12) {
        VStack(spacing: 6) {
          Text("Pick your Daily provider")
            .font(.custom("Switzer-Medium", size: 24))
            .foregroundColor(theme.textPrimary)
            .multilineTextAlignment(.center)

          Text(
            "Choose how Daily generates your recap, or turn generation off. You can change this later."
          )
          .font(.custom("Switzer-Regular", size: 13))
          .foregroundColor(theme.textSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
        }

        if isRefreshingProviderAvailability {
          ProgressView()
            .controlSize(.small)
            .tint(theme.accent)
        }

        VStack(spacing: 6) {
          ForEach(DailyRecapProvider.allCases, id: \.self) { provider in
            let availability =
              providerAvailability[provider]
              ?? DailyRecapProviderAvailability(
                isAvailable: true,
                detail: provider.pickerSubtitle
              )
            let isSelected = selectedProvider == provider

            Button {
              onSelectProvider(provider)
            } label: {
              HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(provider.displayName)
                    .font(.custom("Switzer-Semibold", size: 13))
                    .foregroundStyle(theme.textPrimary)

                  Text(availability.detail)
                    .font(.custom("Switzer-Regular", size: 11))
                    .foregroundStyle(
                      availability.isAvailable ? theme.textSecondary : theme.textMuted
                    )
                    .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                  .font(.system(size: 13, weight: .semibold))
                  .foregroundStyle(isSelected ? theme.accent : theme.textMuted)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(isSelected ? theme.controlFill : theme.chipFill)
              .overlay(
                RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
                  .stroke(
                    isSelected ? theme.controlBorder : theme.chipBorder,
                    lineWidth: 1
                  )
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!availability.isAvailable)
            .pointingHandCursor(enabled: availability.isAvailable)
          }
        }

        DayflowSurfaceButton(
          action: onContinue,
          content: {
            Text("Continue to Daily")
              .font(.custom("Switzer", size: 14))
              .fontWeight(.semibold)
          },
          background: theme.primaryButtonFill,
          foreground: theme.primaryButtonText,
          borderColor: .clear,
          cornerRadius: TBDTokens.Radius.base,
          horizontalPadding: 20,
          verticalPadding: 10,
          showOverlayStroke: true
        )
        .disabled(!canContinue)
        .pointingHandCursor(enabled: canContinue)
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 24)
      .frame(maxWidth: 460)
      .background(theme.summaryCardFill)
      .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).stroke(theme.summaryCardBorder, lineWidth: 1))
    }
  }
}

private struct DailyAccessHeaderView: View {
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    HStack(alignment: .top, spacing: 4) {
      Text("Tealbrick Daily")
        .font(.custom("Switzer-Medium", size: 38))
        .foregroundColor(theme.textPrimary)

      Text("BETA")
        .font(.custom("Switzer-Bold", size: 11))
        .foregroundColor(theme.primaryButtonText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: TBDTokens.Radius.xs)
            .fill(CompanionPalette.fill)
        )
        .rotationEffect(.degrees(-12))
        .offset(x: -4, y: -4)
    }
  }
}

private enum DailyAccessRequestState {
  case idle
  case granted
}

private struct DailyAnimatedRequestAccessButton: View {
  let requestState: DailyAccessRequestState
  let showsSuccessRing: Bool
  let isEnabled: Bool
  let stateChangeAnimation: Animation
  let successRingAnimation: Animation
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      ZStack {
        // Brick: square ring in place of the donor capsule glow.
        RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
          .stroke(TBDTokens.ink.opacity(0.24), lineWidth: 1.5)
          .scaleEffect(showsSuccessRing ? 1.08 : 0.96)
          .opacity(showsSuccessRing ? 0 : 0.65)

        ZStack {
          Text("Unlock Daily")
            .font(.custom("Switzer", size: 15))
            .fontWeight(.semibold)
            .opacity(requestState == .idle ? 1 : 0)
            .offset(y: requestState == .idle ? 0 : -5)

          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 14, weight: .semibold))
            Text("Daily Unlocked")
              .font(.custom("Switzer", size: 15))
              .fontWeight(.semibold)
          }
          .opacity(requestState == .granted ? 1 : 0)
          .offset(y: requestState == .granted ? 0 : 5)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 13)
      }
      .compositingGroup()
      .fixedSize()
      .animation(stateChangeAnimation, value: requestState)
      .animation(successRingAnimation, value: showsSuccessRing)
    }
    // Brick: fill/border/hover-lift/disabled-opacity all come from the
    // primary button style now — no more manual bg + double shadow.
    .buttonStyle(TBDButtonStyle(.primary))
    .disabled(requestState == .granted || !isEnabled)
    .pointingHandCursor(enabled: requestState == .idle && isEnabled)
  }
}

private struct DailyNotificationPermissionPanelView: View {
  @Environment(\.dayflowTheme) private var theme

  let notificationPermissionMessage: String
  let notificationPermissionButtonTitle: String
  let isNotificationPermissionButtonDisabled: Bool
  let isNotificationRecheckButtonDisabled: Bool
  let onNotificationPermissionAction: () -> Void
  let onRecheckPermissions: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Text("Turn on notifications to unlock Daily")
        .font(.custom("Switzer-Medium", size: 30))
        .foregroundColor(theme.textPrimary)
        .multilineTextAlignment(.center)

      Text("Tealbrick uses notifications to tell you when your recap is ready.")
        .font(.custom("Switzer-Semibold", size: 16))
        .foregroundColor(theme.textPrimary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)

      Text(notificationPermissionMessage)
        .font(.custom("Switzer-Regular", size: 14))
        .foregroundColor(theme.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 430)

      VStack(spacing: 10) {
        DayflowSurfaceButton(
          action: onNotificationPermissionAction,
          content: {
            Text(notificationPermissionButtonTitle)
              .font(.custom("Switzer", size: 15))
              .fontWeight(.semibold)
          },
          background: theme.primaryButtonFill,
          foreground: theme.primaryButtonText,
          borderColor: .clear,
          cornerRadius: TBDTokens.Radius.base,
          horizontalPadding: 24,
          verticalPadding: 12,
          showOverlayStroke: true
        )
        .disabled(isNotificationPermissionButtonDisabled)
        .pointingHandCursor(enabled: !isNotificationPermissionButtonDisabled)

        DayflowSurfaceButton(
          action: onRecheckPermissions,
          content: {
            Text("Recheck permissions")
              .font(.custom("Switzer", size: 14))
              .fontWeight(.semibold)
          },
          background: theme.secondaryButtonFill,
          foreground: theme.secondaryButtonText,
          borderColor: theme.secondaryButtonBorder,
          cornerRadius: TBDTokens.Radius.base,
          horizontalPadding: 20,
          verticalPadding: 11,
          isSecondaryStyle: true
        )
        .disabled(isNotificationRecheckButtonDisabled)
        .pointingHandCursor(enabled: !isNotificationRecheckButtonDisabled)
      }
    }
    .padding(.horizontal, 34)
    .padding(.vertical, 30)
    .frame(maxWidth: 560)
    .background(theme.summaryCardFill)
    .overlay(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).stroke(theme.summaryCardBorder, lineWidth: 1))
  }
}

// Keep disabled access requirements readable; their subdued fill signals the state.
struct AccessButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
  }
}
