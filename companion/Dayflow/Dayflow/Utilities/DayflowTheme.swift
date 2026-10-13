//
//  DayflowTheme.swift
//  Dayflow
//
//  Single source of truth for light/dark styling. Every value here comes from
//  the Figma "Interface refresh" file. Views read `@Environment(\.dayflowTheme)`
//  instead of hardcoding hex colors so both appearances stay side by side.
//

import SwiftUI
import TBDDesign

// MARK: - Appearance preference

/// User-facing appearance choice. Defaults to following the system.
enum DayflowAppearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let storageKey = "dayflowAppearance"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: return String(localized: "System")
    case .light: return String(localized: "Light")
    case .dark: return String(localized: "Dark")
    }
  }

  func colorScheme(system: ColorScheme) -> ColorScheme {
    switch self {
    case .system: return system
    case .light: return .light
    case .dark: return .dark
    }
  }
}

/// Keep an explicit system scheme so switching back never passes nil to SwiftUI.
@MainActor
final class SystemAppearanceObserver: ObservableObject {
  @Published private(set) var colorScheme: ColorScheme
  private var observation: NSKeyValueObservation?

  init() {
    let app = NSApplication.shared
    colorScheme = Self.currentColorScheme
    observation = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.colorScheme = Self.currentColorScheme
      }
    }
  }

  static var currentColorScheme: ColorScheme {
    NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? .dark : .light
  }
}

// MARK: - Theme tokens

struct DayflowTheme {
  var isDark: Bool

  // Window
  var windowBackground: AnyShapeStyle
  var windowBorder: Color

  // Main content panel (the big rounded card next to the sidebar)
  var panelFill: AnyShapeStyle
  var panelBorder: Color
  var panelShadow: Color
  var panelInnerGlow: Color
  /// Opaque approximation of the panel color, for fades that must hide content.
  var panelSolid: Color

  // Sidebar
  var sidebarSelectedFill: LinearGradient
  var sidebarSelectedBorder: Color
  var sidebarSelectedInnerGlow: Color
  var sidebarSelectedShadow: Color
  var sidebarLabel: Color
  var sidebarLabelActive: Color
  var sidebarIcon: Color
  var sidebarIconActive: Color

  // Text
  var textPrimary: Color
  var textSecondary: Color
  var textTertiary: Color
  var textMuted: Color
  var accent: Color
  var accentText: Color

  // Peach "glass" control (calendar pill, Pause, selected Day/Week segment)
  var controlFill: Color
  var controlBorder: Color
  var controlInnerGlow: Color
  var controlText: Color

  // Day/Week segmented container
  var segmentTrackFill: Color
  var segmentTrackBorder: Color
  var segmentInactiveText: Color

  // Small circular edit (pencil) button
  var editButtonFill: Color
  var editButtonBorder: Color
  var editButtonInnerGlow: Color

  // Category chips in the timeline header
  var chipFill: Color
  var chipBorder: Color
  var chipText: Color

  // Timeline grid
  var hourLabel: Color
  var hourLabelFuture: Color
  var hourLine: Color

  // Day timeline activity cards
  var cardFill: Color
  var cardBorder: Color
  var cardInnerGlow: Color
  var cardTitle: Color
  var cardTime: Color
  var cardFailedFill: Color

  // "Generating your next card…" card
  var generatingGradient: LinearGradient
  var pausedCardGradient: LinearGradient
  var pausedCardText: Color

  // Week timeline cards
  var weekCardFillOpacity: Double

  // Right panel (day summary)
  var rightPanelFill: Color
  var rightPanelBorder: Color
  var rightPanelShadow: Color
  var rightPanelDivider: Color

  // Today's targets header
  var targetsFill: Color
  var targetsBorder: Color
  var targetsTrackFill: Color
  var targetsTrackBorder: Color
  var targetsBubbleFill: Color
  var targetsBubbleBorder: Color
  var targetsInactiveTrack: Color
  var targetsInactiveFill: Color

  // Summary cards (Total focus time, Longest focus, Distractions)
  var summaryCardFill: Color
  var summaryCardBorder: Color
  var summaryCardShadow: Color
  var summaryCardInnerGlow: Color
  var summaryValue: Color

  // Donut chart
  var donutRingBackground: Color
  var donutCenterFill: Color
  var donutShadow: Color
  var legendSwatchOpacity: Double

  // Secondary button (Copy timeline, Cancel)
  var secondaryButtonFill: Color
  var secondaryButtonBorder: Color
  var secondaryButtonText: Color

  // Primary button (Confirm, Continue)
  var primaryButtonFill: Color
  var primaryButtonBorder: Color
  var primaryButtonInnerGlow: Color
  var primaryButtonText: Color

  // Floating editors / popovers
  var popoverFill: Color
  var popoverBorder: Color

