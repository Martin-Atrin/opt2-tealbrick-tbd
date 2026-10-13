import SwiftUI
import TBDDesign

struct WeeklyHighlightsSection: View {
  let snapshot: WeeklyHighlightsSnapshot
  let width: CGFloat

  init(snapshot: WeeklyHighlightsSnapshot, width: CGFloat = Design.width) {
    self.snapshot = snapshot
    self.width = width
  }

  private enum Design {
    static let width: CGFloat = 470
    static let height: CGFloat = 298
    static let borderColor = WeeklyPalette.cardBorder
    @MainActor static var background: Color { WeeklyPalette.cardFill }
    static let titleColor = WeeklyPalette.title
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Top Highlights")
        .font(TBDTokens.Typography.title)
        .foregroundStyle(Design.titleColor)

      VStack(alignment: .leading, spacing: 19) {
        ForEach(snapshot.highlights) { highlight in
          HStack(alignment: .top, spacing: 18) {
            Text(highlight.tag)
              .font(TBDTokens.Typography.label)
              .foregroundStyle(WeeklyPalette.accent)
              .lineLimit(2)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(WeeklyPalette.highlightChipFill, in: TBDBrickShape())
              .overlay(TBDBrickShape().strokeBorder(WeeklyPalette.cardInnerStroke, lineWidth: TBDKit.hair))
              .frame(width: 112, alignment: .leading)

            Text(highlight.text)
              .font(TBDTokens.Typography.hint)
              .foregroundStyle(WeeklyPalette.text)
              .lineSpacing(1)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(.top, 26)

      Spacer(minLength: 0)
    }
    .padding(.top, 19)
    .padding(.horizontal, 18)
    .frame(width: width, height: Design.height, alignment: .topLeading)
    .background(Design.background)
    .clipShape(TBDBrickShape())
    .overlay(
      TBDBrickShape()
        .strokeBorder(Design.borderColor, lineWidth: TBDKit.hair)
    )
  }
}

struct WeeklyHighlightsSnapshot {
  let highlights: [WeeklyHighlight]

  static let figmaPreview = WeeklyHighlightsSnapshot(
    highlights: [
      WeeklyHighlight(
        id: "editorial-nls",
        tag: "EDITORIAL NLS",
        text:
          String(
            localized:
              "Iterated on ZSR and sparse results design explorations (zero-result states, best match redirects, query rephrasing guidance)"
          )
      ),
      WeeklyHighlight(
        id: "editorial-video-nls",
        tag: "EDITORIAL VIDEO NLS",
        text:
          String(
            localized:
              "Conducted competitive analysis of NLS video search tools (TwelveLabs, WayinVideo, AP Moments, YouTube Ask) during Pod 1 Review"
          )
      ),
      WeeklyHighlight(
        id: "editorial-sbi",
        tag: "EDITORIAL SBI",
        text:
          String(
            localized:
              "Reviewed scope-switching and SBI handling flows; drafted \"Areas requiring additional PD input\" spec with ClickUp links; synced with Jason Ross on SBI UX details"
          )
      ),
    ]
  )
}

struct WeeklyHighlight: Identifiable {
  let id: String
  let tag: String
  let text: String
}

#Preview("Top Highlights", traits: .fixedLayout(width: 470, height: 298)) {
  WeeklyHighlightsSection(snapshot: .figmaPreview)
    .padding(24)
    .background(WeeklyPalette.canvas)
}
