import MacParakeet
import SwiftUI

struct SunriseGlassPillToggleStyle: ToggleStyle {
  var onColors: [Color] = [
    CompanionPalette.soft,
    CompanionPalette.fill,
  ]
  var offColors: [Color] = [
    CompanionPalette.border,
    CompanionPalette.border,
  ]
  var trackWidth: CGFloat = 64
  var trackHeight: CGFloat = 32
  var knobSize: CGFloat = 28

  @Environment(\.colorScheme) private var scheme

  func makeBody(configuration: Configuration) -> some View {
    let isOn = configuration.isOn
    Button {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
        configuration.isOn.toggle()
        #if os(iOS)
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
      }
    } label: {
      ZStack(alignment: isOn ? .trailing : .leading) {

        // Track: flat brick fill, hairline border, no glass/blur/gloss.
        RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
          .fill(
            LinearGradient(
              colors: isOn ? onColors : offColors,
              startPoint: .topLeading, endPoint: .bottomTrailing
            )
          )
          .overlay(
            RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
              .stroke(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline)
          )
          .frame(width: trackWidth, height: trackHeight)

        // Knob: the sliding indicator is genuinely circular content.
        Circle()
          .fill(Color.white)
          .overlay(
            Circle().strokeBorder(.black.opacity(0.06), lineWidth: 0.75)
          )
          .frame(width: knobSize, height: knobSize)
          .padding(2)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityValue(Text(isOn ? String(localized: "On") : String(localized: "Off")))
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}
