import SwiftUI
import TBDDesign

struct WeeklyInteractionGraphNodeBadge: View {
  let node: WeeklyInteractionGraphNodeLayout

  var shellGradient: LinearGradient {
    switch node.category {
    case .work:
      return LinearGradient(
        colors: [TBDColor.tealWash, TBDColor.tile],
        startPoint: .top,
        endPoint: .bottom
      )
    case .personal:
      return LinearGradient(
        colors: [TBDColor.plate, TBDColor.tile],
        startPoint: .top,
        endPoint: .bottom
      )
    case .distraction:
      return LinearGradient(
        colors: [TBDColor.brickWash, TBDColor.tile],
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(shellGradient)
        .overlay(
          Circle()
            .stroke(node.category.borderColor, lineWidth: node.borderWidth)
        )
        .shadow(
          color: node.category.borderColor.opacity(node.isCenter ? 0.22 : 0.08),
          radius: node.isCenter ? 5 : 2,
          x: 0,
          y: 0
        )

      WeeklyInteractionGraphGlyphView(
        glyph: node.glyph,
        diameter: node.diameter
      )
      .padding(node.diameter * 0.2)
    }
  }
}

struct WeeklyInteractionGraphGlyphView: View {
  let glyph: WeeklyInteractionGraphGlyph
  let diameter: CGFloat

  var body: some View {
    Group {
      switch glyph {
      case .figma:
        WeeklyInteractionFigmaGlyph()
      case .youtube:
        WeeklyInteractionYouTubeGlyph()
      case .x:
        WeeklyInteractionMonogramGlyph(
          text: String(localized: "X"),
          background: TBDColor.ink,
          foreground: TBDColor.paper,
          cornerRadius: diameter * 0.11,
          fontSize: diameter * 0.34
        )
      case .notion:
        WeeklyInteractionNotionGlyph(fontSize: diameter * 0.34)
      case .slack:
        WeeklyInteractionSlackGlyph()
      case .zoom:
        WeeklyInteractionZoomGlyph(fontSize: diameter * 0.24)
      case .reddit:
        WeeklyInteractionMonogramGlyph(
          text: String(localized: "r"),
          background: CompanionPalette.accent,
          foreground: TBDColor.paper,
          cornerRadius: diameter * 0.5,
          fontSize: diameter * 0.34
        )
      case .linear:
        WeeklyInteractionMonogramGlyph(
          text: String(localized: "L"),
          background: CompanionPalette.accent,
          foreground: TBDColor.paper,
          cornerRadius: diameter * 0.12,
          fontSize: diameter * 0.34
        )
      case .framer:
        WeeklyInteractionMonogramGlyph(
          text: String(localized: "F"),
          background: TBDColor.ink,
          foreground: TBDColor.paper,
          cornerRadius: diameter * 0.12,
          fontSize: diameter * 0.34
        )
      case .bookmark:
        WeeklyInteractionBookmarkGlyph()
      case .cube:
        WeeklyInteractionCubeGlyph()
      case .burst:
        WeeklyInteractionBurstGlyph()
      case .bullseye:
        WeeklyInteractionBullseyeGlyph()
      case .bars:
        WeeklyInteractionBarsGlyph()
      case .asset(let name):
        Image(name)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      case .monogram(let text, let backgroundHex, let foregroundHex):
        WeeklyInteractionMonogramGlyph(
          text: text,
          background: Color(hex: backgroundHex),  // design-guard: allow (user app colour carried as hex)
          foreground: Color(hex: foregroundHex),  // design-guard: allow (user app colour carried as hex)
          cornerRadius: diameter * 0.12,
          fontSize: diameter * 0.34
        )
      }
    }
  }
}

struct WeeklyInteractionMonogramGlyph: View {
  let text: String
  let background: Color
  let foreground: Color
  let cornerRadius: CGFloat
  let fontSize: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(background)
      .overlay {
        Text(text)
          .font(TBDFonts.nunito(fontSize, TBDKit.weightLabel))
          .foregroundStyle(foreground)
      }
  }
}

struct WeeklyInteractionFigmaGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let circle = width * 0.28
      let pillWidth = width * 0.56

      ZStack {
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: circle * 0.7, style: .continuous)
              .fill(TBDColor.toneBrick)
              .frame(width: pillWidth, height: circle)

            Circle()
              .fill(TBDColor.toneWood)
              .frame(width: circle, height: circle)
          }

          HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: circle * 0.7, style: .continuous)
              .fill(TBDColor.toneTeal)
              .frame(width: pillWidth, height: circle)

            Circle()
              .fill(TBDColor.toneWood)
              .frame(width: circle, height: circle)
          }

          HStack(spacing: 0) {
            Circle()
              .fill(TBDColor.toneMoss)
              .frame(width: circle, height: circle)

            Spacer(minLength: 0)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

struct WeeklyInteractionYouTubeGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let height = proxy.size.height

      RoundedRectangle(cornerRadius: height * 0.22, style: .continuous)
        .fill(TBDColor.brick)
        .overlay {
          Image(systemName: "play.fill")
            .font(TBDFonts.symbol(width * 0.28, TBDKit.weightNav))
            .foregroundStyle(TBDColor.onBrick)
            .offset(x: width * 0.03)
        }
    }
    .aspectRatio(1.35, contentMode: .fit)
  }
}

struct WeeklyInteractionSlackGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let bar = width * 0.18
      let long = width * 0.44

      ZStack {
        RoundedRectangle(cornerRadius: bar * 0.65, style: .continuous)
          .fill(TBDColor.toneTeal)
          .frame(width: bar, height: long)
          .offset(x: -bar * 0.9, y: long * 0.2)

        RoundedRectangle(cornerRadius: bar * 0.65, style: .continuous)
          .fill(TBDColor.toneMoss)
          .frame(width: long, height: bar)
          .offset(x: -bar * 0.2, y: bar * 0.9)

        RoundedRectangle(cornerRadius: bar * 0.65, style: .continuous)
          .fill(TBDColor.toneBrick)
          .frame(width: bar, height: long)
          .offset(x: bar * 0.9, y: -long * 0.2)

        RoundedRectangle(cornerRadius: bar * 0.65, style: .continuous)
          .fill(TBDColor.toneWood)
          .frame(width: long, height: bar)
          .offset(x: bar * 0.2, y: -bar * 0.9)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

struct WeeklyInteractionNotionGlyph: View {
  let fontSize: CGFloat

  var body: some View {
    TBDBrickShape()
      .fill(TBDColor.tile)
      .overlay(
        TBDBrickShape()
          .strokeBorder(TBDColor.ink, lineWidth: TBDKit.hair)
      )
      .overlay {
        Text("N")
          .font(TBDFonts.nunito(fontSize, TBDKit.weightLabel))
          .foregroundStyle(TBDColor.ink)
      }
  }
}

struct WeeklyInteractionZoomGlyph: View {
  let fontSize: CGFloat

  var body: some View {
    TBDBrickShape()
      .fill(TBDColor.tealInk)
      .overlay {
        Image(systemName: "video.fill")
          .font(TBDFonts.symbol(fontSize, TBDKit.weightNav))
          .foregroundStyle(TBDColor.paper)
      }
  }
}

struct WeeklyInteractionBookmarkGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width

      Image(systemName: "bookmark.fill")
        .resizable()
        .scaledToFit()
        .foregroundStyle(CompanionPalette.accent)
        .frame(width: width * 0.56, height: width * 0.68)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct WeeklyInteractionCubeGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height)

      ZStack {
        Image(systemName: "shippingbox.fill")
          .resizable()
          .scaledToFit()
          .foregroundStyle(CompanionPalette.accent)
          .frame(width: size * 0.78, height: size * 0.78)

        Image(systemName: "shippingbox")
          .resizable()
          .scaledToFit()
          .foregroundStyle(TBDColor.muted)
          .frame(width: size * 0.78, height: size * 0.78)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct WeeklyInteractionBurstGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height)
      let strokeLength = size * 0.34
      let strokeWidth = max(size * 0.028, 1.2)

      ZStack {
        ForEach(0..<12, id: \.self) { index in
          Capsule(style: .continuous)
            .fill(CompanionPalette.accent)
            .frame(width: strokeWidth, height: strokeLength)
            .offset(y: -size * 0.18)
            .rotationEffect(.degrees(Double(index) * 30))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct WeeklyInteractionBullseyeGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height)

      ZStack {
        Circle()
          .stroke(TBDColor.toneMoss, lineWidth: max(size * 0.1, 2))
          .frame(width: size * 0.66, height: size * 0.66)

        Circle()
          .stroke(TBDColor.toneMossInk, lineWidth: max(size * 0.08, 1.5))
          .frame(width: size * 0.38, height: size * 0.38)

        Circle()
          .fill(TBDColor.toneMossInk)
          .frame(width: size * 0.12, height: size * 0.12)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct WeeklyInteractionBarsGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let barWidth = width * 0.12

      HStack(alignment: .bottom, spacing: width * 0.06) {
        RoundedRectangle(cornerRadius: barWidth, style: .continuous)
          .fill(TBDColor.toneStone)
          .frame(width: barWidth, height: width * 0.34)

        RoundedRectangle(cornerRadius: barWidth, style: .continuous)
          .fill(TBDColor.toneStoneInk)
          .frame(width: barWidth, height: width * 0.54)

        RoundedRectangle(cornerRadius: barWidth, style: .continuous)
          .fill(TBDColor.toneStone)
          .frame(width: barWidth, height: width * 0.24)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct WeeklyInteractionGraphLegend: View {
  var body: some View {
    HStack(spacing: 24) {
      legendItem(for: .work, title: String(localized: "Work"))
      legendItem(for: .personal, title: String(localized: "Personal"))
      legendItem(for: .distraction, title: String(localized: "Distraction"))
    }
  }

  func legendItem(
    for category: WeeklyInteractionGraphCategory,
    title: String
  ) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: TBDKit.radiusSwatch, style: .continuous)
        .fill(category.fillColor)
        .overlay(
          RoundedRectangle(cornerRadius: TBDKit.radiusSwatch, style: .continuous)
            .stroke(category.borderColor, lineWidth: 1.75)
        )
        .frame(width: 16, height: 12)

      Text(title)
        .font(WeeklyFont.axis)
        .foregroundStyle(TBDColor.ink)
    }
  }
}
