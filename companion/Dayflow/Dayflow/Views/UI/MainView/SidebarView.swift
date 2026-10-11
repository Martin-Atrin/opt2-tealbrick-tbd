import SwiftUI
import MacParakeet

private enum SidebarMetrics {
  static let itemSpacing: CGFloat = TBDRailMetrics.gap
  static let scale: CGFloat = 1.1
  static let itemSize: CGFloat = TBDRailMetrics.row
  static let selectedBackgroundSize: CGFloat = TBDRailMetrics.iconBox
  static let selectedBackgroundRadius: CGFloat = 10
  static let iconSize: CGFloat = TBDRailMetrics.icon
  static let fallbackSymbolSize: CGFloat = TBDRailMetrics.icon
  static let badgeSize: CGFloat = 8 * scale
  static let badgeOffsetX: CGFloat = 10 * scale
  static let badgeOffsetY: CGFloat = -10 * scale
  static let iconContainerSize: CGFloat = TBDRailMetrics.iconBox
  static let iconLabelSpacing: CGFloat = 3
  static let labelFontSize: CGFloat = TBDRailMetrics.label
}

enum SidebarIcon: CaseIterable {
  case timeline
  case daily
  case weekly
  case chat
  case flow
  case agents
  case review
  case bug
  case settings

  var assetName: String? {
    switch self {
    case .timeline: return "TimelineIcon"
    case .daily: return "DailyIcon"
    case .weekly: return "WeeklyIcon"
    case .chat: return "ChatIcon"
    case .flow: return "FlowIcon"
    case .agents: return "AgentsIcon"
    case .review: return nil
    case .bug: return nil
    case .settings: return nil
    }
  }

  var systemNameFallback: String? {
    switch self {
    case .flow: return "water.waves"
    case .agents: return "sparkles"
    case .review: return "rectangle.stack"
    case .bug: return "exclamationmark.bubble.fill"
    case .settings: return "gearshape.fill"
    default: return nil
    }
  }

  var displayName: String {
    switch self {
    case .timeline: return String(localized: "Timeline")
    case .daily:
      return String(
        localized: "sidebar.daily", defaultValue: "Daily",
        comment: "Short sidebar label for the daily recap view.")
    case .weekly:
      return String(
        localized: "sidebar.weekly", defaultValue: "Weekly",
        comment: "Short sidebar label for the weekly recap view.")
    case .chat: return String(localized: "Chat")
    case .flow: return String(localized: "Flow")
    case .agents: return String(localized: "Agents")
    case .review: return "Review"
    case .bug: return String(localized: "Support")
    case .settings: return String(localized: "Settings")
    }
  }

  var analyticsTabName: String {
    switch self {
    case .timeline: return "timeline"
    case .daily: return "daily"
    case .weekly: return "weekly"
    case .chat: return "dashboard"
    case .flow: return "flow"
    case .agents: return "agents"
    case .review: return "review"
    case .bug: return "bug_report"
    case .settings: return "settings"
    }
  }
}

struct SidebarView: View {
  @Binding var selectedIcon: SidebarIcon
  @ObservedObject private var badgeManager = NotificationBadgeManager.shared
  @ObservedObject private var authManager = DayflowAuthManager.shared

  private var visibleIcons: [SidebarIcon] {
    SidebarIcon.allCases.filter { icon in
      if icon == .settings { return false }
      // Support is discontinued in the Companion rail (operator 2026-09-27); About keeps the link.
      if icon == .bug { return false }
      if icon == .flow { return SidebarView.showsFlowTab(flowEnabled: authManager.flowEnabled) }
      return true
    }
  }

  /// Local Tasks and nudge demo do not depend on a hosted account.
  static func showsFlowTab(flowEnabled: Bool) -> Bool {
    true // Local demo; no hosted account required.
  }

  var body: some View {
    VStack(alignment: .center, spacing: SidebarMetrics.itemSpacing) {
      ForEach(visibleIcons, id: \.self) { icon in
        SidebarIconButton(
          icon: icon,
          isSelected: selectedIcon == icon,
          showBadge: shouldShowBadge(for: icon),
          action: {
            if icon == .settings {
              NotificationCenter.default.post(name: Notification.Name("tbdOpenSettings"), object: "account")
            } else { selectedIcon = icon }
          }
        )
        .frame(width: SidebarMetrics.itemSize, height: SidebarMetrics.itemSize)
      }
    }
  }

  private func shouldShowBadge(for icon: SidebarIcon) -> Bool {
    switch icon {
    case .bug:
      return badgeManager.supportUnreadCount > 0
    case .daily:
      return badgeManager.hasPendingDailyRecap
    default:
      return false
    }
  }
}

struct SidebarIconButton: View {
  @Environment(\.dayflowTheme) private var theme

  let icon: SidebarIcon
  let isSelected: Bool
  var showBadge: Bool = false
  let action: () -> Void

  private var iconColor: Color {
    isSelected ? theme.sidebarIconActive : theme.sidebarIcon
  }

  private var labelColor: Color {
    isSelected ? theme.sidebarLabelActive : theme.sidebarLabel
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: SidebarMetrics.iconLabelSpacing) {
        iconBox

        Text(icon.displayName)
          .font(.custom("Switzer", size: SidebarMetrics.labelFontSize))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .foregroundColor(labelColor)
      }
      .frame(width: SidebarMetrics.itemSize, height: SidebarMetrics.itemSize)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .pointingHandCursor()
  }

  private var iconBox: some View {
    return ZStack {
      if isSelected {
        // Soft rail selection (docs/design-language.md).
        TBDRailSelection()
          .frame(
            width: SidebarMetrics.selectedBackgroundSize,
            height: SidebarMetrics.selectedBackgroundSize
          )
      }

      iconImage
        .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)

      if showBadge {
        // Status dots are square in the brick language.
        RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
          .fill(theme.accent)
          .frame(width: SidebarMetrics.badgeSize, height: SidebarMetrics.badgeSize)
          .offset(x: SidebarMetrics.badgeOffsetX, y: SidebarMetrics.badgeOffsetY)
      }
    }
    .frame(width: SidebarMetrics.iconContainerSize, height: SidebarMetrics.iconContainerSize)
  }

  @ViewBuilder
  private var iconImage: some View {
    if let asset = icon.assetName {
      Image(asset)
        .resizable()
        .interpolation(.high)
        .renderingMode(.template)
        .aspectRatio(contentMode: .fit)
        .foregroundColor(iconColor)
    } else if let sys = icon.systemNameFallback {
      Image(systemName: sys)
        .font(.system(size: SidebarMetrics.fallbackSymbolSize))
        .foregroundColor(iconColor)
    }
  }
}
