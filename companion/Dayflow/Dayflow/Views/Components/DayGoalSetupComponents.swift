import AppKit
import TBDDesign
import SwiftUI
import UniformTypeIdentifiers

struct GoalCategoryPool: View {
  let categories: [TimelineCategory]
  let focusIDs: Set<String>
  let distractionIDs: Set<String>
  var onCycle: (TimelineCategory) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Drag and drop to set the categories you want to track")
        .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
        .foregroundColor(TBDColor.muted)

      DayGoalFlowLayout(spacing: 8, rowSpacing: 6) {
        ForEach(categories) { category in
          Button {
            onCycle(category)
          } label: {
            GoalCategoryChip(
              title: category.name,
              colorHex: category.colorHex,
              status: status(for: category)
            )
          }
          .buttonStyle(.plain)
          .onDrag {
            NSItemProvider(object: category.id.uuidString as NSString)
          }
          .pointingHandCursor()
          .help(
            "Drag into a goal panel, or click to cycle between Focus, Distraction, and untracked")
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(TBDColor.tile, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }

  private func status(for category: TimelineCategory) -> GoalCategoryChip.Status {
    let id = category.id.uuidString
    if focusIDs.contains(id) {
      return .focus
    }
    if distractionIDs.contains(id) {
      return .distraction
    }
    return .untracked
  }
}

struct GoalSetupPanel: View {
  let kind: DayGoalCategoryKind
  let title: String
  @Binding var durationMinutes: Int
  let leadingStatTitle: String
  let leadingStatMinutes: Int
  let trailingStatTitle: String
  let trailingStatMinutes: Int
  let statScaleMaxMinutes: Int
  let selectedCategories: [DayGoalCategorySnapshot]
  var onRemoveCategory: (String) -> Void
  var onDropCategory: (String) -> Void

  private var accent: Color {
    switch kind {
    case .focus:
      return TBDColor.teal
    case .distraction:
      return TBDColor.brick
    }
  }

  private var headerFill: Color {
    kind == .focus ? TBDColor.statusLiveFill : TBDColor.statusNeedsYouFill
  }

  private var headerOn: Color {
    kind == .focus ? TBDColor.statusLiveOn : TBDColor.statusNeedsYouOn
  }

  private var statTextColor: Color {
    switch kind {
    case .focus:
      return TBDColor.tealInk
    case .distraction:
      return TBDColor.brickInk
    }
  }

  private var iconName: String {
    switch kind {
    case .focus:
      return "DayGoalFocus"
    case .distraction:
      return "DayGoalDistraction"
    }
  }

  private var panelWidth: CGFloat {
    switch kind {
    case .focus:
      return 396
    case .distraction:
      return 400.28
    }
  }

  private var statColumnWidth: CGFloat {
    (panelWidth - 32 - 18) / 2
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(iconName)
          .resizable()
          .scaledToFit()
          .frame(width: 16, height: 16)

        Text(title)
          .font(TBDTokens.Typography.control)
          .foregroundColor(headerOn)

        Spacer()
      }
      .padding(.horizontal, 11)
      .frame(height: 30)
      .background(headerFill)

      HStack(spacing: 10) {
        categoryBox
          .frame(width: 140, height: 187)

        GoalDurationPicker(minutes: $durationMinutes)
          .frame(width: 192, height: 187)
      }
      .padding(.top, 21)
      .padding(.bottom, 23)
      .padding(.horizontal, 24)
      .frame(maxWidth: .infinity)
      .background(TBDColor.tile)

      footer
        .frame(height: 59)
    }
    .frame(width: panelWidth)
    .clipShape(TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }

  private var categoryBox: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Categories")
        .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
        .foregroundColor(TBDColor.muted)

      VStack(alignment: .leading, spacing: 6) {
        ForEach(selectedCategories) { category in
          Button {
            onRemoveCategory(category.categoryID)
          } label: {
            GoalCategoryChip(
              title: category.name,
              colorHex: category.colorHex,
              status: kind == .focus ? .focus : .distraction,
              showsRemove: true
            )
          }
          .buttonStyle(.plain)
          .pointingHandCursor()
        }
      }
      Spacer(minLength: 0)
    }
    .padding(11)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(TBDColor.paper, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
    .onDrop(of: [.plainText], isTargeted: nil, perform: handleCategoryDrop)
  }