  // Day goal sheet
  var sheetOverlay: Color
  var sheetCardFill: Color
  var sheetCardBorder: Color
  var sheetFocusHeader: Color
  var sheetDistractionHeader: Color
  var sheetFocusStatText: Color
  var sheetDistractionStatText: Color
  var sheetPanelFill: Color
  var sheetPanelBorder: Color
  var sheetInnerBoxFill: Color
  var sheetInnerBoxBorder: Color
  var sheetFooterFill: Color
  var sheetWheelGradient: LinearGradient
  var sheetWheelBorder: Color
  var sheetWheelDimText: Color

  // Daily view
  var dailyGridFill: Color
  var dailyGridBorder: Color
  var dailyTotalsFill: Color
  var dailyEmptyCell: Color
  var dailyDistractionTrack: Color
  var dailyDistractionTrackBorder: Color
  var dailyStatValue: Color
  var standupCardGradient: LinearGradient
  var standupCardBorder: Color
  var standupBlockersFill: Color
  var standupBlockersBorder: Color

  // Standard text field / input
  var inputFill: Color
  var inputBorder: Color

  // Chat
  var chatBackground: AnyShapeStyle
  var chatSoftAccentFill: Color
  var chatSoftAccentBorder: Color
  var chatSidePanelFill: Color
  var chatSidePanelHeaderFill: Color
  var chatCodeFill: Color
}

// MARK: - Kit theme (C139/C145)

extension DayflowTheme {
  /// The companion theme now reads the kit (TBDColor, generated from the toolkit tokens). TBDColor values are
  /// dynamic (light/dark), so `dark` only sets `isDark` and the two opacities. The earlier "Before/After" Figma
  /// palettes and the palette switch are gone; the four names stay so call sites compile.
  static let light = kit(dark: false)
  static let lightBefore = light
  static let dark = kit(dark: true)
  static let darkBefore = dark

  private static func kit(dark: Bool) -> DayflowTheme {
    func flat(_ c: Color) -> LinearGradient { LinearGradient(colors: [c, c], startPoint: .top, endPoint: .bottom) }
    return DayflowTheme(
      isDark: dark,
      windowBackground: AnyShapeStyle(TBDColor.paper),
      windowBorder: TBDColor.line,
      panelFill: AnyShapeStyle(TBDColor.tile),
      panelBorder: TBDColor.line,
      panelShadow: .clear,
      panelInnerGlow: .clear,
      panelSolid: TBDColor.tile,
      sidebarSelectedFill: flat(TBDColor.tealWash),
      sidebarSelectedBorder: TBDColor.tealWashLine,
      sidebarSelectedInnerGlow: .clear,
      sidebarSelectedShadow: .clear,
      sidebarLabel: TBDColor.muted,
      sidebarLabelActive: TBDColor.ink,
      sidebarIcon: TBDColor.muted,
      sidebarIconActive: TBDColor.tealInk,
      textPrimary: TBDColor.ink,
      textSecondary: TBDColor.inkSoft,
      textTertiary: TBDColor.muted,
      textMuted: TBDColor.muted,
      accent: TBDColor.teal,
      accentText: TBDColor.tealInk,
      controlFill: TBDColor.tile,
      controlBorder: TBDColor.lineStrong,
      controlInnerGlow: .clear,
      controlText: TBDColor.ink,
      segmentTrackFill: TBDColor.plate,
      segmentTrackBorder: .clear,
      segmentInactiveText: TBDColor.muted,
      editButtonFill: TBDColor.tile,
      editButtonBorder: TBDColor.lineStrong,
      editButtonInnerGlow: .clear,
      chipFill: TBDColor.tile,
      chipBorder: TBDColor.line,
      chipText: TBDColor.ink,
      hourLabel: TBDColor.muted,
      hourLabelFuture: TBDColor.muted,
      hourLine: TBDColor.line,
      cardFill: TBDColor.tile,
      cardBorder: TBDColor.line,
      cardInnerGlow: .clear,
      cardTitle: TBDColor.ink,
      cardTime: TBDColor.muted,
      cardFailedFill: TBDColor.brickWash,
      generatingGradient: LinearGradient(colors: [TBDColor.tealWash, TBDColor.tile], startPoint: .leading, endPoint: .trailing),
      pausedCardGradient: LinearGradient(colors: [TBDColor.tile, TBDColor.plate], startPoint: .top, endPoint: .bottom),
      pausedCardText: TBDColor.muted,
      weekCardFillOpacity: dark ? 0.25 : 0.2,
      rightPanelFill: TBDColor.tile,
      rightPanelBorder: TBDColor.line,
      rightPanelShadow: .clear,
      rightPanelDivider: TBDColor.line,
      targetsFill: TBDColor.tealWash,
      targetsBorder: TBDColor.line,
      targetsTrackFill: TBDColor.tile,
      targetsTrackBorder: TBDColor.line,
      targetsBubbleFill: TBDColor.tile,
      targetsBubbleBorder: TBDColor.line,
      targetsInactiveTrack: TBDColor.plate,
      targetsInactiveFill: TBDColor.tile,
      summaryCardFill: TBDColor.tile,
      summaryCardBorder: TBDColor.line,
      summaryCardShadow: .clear,
      summaryCardInnerGlow: .clear,
      summaryValue: TBDColor.ink,
      donutRingBackground: TBDColor.plate,
      donutCenterFill: TBDColor.tile,
      donutShadow: .clear,
      legendSwatchOpacity: dark ? 0.6 : 0.4,
      secondaryButtonFill: TBDColor.secondaryFill,
      secondaryButtonBorder: TBDColor.secondaryEdge,
      secondaryButtonText: TBDColor.secondaryOn,
      primaryButtonFill: TBDColor.primaryFill,
      primaryButtonBorder: TBDColor.primaryFill,
      primaryButtonInnerGlow: .clear,
      primaryButtonText: TBDColor.primaryOn,
      popoverFill: TBDColor.tile,
      popoverBorder: TBDColor.line,
      sheetOverlay: TBDColor.scrim,
      sheetCardFill: TBDColor.tile,
      sheetCardBorder: TBDColor.line,
      sheetFocusHeader: TBDColor.tealWash,
      sheetDistractionHeader: TBDColor.brickWash,
      sheetFocusStatText: TBDColor.ink,
      sheetDistractionStatText: TBDColor.ink,
      sheetPanelFill: TBDColor.tile,
      sheetPanelBorder: TBDColor.line,
      sheetInnerBoxFill: TBDColor.tile,
      sheetInnerBoxBorder: TBDColor.line,
      sheetFooterFill: TBDColor.tile,
      sheetWheelGradient: LinearGradient(colors: [TBDColor.tile, TBDColor.plate], startPoint: .top, endPoint: .bottom),
      sheetWheelBorder: TBDColor.line,
      sheetWheelDimText: TBDColor.muted,
      dailyGridFill: TBDColor.tile,
      dailyGridBorder: TBDColor.line,
      dailyTotalsFill: TBDColor.tealWash,
      dailyEmptyCell: TBDColor.plate,
      dailyDistractionTrack: TBDColor.plate,
      dailyDistractionTrackBorder: TBDColor.line,
      dailyStatValue: TBDColor.ink,
      standupCardGradient: flat(TBDColor.tile),
      standupCardBorder: TBDColor.line,
      standupBlockersFill: TBDColor.brickWash,
      standupBlockersBorder: TBDColor.line,
      inputFill: TBDColor.fieldFill,
      inputBorder: TBDColor.fieldEdge,
      chatBackground: AnyShapeStyle(TBDColor.paper),
      chatSoftAccentFill: TBDColor.tealWash,
      chatSoftAccentBorder: TBDColor.tealWashLine,
      chatSidePanelFill: TBDColor.tile,
      chatSidePanelHeaderFill: TBDColor.plate,
      chatCodeFill: TBDColor.plate
    )
  }
}

