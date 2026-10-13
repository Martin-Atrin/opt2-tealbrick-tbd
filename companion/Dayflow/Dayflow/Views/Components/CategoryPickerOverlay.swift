import AppKit
import SwiftUI
import TBDDesign

struct CategoryPickerOverlay: View {
  let categories: [TimelineCategory]
  let currentCategoryName: String
  var onSelect: (TimelineCategory) -> Void
  var onNavigateToEditor: () -> Void
  var onDismiss: () -> Void

  private var orderedCategories: [TimelineCategory] {
    let trimmedCurrent = currentCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let sorted = categories.sorted { lhs, rhs in
      lhs.order < rhs.order
    }

    guard
      let index = sorted.firstIndex(where: {
        $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmedCurrent
      })
    else {
      return sorted
    }

    var reordered = sorted
    let selected = reordered.remove(at: index)
    reordered.insert(selected, at: 0)
    return reordered
  }

  var body: some View {
    VStack(spacing: 12) {
      FlowLayout(spacing: 6, rowSpacing: 8) {
        ForEach(orderedCategories) { category in
          Button {
            onSelect(category)
          } label: {
            CategoryPickerPill(
              category: category,
              isSelected: isSelected(category)
            )
          }
          .buttonStyle(.plain)
          .pointingHandCursor()
        }
      }
      .padding(.trailing, 40)
      .frame(maxWidth: .infinity, alignment: .leading)

      Rectangle()
        .fill(TBDColor.line)
        .frame(height: TBDKit.hair)

      helperContent
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .tbdFloating()
    .overlay(alignment: .topTrailing) {
      dismissButton
    }
  }

  private var dismissButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "checkmark")
        .font(TBDFonts.symbol(11, TBDKit.weightLabel))
    }
    .buttonStyle(TBDButtonStyle(.icon))
    .pointingHandCursor()
    .accessibilityLabel("Done")
  }

  private var helperContent: some View {
    let baseFont = TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody)
    let baseColor = TBDColor.muted
    let linkColor = TBDColor.tealInk
    let linkURL = URL(string: "dayflow://category-editor")!

    var intro = AttributedString(
      String(
        localized:
          "To help Tealbrick organize your activities more accurately, try adding more details to the descriptions in your categories "
      )
    )
    intro.font = baseFont
    intro.foregroundColor = baseColor

    var link = AttributedString("here")
    link.font = baseFont
    link.foregroundColor = linkColor
    link.underlineStyle = .single
    link.link = linkURL

    var period = AttributedString(".")
    period.font = baseFont
    period.foregroundColor = baseColor

    let attributed = intro + link + period

    return Text(attributed)
      .fixedSize(horizontal: false, vertical: true)
      .environment(
        \.openURL,
        OpenURLAction { url in
          guard url == linkURL else { return .systemAction }
          onNavigateToEditor()
          return .handled
        })
  }

  private func isSelected(_ category: TimelineCategory) -> Bool {
    let trimmedCurrent = currentCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      == trimmedCurrent
  }
}

private struct CategoryPickerPill: View {
  let category: TimelineCategory
  let isSelected: Bool

  private var categoryColor: Color {
    if let nsColor = NSColor(hex: category.colorHex) {
      return Color(nsColor: nsColor)
    }
    return TBDColor.toneStone
  }

  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(categoryColor)
        .frame(width: 10, height: 10)

      Text(category.name)
        .font(
          TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav)
        )
        .foregroundStyle(isSelected ? TBDColor.tealInk : TBDColor.ink)
        .lineLimit(1)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(isSelected ? TBDColor.tealWash : TBDColor.tile, in: Capsule())
    .tbdPillEdge(isSelected ? TBDColor.tealWashLine : (category.isIdle ? Color.clear : TBDColor.line))
    .overlay {
      if category.isIdle && !isSelected {
        Capsule().strokeBorder(
          TBDColor.lineStrong, style: StrokeStyle(lineWidth: TBDKit.hair, dash: [4, 3]))
      }
    }
  }
}

private struct FlowLayout: Layout {
  var spacing: CGFloat = 6
  var rowSpacing: CGFloat = 6

  func makeCache(subviews: Subviews) {
    ()
  }

  func updateCache(_ cache: inout (), subviews: Subviews) {}

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var maxRowWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let proposedWidth = size.width

      if rowWidth > 0 && rowWidth + spacing + proposedWidth > maxWidth {
        totalHeight += rowHeight + rowSpacing
        maxRowWidth = max(maxRowWidth, rowWidth)
        rowWidth = proposedWidth
        rowHeight = size.height
      } else {
        rowWidth = rowWidth == 0 ? proposedWidth : rowWidth + spacing + proposedWidth
        rowHeight = max(rowHeight, size.height)
      }
    }

    maxRowWidth = max(maxRowWidth, rowWidth)
    totalHeight += rowHeight

    return CGSize(width: maxRowWidth, height: totalHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var origin = CGPoint(x: bounds.minX, y: bounds.minY)
    var currentRowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if origin.x > bounds.minX && origin.x + size.width > bounds.maxX {
        origin.x = bounds.minX
        origin.y += currentRowHeight + rowSpacing
        currentRowHeight = 0
      }

      subview.place(
        at: CGPoint(x: origin.x, y: origin.y),
        proposal: ProposedViewSize(width: size.width, height: size.height)
      )

      origin.x += size.width + spacing
      currentRowHeight = max(currentRowHeight, size.height)
    }
  }
}
