import TBDDesign
import SwiftUI

struct CanvasActivityCardStyle {
  let text: Color
  let time: Color
  let accent: Color
  let isIdle: Bool
}

struct CanvasActivityCard: View {
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
      .font(TBDFonts.nunito(9, TBDKit.weightNav))
      .foregroundStyle(TBDColor.muted)
      .frame(width: 14, height: 14)
      .background(
        TBDBrickShape()
          .fill(TBDColor.tile)
      )
      .overlay(
        TBDBrickShape()
          .strokeBorder(TBDColor.line, lineWidth: TBDKit.hair)
      )
      .help(
        "This card fell back to a lower-quality Gemini model due to rate limiting, so output quality may be lower."
      )
  }

  private var selectionStroke: Color {
    if isSystemCategory {
      return TBDColor.brick
    }
    return style.accent
  }

  var body: some View {
    Button(action: {
      withAnimation(TBDMotion.spring) {
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
                    TBDFonts.nunito(fontSize, fontWeight.fontWeight)
                  )
                  .foregroundStyle(style.text)

                Spacer()

                Text(time)
                  .font(
                    TBDFonts.nunito(secondaryFontSize, TBDKit.weightNav)
                  )
                  .foregroundStyle(style.time)
                  .lineLimit(1)
                  .truncationMode(.tail)
              }

              if let statusLine = statusLine {
                Text(statusLine)
                  .font(TBDFonts.nunito(secondaryFontSize, TBDKit.weightBody))
                  .foregroundStyle(TBDColor.muted)
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
                backgroundColor: isFailedCard ? TBDColor.brickWash : TBDColor.tile
              )
              .offset(y: faviconVerticalOffset)
            }

            Text(title)
              .font(
                TBDFonts.nunito(fontSize, fontWeight.fontWeight)
              )
              .foregroundStyle(style.text)

            Spacer()

            HStack(spacing: 6) {
              if isBackupGenerated {
                backupIndicator
              }

              Text(time)
                .font(
                  TBDFonts.nunito(secondaryFontSize, TBDKit.weightNav)
                )
                .foregroundStyle(style.time)
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
      .background(isFailedCard ? TBDColor.brickWash : TBDColor.tile)
      .clipShape(TBDBrickShape())
      .overlay(
        TBDBrickShape()
          .inset(by: TBDKit.hair / 2)
          .stroke(
            isFailedCard ? TBDColor.brick : TBDColor.line,
            style: isFailedCard
              ? StrokeStyle(lineWidth: TBDKit.hair, dash: [2.5, 2.5]) : StrokeStyle(lineWidth: TBDKit.hair)
          )
      )
      .overlay(alignment: .leading) {
        if !isFailedCard {
          TBDBrickShape()
            .fill(style.accent)
            .frame(width: 6)
        }
      }
      // Selection halo for the active activity
      .overlay(
        TBDBrickShape()
          .stroke(selectionStroke, lineWidth: 1.5)
          .opacity(isSelected ? 1 : 0)
      )
      .overlay(
        TBDBrickShape()
          .stroke(TBDColor.ink.opacity(isHovering ? 0.08 : 0), lineWidth: 1)
      )
      .offset(x: isHovering ? -1 : 0, y: isHovering ? -1 : 0)
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .onHover { hovering in
      isHovering = hovering
    }
    .animation(TBDMotion.quick, value: isHovering)
    .padding(.horizontal, 6)
  }
}
