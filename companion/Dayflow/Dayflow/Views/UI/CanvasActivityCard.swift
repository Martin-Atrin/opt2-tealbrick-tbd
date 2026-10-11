import MacParakeet
import SwiftUI

struct CanvasActivityCardStyle {
  let text: Color
  let time: Color
  let accent: Color
  let isIdle: Bool
}

struct CanvasActivityCard: View {
  @Environment(\.dayflowTheme) private var theme
  @AppStorage("showTimelineAppIcons") private var showTimelineAppIcons: Bool = true
  @State private var isHovering = false

  let title: String
  let time: String
  let height: CGFloat
  let durationMinutes: Double
  let style: CanvasActivityCardStyle
  let isSelected: Bool
  let isSystemCategory: Bool
  let isBackupGenerated: Bool
  let onTap: () -> Void
  // Raw values for pattern matching (may contain paths)
  let faviconPrimaryRaw: String?
  let faviconSecondaryRaw: String?
  // Normalized hosts for network fetch
  let faviconPrimaryHost: String?
  let faviconSecondaryHost: String?
  let statusLine: String?
  let failureCount: Int
  let fontSize: CGFloat
  let fontWeight: TimelineCardTextWeight
  let iconLeadingInset: CGFloat
  let iconTextSpacing: CGFloat
  let faviconSize: CGFloat
  let faviconVerticalOffset: CGFloat
  let compactDurationThreshold: CGFloat
  let compactVerticalPadding: CGFloat
  let normalVerticalPadding: CGFloat
  let hoverScale: CGFloat
  let pressedScale: CGFloat

  private var isFailedCard: Bool {
    title == "Processing failed"
  }

  private var displayTitle: String {
    guard isFailedCard else { return title }
    let failedTitle = String(localized: "Processing failed")
    guard failureCount > 1 else { return failedTitle }
    return String(localized: "\(failedTitle) · \(failureCount) intervals")
  }

  private var isCompactCard: Bool {
    durationMinutes < Double(compactDurationThreshold)
  }

  private var verticalPadding: CGFloat {
    guard !isFailedCard else { return 0 }
    return isCompactCard ? compactVerticalPadding : normalVerticalPadding
  }

  private var secondaryFontSize: CGFloat {
    TimelineTypography.cardSecondaryTextFontSize(for: fontSize)
  }

  private var backupIndicator: some View {
    Text("!")
      .font(Font.custom("Switzer", size: 9).weight(.semibold))
      .foregroundColor(theme.textSecondary)
      .frame(width: 14, height: 14)
      .background(
        RoundedRectangle(cornerRadius: TBDTokens.Radius.xs)
          .fill(theme.chipFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: TBDTokens.Radius.xs)
          .stroke(theme.chipBorder, lineWidth: 0.75)
      )
      .help(
        "This card fell back to a lower-quality Gemini model due to rate limiting, so output quality may be lower."
      )
  }

  private var selectionStroke: Color {
    if isSystemCategory {
      return Color(red: 1, green: 0.16, blue: 0.11)
    }
    return style.accent
  }

  var body: some View {
    Button(action: {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
        onTap()
      }
    }) {
      HStack(alignment: .top, spacing: isFailedCard ? 10 : iconTextSpacing) {
        if durationMinutes >= 10 {
          if isFailedCard {
            VStack(alignment: .leading, spacing: 4) {
              HStack(alignment: .top, spacing: 8) {
                Text(displayTitle)
                  .font(
                    Font.custom("Switzer", size: fontSize)
                      .weight(fontWeight.fontWeight)
                  )
                  .foregroundColor(style.text)

                Spacer()

                Text(time)
                  .font(
                    Font.custom("Switzer", size: secondaryFontSize)
                      .weight(.medium)
                  )
                  .foregroundColor(style.time)
                  .lineLimit(1)
                  .truncationMode(.tail)
              }

              if let statusLine = statusLine {
                Text(statusLine)
                  .font(Font.custom("Switzer", size: secondaryFontSize))
                  .foregroundColor(theme.textSecondary)
                  .lineLimit(1)
                  .truncationMode(.tail)
              }
            }
          } else {
            if showTimelineAppIcons && (faviconPrimaryRaw != nil || faviconSecondaryRaw != nil) {
              FaviconImageView(
                primaryRaw: faviconPrimaryRaw,
                secondaryRaw: faviconSecondaryRaw,
                primaryHost: faviconPrimaryHost,
                secondaryHost: faviconSecondaryHost,
                size: faviconSize,
                backgroundColor: isFailedCard ? theme.cardFailedFill : theme.cardFill
              )
              .offset(y: faviconVerticalOffset)
            }

            Text(title)
              .font(
                Font.custom("Switzer", size: fontSize)
                  .weight(fontWeight.fontWeight)
              )
              .foregroundColor(style.text)

            Spacer()

            HStack(spacing: 6) {
              if isBackupGenerated {
                backupIndicator
              }

              Text(time)
                .font(
                  Font.custom("Switzer", size: secondaryFontSize)
                    .weight(.medium)
                )
                .foregroundColor(style.time)
                .lineLimit(1)
                .truncationMode(.tail)
            }
          }
        }
      }
      .padding(.leading, iconLeadingInset)
      .padding(.trailing, 10)
      .padding(.vertical, verticalPadding)
      .frame(
        maxWidth: .infinity,
        minHeight: height,
        maxHeight: height,
        alignment: isCompactCard ? .leading : .topLeading
      )
      .background(isFailedCard ? theme.cardFailedFill : theme.cardFill)
      .background(theme.panelSolid)
      .clipShape(RoundedRectangle(cornerRadius: TBDTokens.Radius.base))
      .overlay(
        RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
          .inset(by: 0.25)
          .stroke(
            isFailedCard ? Color(red: 1, green: 0.16, blue: 0.11) : theme.cardBorder,
            style: isFailedCard
              ? StrokeStyle(lineWidth: 0.5, dash: [2.5, 2.5]) : StrokeStyle(lineWidth: 0.25)
          )
      )
      .overlay(alignment: .leading) {
        if !isFailedCard {
          RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
            .fill(style.accent)
            .frame(width: 6)
        }
      }
      // Selection halo for the active activity
      .overlay(
        RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
          .stroke(selectionStroke, lineWidth: 1.5)
          .opacity(isSelected ? 1 : 0)
      )
      .overlay(
        RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
          .stroke(Color.black.opacity(isHovering ? 0.08 : 0), lineWidth: 1)
      )
      // Hovered cards lift onto a hard, zero-blur offset shadow instead of a
      // soft drop-shadow — flat content otherwise never floats.
      .background(
        RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
          .fill(TBDTokens.ink.opacity(isHovering ? TBDTokens.Shadow.brickSm.opacity : 0))
          .offset(x: TBDTokens.Shadow.brickSm.x, y: TBDTokens.Shadow.brickSm.y)
      )
      .offset(x: isHovering ? -1 : 0, y: isHovering ? -1 : 0)
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .onHover { hovering in
      isHovering = hovering
    }
    .animation(.easeOut(duration: 0.18), value: isHovering)
    .padding(.horizontal, 6)
  }
}
