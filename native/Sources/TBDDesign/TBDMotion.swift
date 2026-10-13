// Motion: the kit's durations and its one ease (TBDKit, generated from the toolkit tokens).
// Reduced motion (C128): every animation has a still end state; use `TBDMotion.animation(_:reduce:)`.
import SwiftUI

public enum TBDMotion {
    private static func curve(_ c: (Double, Double, Double, Double), _ duration: Double) -> Animation {
        .timingCurve(c.0, c.1, c.2, c.3, duration: duration)
    }
    /// Exits, hover and press flips (--tb-dur-exit).
    public static let instant: Animation = curve(TBDKit.ease, TBDKit.durExit)
    /// Underlines, small fades, menus appearing (--tb-dur-fast).
    public static let quick: Animation = curve(TBDKit.ease, TBDKit.durFast)
    /// Opening a surface, content and section switches (--tb-dur).
    public static let standard: Animation = curve(TBDKit.ease, TBDKit.dur)
    /// Fill and colour changes on controls (--tb-dur-color).
    public static let color: Animation = curve(TBDKit.ease, TBDKit.durColor)
    /// Moving or resizing sheets, panels and overlays (--tb-dur-slow). The kit has no springs.
    public static let spring: Animation = curve(TBDKit.ease, TBDKit.durSlow)
    /// Large surfaces and slow reveals (--tb-dur-slow).
    public static let gentle: Animation = curve(TBDKit.ease, TBDKit.durSlow)
    /// StepFlow: the middle fades OUT to the ground (ease-in), then the next step fades IN (ease-out), C128.
    public static let stepOut: Animation = curve(TBDKit.easeIn, TBDKit.durStep)
    public static let stepIn: Animation = curve(TBDKit.easeOut, TBDKit.durStep)

    /// Pulses and breathing indicators. `duration` is the time of one half cycle.
    public static func repeating(_ duration: Double) -> Animation {
        curve(TBDKit.ease, duration).repeatForever(autoreverses: true)
    }
    /// `nil` (no animation) when the user asks for reduced motion.
    public static func animation(_ animation: Animation, reduce: Bool) -> Animation? { reduce ? nil : animation }
}