  private func handleCategoryDrop(_ providers: [NSItemProvider]) -> Bool {
    guard
      let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
      })
    else {
      return false
    }

    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
      let categoryID: String?
      if let data = item as? Data {
        categoryID = String(data: data, encoding: .utf8)
      } else if let string = item as? String {
        categoryID = string
      } else if let nsString = item as? NSString {
        categoryID = String(nsString)
      } else {
        categoryID = nil
      }

      guard let categoryID else { return }
      Task { @MainActor in
        onDropCategory(categoryID)
      }
    }
    return true
  }

  private var footer: some View {
    HStack(spacing: 18) {
      goalStat(title: leadingStatTitle, minutes: leadingStatMinutes)
        .frame(width: statColumnWidth, alignment: .leading)
      goalStat(title: trailingStatTitle, minutes: trailingStatMinutes)
        .frame(width: statColumnWidth, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(TBDColor.plate)
  }

  private func goalStat(title: String, minutes: Int) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
        .foregroundColor(TBDColor.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.82)

      HStack(spacing: 5) {
        TBDBrickShape()
          .fill(accent)
          .frame(width: statBarWidth(minutes: minutes), height: 6)

        Text(formatShort(minutes: minutes))
          .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
          .foregroundColor(statTextColor)
          .lineLimit(1)
          .minimumScaleFactor(0.86)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func formatShort(minutes: Int) -> String {
    let hours = minutes / 60
    let mins = minutes % 60
    if hours > 0 && mins == 0 {
      return "\(hours) hours"
    }
    if hours > 0 {
      return "\(hours)h \(mins)m"
    }
    return "\(mins)m"
  }

  private func statBarWidth(minutes: Int) -> CGFloat {
    guard minutes > 0, statScaleMaxMinutes > 0 else { return 0 }
    let ratio = min(max(CGFloat(minutes) / CGFloat(statScaleMaxMinutes), 0), 1)
    return max(12, 86 * ratio)
  }
}

private struct GoalCategoryChip: View {
  enum Status {
    case untracked
    case focus
    case distraction
  }

  let title: String
  let colorHex: String
  let status: Status
  var showsRemove = false

  private var color: Color {
    if let nsColor = NSColor(hex: colorHex) {
      return Color(nsColor: nsColor)
    }
    return TBDColor.toneStone
  }

  var body: some View {
    HStack(spacing: 2) {
      ChipDragHandle(color: color)
        .frame(width: 16, height: 16)

      Text(title)
        .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
        .foregroundColor(TBDColor.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.8)

      if showsRemove {
        Image(systemName: "xmark")
          .font(TBDFonts.symbol(7, .bold))
          .foregroundColor(TBDColor.muted)
      }
    }
    .padding(4)
    .background(color.opacity(0.3), in: Capsule())
    .tbdPillEdge(color.opacity(status == .untracked ? 0.75 : 1))
  }
}

private struct ChipDragHandle: View {
  let color: Color

  var body: some View {
    VStack(spacing: 2) {
      HStack(spacing: 2) {
        Circle().fill(color)
        Circle().fill(color)
      }
      HStack(spacing: 2) {
        Circle().fill(color)
        Circle().fill(color)
      }
    }
    .padding(3)
  }
}

private struct DayGoalFlowLayout: Layout {
  var spacing: CGFloat = 6
  var rowSpacing: CGFloat = 6

  func makeCache(subviews: Subviews) {}

  func updateCache(_ cache: inout (), subviews: Subviews) {}

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var maxRowWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
        totalHeight += rowHeight + rowSpacing
        maxRowWidth = max(maxRowWidth, rowWidth)
        rowWidth = size.width
        rowHeight = size.height
      } else {
        rowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
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
