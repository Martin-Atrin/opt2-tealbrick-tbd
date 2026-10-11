// Teal Brick motion tokens: one small set of animation curves shared by every TBD surface.
import SwiftUI

public enum TBDMotion {
    /// Hover, press and other small state flips.
    public static let instant: Animation = .easeOut(duration: 0.12)

    /// Fades, menus and toasts appearing.
    public static let quick: Animation = .easeOut(duration: 0.2)

    /// Content changes and tab or section switches.
    public static let standard: Animation = .easeInOut(duration: 0.25)

    /// Moving or resizing elements, sheets, panels and overlays.
    public static let spring: Animation = .spring(response: 0.3, dampingFraction: 0.88)

    /// Large surfaces, onboarding and slow reveals.
    public static let gentle: Animation = .easeInOut(duration: 0.4)

    /// Pulses and breathing indicators. `duration` is the time of one half cycle.
    public static func repeating(_ duration: Double) -> Animation {
        .easeInOut(duration: duration).repeatForever(autoreverses: true)
    }
}
