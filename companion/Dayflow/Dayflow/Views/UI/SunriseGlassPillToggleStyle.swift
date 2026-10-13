import TBDDesign
import SwiftUI

/// Switch toggle on the kit's switch style (pill track, ink-soft thumb; on = teal-ink track).
/// The colour and size properties are kept for source compatibility; the kit owns the look.
struct SunriseGlassPillToggleStyle: ToggleStyle {
  var onColors: [Color] = []
  var offColors: [Color] = []
  var trackWidth: CGFloat = 64
  var trackHeight: CGFloat = 32
  var knobSize: CGFloat = 28

  func makeBody(configuration: Configuration) -> some View {
    TBDSwitchStyle().makeBody(configuration: configuration)
      .pointingHandCursor()
  }
}
