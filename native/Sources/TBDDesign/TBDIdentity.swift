import AppKit
import SwiftUI

// Identity components shared with the web kit (DESIGN-SYSTEM §5b, §5c; C146): AppIcon, AppMark, the app chip and the
// compact agent card of the canvas. Values from TBDKit/TBDColor; the stills are the production art (design/apps).

/// AppIcon: the app's production still, square brick crop on spot paper. Sizes 16/24/32/48/64; the crop follows the
/// kit rule (48+ = the full centre square, 24–32 = 125 %, 16 = 150 % with the 2pt swatch corner).
public struct TBDAppIcon: View {
    let app: TBDApp?
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    public init(_ id: String, size: CGFloat = 48) { self.app = TBDApps.app(id); self.size = size }
    public init(app: TBDApp, size: CGFloat = 48) { self.app = app; self.size = size }

    static func image(_ slug: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: "\(slug)@2x", withExtension: "webp", subdirectory: "Apps") else { return nil }
        return NSImage(contentsOf: url)
    }
    private var crop: CGFloat { size >= 48 ? 1 : size >= 24 ? 1.25 : 1.5 }
    private var radius: CGFloat { size <= 16 ? TBDKit.radiusSwatch : TBDKit.radiusBrick }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            TBDColor.spotPaper
            if let app, let image = Self.image(app.slug) {
                // The still is 1200 × 540 with the object in its centre square: height = size × crop, width follows.
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: size * crop * 1200 / 540, height: size * crop)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // Kit: a 1.5pt line ring in light (the still's paper meets the page); none in dark.
        .overlay { if scheme == .light { shape.strokeBorder(TBDColor.line, lineWidth: TBDMetrics.appIconRingLight) } }
        .accessibilityLabel(app?.name ?? "App")
    }
}

/// AppMark: AppIcon plus the app name (900).
public struct TBDAppMark: View {
    let app: TBDApp
    let size: CGFloat
    public init(app: TBDApp, size: CGFloat = 32) { self.app = app; self.size = size }
    public var body: some View {
        HStack(spacing: 10) {
            TBDAppIcon(app: app, size: size).accessibilityHidden(true)
            Text(app.name).font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightHead)).foregroundStyle(TBDColor.ink).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// App chip: a connected app as an object (brick, not a state pill): the app's own colour with white text and a
/// 16pt AppIcon. 28pt high, 13/700.
public struct TBDAppChip: View {
    let app: TBDApp
    public init(app: TBDApp) { self.app = app }
    public var body: some View {
        HStack(spacing: 6) {
            TBDAppIcon(app: app, size: 16).accessibilityHidden(true)
            Text(app.name).font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav)).foregroundStyle(TBDColor.appOn).lineLimit(1)
        }
        .padding(.leading, TBDMetrics.appChipPaddingLeading).padding(.trailing, TBDMetrics.appChipPaddingTrailing)
        .frame(minHeight: 28)
        .background(app.color, in: TBDBrickShape())
        .accessibilityElement(children: .combine)
    }
}

/// The compact agent card of the canvas (C146): neutral tile, line-strong ring, initial avatar (ink brick), name 16/900,
/// harness · mode (13/700 muted) and a status pill. Selected = 2pt ink ring. Width 208 on the canvas; lists may stretch it.
public struct TBDAgentCard<Trailing: View>: View {
    let name: String
    let harness: String
    let mode: String?
    let status: (text: String, kind: TBDStatus)?
    let selected: Bool
    let trailing: Trailing
    public init(name: String, harness: String, mode: String? = nil, status: (text: String, kind: TBDStatus)? = nil, selected: Bool = false,
                @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.name = name; self.harness = harness; self.mode = mode; self.status = status; self.selected = selected; self.trailing = trailing()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: TBDKit.s2) {
            HStack(spacing: 10) {
                TBDAgentAvatar(name: name)
                Text(name).font(TBDFonts.nunito(TBDKit.textBody, TBDKit.weightHead)).foregroundStyle(TBDColor.ink).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text([harness, mode].compactMap { $0 }.joined(separator: " · "))
                    .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav)).foregroundStyle(TBDColor.muted).lineLimit(1)
                Spacer(minLength: 0)
                if let status { TBDTag(status.text, status: status.kind) }
            }
            trailing
        }
        .padding(.top, 10).padding(.trailing, 14).padding(.bottom, 12).padding(.leading, 12)
        .background(TBDColor.tile, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(selected ? TBDColor.ink : TBDColor.lineStrong, lineWidth: selected ? 2 : TBDKit.hair))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The agent's initial in a 32pt ink brick (14/900 on the primary pair).
public struct TBDAgentAvatar: View {
    let name: String
    let size: CGFloat
    public init(name: String, size: CGFloat = 32) { self.name = name; self.size = size }
    public var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightHead))
            .foregroundStyle(TBDColor.primaryOn)
            .frame(width: size, height: size)
            .background(TBDColor.primaryFill, in: TBDBrickShape())
            .accessibilityHidden(true)
    }
}