// MARK: - Environment plumbing

private struct DayflowThemeKey: EnvironmentKey {
  static let defaultValue = DayflowTheme.light
}

extension EnvironmentValues {
  var dayflowTheme: DayflowTheme {
    get { self[DayflowThemeKey.self] }
    set { self[DayflowThemeKey.self] = newValue }
  }
}

/// Resolves the theme from the effective color scheme and injects it.
/// Attach once at the root of a window; every descendant reads
/// `@Environment(\.dayflowTheme)`.
private struct DayflowThemeResolver: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject private var preview = StylePreview.shared

  func body(content: Content) -> some View {
    content.environment(
      \.dayflowTheme,
      (colorScheme == .dark
        ? (preview.showAfter ? .dark : .darkBefore)
        : (preview.showAfter ? DayflowTheme.light : DayflowTheme.lightBefore)))
      .tint(TBDColor.tealInk)
  }
}

extension View {
  func resolveDayflowTheme() -> some View {
    modifier(DayflowThemeResolver())
  }

  /// Forces a subtree to a specific theme regardless of the system appearance.
  /// Used by onboarding, which is designed light-only.
  func dayflowTheme(_ theme: DayflowTheme) -> some View {
    environment(\.dayflowTheme, theme)
      .environment(\.colorScheme, theme.isDark ? .dark : .light)
  }
}

// MARK: - Adaptive colors

extension Color {
  /// A color that resolves per appearance (light / dark) automatically, for
  /// static design tokens like `SettingsStyle` that can't read the environment.
  static func dayflowAdaptive(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? dark : light
      }
    )
  }
}

// MARK: - Shared shapes

/// Faux "inset box-shadow" glow used all over the Figma: a soft stroke drawn
/// just inside the shape's edge.
struct InnerGlow<S: InsettableShape>: View {
  let shape: S
  let color: Color
  var radius: CGFloat = 4
  /// Stroke width of the glow band; defaults to `radius`.
  var spread: CGFloat? = nil
  /// Softness of the band's edges; defaults to `radius`.
  var blur: CGFloat? = nil

  var body: some View {
    shape
      .strokeBorder(color, lineWidth: spread ?? radius)
      .blur(radius: blur ?? radius)
      .clipShape(shape)
      .allowsHitTesting(false)
  }
}
