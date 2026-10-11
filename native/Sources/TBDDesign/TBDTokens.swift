// Teal Brick design tokens (teal and burgundy palettes, light and dark).
import AppKit
import SwiftUI

public enum TBDTokens {
    public enum Palette: String { case teal, burgundy }
    /// Current palette preference shared with Companion (`tealbrickPalette`).
    public static var palette: Palette { Palette(rawValue: UserDefaults.standard.string(forKey: "tealbrickPalette") ?? "") ?? .teal }

    public static let canvas = dynamic(0xF3F1E9, 0x142321)
    public static let paper = dynamic(0xFFFEFA, 0x1C2B2A)
    public static let ink = dynamic(0x173F3C, 0xF3F1E9)
    public static let muted = dynamic(0x526560, 0xAEC3BC)
    public static let border = dynamic(0xC9D0C5, 0x3C5550)
    public static let selected = dynamic(0xD5DED1, 0x2D4944)
    public static let hover = dynamic(0xDFE5DA, 0x273D39)
    public static let onPrimary = dynamic(0xF3F1E9, 0xF3F1E9)
    public static let alert = dynamic(0xA8442F, 0xE7ACA7)
    public static var accent: Color { brand((0x087373, 0x72D4CA), (0xA94944, 0xE7ACA7)) }
    public static var fill: Color { brand((0x034A4A, 0x17544F), (0x552522, 0x813F3B)) }

    /// Muted brick set for categories and charts; never used for chrome.
    public static let data: [Color] = [
        dynamic(0x3E7F78, 0x7DBDB5),
        dynamic(0x6B7F3E, 0xAFC07F),
        dynamic(0xA07A2C, 0xD9B46A),
        dynamic(0xA4583F, 0xDE9A82),
        dynamic(0x4F6479, 0x9DB2C6),
        dynamic(0x7A4E6E, 0xC49AB9),
    ]

    public enum Radius {
        public static let base: CGFloat = 2
        public static let xs: CGFloat = 3
        public static let sm: CGFloat = 4
    }
    public enum Stroke {
        public static let hairline: CGFloat = 1
        public static let bar: CGFloat = 2
    }
    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32
    }
    public struct HardShadow: Sendable { public let x: CGFloat; public let y: CGFloat; public let opacity: Double }
    public enum Shadow {
        public static let brickSm = HardShadow(x: 3, y: 3, opacity: 0.09)
        public static let brickMd = HardShadow(x: 6, y: 6, opacity: 0.08)
        public static let brickLg = HardShadow(x: 12, y: 12, opacity: 0.09)
    }
    public enum Control {
        public static let minHeight: CGFloat = 34
        public static let paddingX: CGFloat = 14
    }
    public enum Typography {
        public static let display: Font = .custom("Georgia", size: 28).weight(.regular)
        public static let displayTracking: CGFloat = -0.7
        public static let title: Font = .custom("Switzer", size: 17).weight(.semibold)
        public static let titleTracking: CGFloat = -0.2
        public static let body: Font = .custom("Switzer", size: 13).weight(.regular)
        public static let bodyTracking: CGFloat = 0
        public static let control: Font = .custom("Switzer", size: 13).weight(.medium)
        public static let controlTracking: CGFloat = 0
        public static let label: Font = .system(size: 10, weight: .medium, design: .monospaced)
        public static let labelTracking: CGFloat = 0.8
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    private static func isDark(_ appearance: NSAppearance) -> Bool { appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { isDark($0) ? rgb(dark) : rgb(light) })
    }
    private static func brand(_ teal: (UInt32, UInt32), _ burgundy: (UInt32, UInt32)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let pair = palette == .burgundy ? burgundy : teal
            return isDark(appearance) ? rgb(pair.1) : rgb(pair.0)
        })
    }
}
