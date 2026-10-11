import SwiftUI
import MacParakeet

enum GitHubStarPromptState {
  static let hasShownKey = "hasShownGitHubStarPrompt"
  static let repositoryURL = URL(string: "https://github.com/jerryzliu/Dayflow")!

  static var hasShown: Bool {
    UserDefaults.standard.bool(forKey: hasShownKey)
  }

  static func markShown() {
    UserDefaults.standard.set(true, forKey: hasShownKey)
  }
}

enum GitHubStarService {
  static func starDayflow() async -> Bool {
    await Task.detached(priority: .userInitiated) {
      guard !GitHubStarPrompt.shouldUseBrowser else { return false }
      let result = LoginShellRunner.run(
        "gh api -X PUT user/starred/JerryZLiu/Tealbrick",
        timeout: 15
      )
      return result.exitCode == 0
    }.value
  }
}

struct GitHubStarPromptCard: View {
  @Environment(\.dayflowTheme) private var theme

  let onStar: () async -> Void
  let onDismiss: () -> Void
  @State private var isStarring = false

  var body: some View {
    VStack(spacing: 40) {
      VStack(spacing: 12) {
        Text("Your first card is ready!")
          .font(.custom("Switzer", size: 16).weight(.semibold))
          .foregroundStyle(theme.textPrimary)
          .frame(maxWidth: .infinity)

        Text("If you’re enjoying Tealbrick so far, a GitHub star helps other people discover it.")
          .font(.custom("Switzer", size: 14))
          .foregroundStyle(theme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      VStack(spacing: 11) {
        Button {
          guard !isStarring else { return }
          isStarring = true
          Task {
            await onStar()
            isStarring = false
          }
        } label: {
          HStack(spacing: 4) {
            if isStarring {
              ProgressView()
                .controlSize(.small)
                .tint(theme.primaryButtonText)
            } else {
              Image(systemName: "star")
                .font(.system(size: 14, weight: .medium))
            }
            Text(
              isStarring
                ? String(localized: "Starring…") : String(localized: "Give a star on GitHub")
            )
            .font(.custom("Switzer", size: 14).weight(.medium))
          }
          .foregroundStyle(theme.primaryButtonText)
          .frame(maxWidth: .infinity)
          .frame(height: 40)
          .background(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).fill(theme.primaryButtonFill))
          .overlay(
            RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(theme.primaryButtonBorder, lineWidth: TBDTokens.Stroke.hairline))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .allowsHitTesting(!isStarring)

        Button(action: onDismiss) {
          Text("Later")
            .font(.custom("Switzer", size: 14).weight(theme.isDark ? .medium : .regular))
            .foregroundStyle(theme.secondaryButtonText)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).fill(theme.secondaryButtonFill))
            .overlay(
              RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
                .strokeBorder(theme.secondaryButtonBorder, lineWidth: TBDTokens.Stroke.hairline)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }
    }
    .padding(20)
    .frame(width: 339)
    // Brick floating card: square, flat fill, hard offset shadow (no glass material, no blur).
    .background(
      RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
        .fill(theme.isDark ? Color(hex: "272F43") : Color(hex: "FFFBF9"))
    )
    .overlay(
      RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
        .strokeBorder(theme.isDark ? Color(hex: "5B5B5B") : Color(hex: "E3DAD1"), lineWidth: TBDTokens.Stroke.hairline)
    )
    .background(
      RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
        .fill(TBDTokens.ink.opacity(TBDTokens.Shadow.brickMd.opacity))
        .offset(x: TBDTokens.Shadow.brickMd.x, y: TBDTokens.Shadow.brickMd.y)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Star Tealbrick on GitHub")
  }
}
