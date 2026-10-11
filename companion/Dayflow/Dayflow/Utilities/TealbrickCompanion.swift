import SwiftUI

/// Palette sampled from tealbrick.com's live logo on 2026-09-22.
enum TealbrickPalette: String, CaseIterable, Identifiable {
  case teal, burgundy
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  var hex: String { self == .teal ? "059393" : "A94944" }
  var deepHex: String { self == .teal ? "034A4A" : "552522" }
  static let key = "tealbrickPalette"
  static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: key) ?? "teal") ?? .teal }
}
struct TealbrickCompanionSettings: View {
  @AppStorage(TealbrickPalette.key) private var palette: TealbrickPalette = .teal
  var body: some View {
    SettingsSection(title: "Appearance", subtitle: "App colors") {
      VStack(spacing: 0) {
        SettingsRow(label: "Palette") {
          Picker("Palette", selection: $palette) {
            ForEach(TealbrickPalette.allCases) { Text($0.title).tag($0) }
          }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
        }
      }
    }
  }
}

extension DayflowTheme {
  func tealbrick(_ palette: TealbrickPalette) -> DayflowTheme {
    var t = self
    let primary = Color(hex: palette.hex)
    let deep = Color(hex: palette.deepHex)
    let paper = Color(hex: "F3F1E9")
    let ink = Color(hex: "173F3C")
    let surface = isDark ? Color(hex: "1C2B2A") : Color(hex: "FFFEFA")
    let text = isDark ? paper : ink
    let muted = isDark ? Color(hex: "AEC3BC") : Color(hex: "526560")
    let line = isDark ? Color(hex: "3C5550") : Color(hex: "C9D0C5")
    let tint = primary.opacity(isDark ? 0.22 : 0.10)
    t.windowBackground = AnyShapeStyle(isDark ? Color(hex: "142321") : paper)
    t.windowBorder = line; t.panelFill = AnyShapeStyle(surface); t.panelSolid = surface
    t.panelBorder = line; t.panelInnerGlow = .clear; t.panelShadow = ink.opacity(0.06)
    t.sidebarSelectedFill = LinearGradient(colors: [tint,tint], startPoint: .top, endPoint: .bottom)
    t.sidebarSelectedBorder = primary.opacity(0.35); t.sidebarSelectedInnerGlow = .clear
    t.sidebarSelectedShadow = .clear; t.sidebarLabel = muted; t.sidebarLabelActive = text
    t.sidebarIcon = muted; t.sidebarIconActive = isDark ? paper : deep
    t.textPrimary = text; t.textSecondary = muted; t.textTertiary = muted
    t.textMuted = muted.opacity(0.8); t.accent = primary; t.accentText = isDark ? paper : deep
    t.controlFill = tint; t.controlBorder = line; t.controlInnerGlow = .clear; t.controlText = text
    t.segmentTrackFill = tint; t.segmentTrackBorder = line; t.segmentInactiveText = muted
    t.editButtonFill = tint; t.editButtonBorder = line; t.editButtonInnerGlow = .clear
    t.chipFill = tint; t.chipBorder = line; t.chipText = text
    t.hourLabel = muted; t.hourLabelFuture = muted.opacity(0.5); t.hourLine = line.opacity(0.6)
    t.cardFill = surface; t.cardBorder = line; t.cardInnerGlow = .clear; t.cardTitle = text; t.cardTime = muted
    t.rightPanelFill = surface; t.rightPanelBorder = line; t.rightPanelShadow = .clear; t.rightPanelDivider = line
    t.targetsFill = tint; t.targetsBorder = line; t.targetsTrackFill = surface; t.targetsTrackBorder = line
    t.targetsBubbleFill = surface; t.targetsBubbleBorder = line
    t.summaryCardFill = surface; t.summaryCardBorder = line; t.summaryCardInnerGlow = .clear
    t.summaryValue = text; t.donutCenterFill = surface; t.donutRingBackground = tint
    t.secondaryButtonFill = tint; t.secondaryButtonBorder = line; t.secondaryButtonText = text
    t.primaryButtonFill = deep; t.primaryButtonBorder = deep; t.primaryButtonInnerGlow = .clear; t.primaryButtonText = .white
    t.popoverFill = surface; t.popoverBorder = line; t.sheetCardFill = surface; t.sheetCardBorder = line
    t.sheetPanelFill = surface; t.sheetPanelBorder = line
    t.chatSoftAccentFill = tint; t.chatSoftAccentBorder = primary.opacity(0.35); t.chatSidePanelFill = surface
    t.cardFailedFill = Color(hex: "A94944").opacity(0.12)
    t.generatingGradient = LinearGradient(colors: [tint, surface], startPoint: .leading, endPoint: .trailing)
    t.pausedCardGradient = LinearGradient(colors: [surface, tint], startPoint: .top, endPoint: .bottom)
    t.pausedCardText = muted; t.targetsInactiveTrack = tint; t.targetsInactiveFill = surface
    t.summaryCardShadow = ink.opacity(0.05); t.donutShadow = .clear
    t.sheetFocusHeader = tint; t.sheetDistractionHeader = Color(hex: "A94944").opacity(0.12)
    t.sheetFocusStatText = text; t.sheetDistractionStatText = text
    t.sheetInnerBoxFill = surface; t.sheetInnerBoxBorder = line; t.sheetFooterFill = surface
    t.sheetWheelGradient = LinearGradient(colors: [surface, tint], startPoint: .top, endPoint: .bottom)
    t.sheetWheelBorder = line; t.sheetWheelDimText = muted
    t.dailyGridFill = surface; t.dailyGridBorder = line; t.dailyTotalsFill = tint; t.dailyEmptyCell = tint
    t.dailyDistractionTrack = tint; t.dailyDistractionTrackBorder = line; t.dailyStatValue = text
    t.standupCardGradient = LinearGradient(colors: [surface, surface], startPoint: .top, endPoint: .bottom)
    t.standupCardBorder = line; t.standupBlockersFill = tint; t.standupBlockersBorder = line
    t.inputFill = surface; t.inputBorder = line; t.chatSidePanelHeaderFill = tint; t.chatCodeFill = tint
    return t
  }
}

/// Adaptive brand tokens for static sub-screen design enums and decorations.
enum CompanionPalette {
  private static func adaptive(_ light: String, _ dark: String) -> Color {
    Color.dayflowAdaptive(light: NSColor(hex: light)!, dark: NSColor(hex: dark)!)
  }
  private static func brand(teal: (String, String), burgundy: (String, String)) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      let pair = TealbrickPalette.current == .burgundy ? burgundy : teal
      let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return NSColor(hex: dark ? pair.1 : pair.0)!
    })
  }
  static var accent: Color { brand(teal: ("087373", "72D4CA"), burgundy: ("A94944", "E7ACA7")) }
  static var fill: Color { brand(teal: ("034A4A", "17544F"), burgundy: ("552522", "813F3B")) }
  static var soft: Color { accent.opacity(0.12) }
  static var canvas: Color { adaptive("F3F1E9", "142321") }
  static var surface: Color { adaptive("FFFEFA", "1C2B2A") }
  static var border: Color { adaptive("C9D0C5", "3C5550") }
  static var text: Color { adaptive("173F3C", "F3F1E9") }
  static var muted: Color { adaptive("526560", "AEC3BC") }
  static var alert: Color { adaptive("A94944", "E7ACA7") }
}
