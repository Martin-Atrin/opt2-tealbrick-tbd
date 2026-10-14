// tbd-design-shots --sameness <outDir>: the NATIVE column of the TBD sameness proof (chat/scripts/design-sameness.ts).
// Each TBDDesign component is rendered in its own fixed cell (2x, light and dark) and measured. Output in <outDir>:
//   <component>-native-<light|dark>.png   the cell
//   native-metrics.json                   { cells, probes: { light|dark: { <probe>: { <prop>: { v, src } } } } }
// Source of a value: "measured" = a frame read from the rendered SwiftUI layout (GeometryReader preference) or from the
// rendered pixels of the cell; "declared" = the token constant the component itself is built from (TBDKit / TBDTokens /
// TBDColor, resolved under the appearance through NSColor). The component views are not changed.
import AppKit
import SwiftUI
import TBDDesign

// MARK: - frame probes

private struct FramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

private final class FrameStore { var frames: [String: CGRect] = [:] }

private extension View {
    func probe(_ id: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: FramesKey.self, value: [id: g.frame(in: .named("cell"))]) })
    }
}

/// A fixed cell: 16pt of paper around the content, top-left aligned (the web and Chat cells use the same box).
private struct SCell<Content: View>: View {
    let size: CGSize
    let store: FrameStore
    let content: Content
    var body: some View {
        content
            .padding(16)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(TBDColor.paper)
            .coordinateSpace(name: "cell")
            .onPreferenceChange(FramesKey.self) { store.frames = $0 }
    }
}

// MARK: - values

private typealias Px = (r: Int, g: Int, b: Int)

private struct Probe {
    var props: [String: [String: Any]] = [:]
    mutating func measured(_ key: String, _ value: Any) { props[key] = ["v": value, "src": "measured"] }
    mutating func declared(_ key: String, _ value: Any) { props[key] = ["v": value, "src": "declared"] }
}

private func rounded(_ v: CGFloat) -> Double { (Double(v) * 100).rounded() / 100 }

private func weightNumber(_ w: Font.Weight) -> Int {
    switch w {
    case .regular: return 400
    case .bold: return 700
    case .heavy: return 800
    case .black: return 900
    default: return 0
    }
}

/// A colour resolved under one appearance as "#rrggbb", "#rrggbb@0.35" (alpha) or "transparent". `alpha` multiplies.
private func hex(_ color: Color, dark: Bool, alpha: Double = 1) -> String {
    var out = "transparent"
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
        let a = Double(c.alphaComponent) * alpha
        if a < 0.005 { return }
        let s = String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        out = a >= 0.995 ? s : s + "@" + String(format: "%.2f", a)
    }
    return out
}

private func rgb(_ color: Color, dark: Bool) -> Px {
    var out: Px = (0, 0, 0)
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
        out = (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    return out
}

// MARK: - rendering and pixel measuring

@MainActor private func renderCell<V: View>(_ view: V, size: CGSize, dark: Bool) -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    host.layoutSubtreeIfNeeded()
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = size
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        host.cacheDisplay(in: host.bounds, to: rep)
    }
    return rep
}

/// The bounding box (in points) of the pixels near `target` inside `region` (points), or nil when none.
private func bbox(_ rep: NSBitmapImageRep, region: CGRect, near target: Px, tolerance: Int = 14) -> CGRect? {
    guard let data = rep.bitmapData else { return nil }
    let spp = rep.samplesPerPixel, row = rep.bytesPerRow
    let x0 = max(0, Int(region.minX * 2)), x1 = min(rep.pixelsWide, Int(region.maxX * 2))
    let y0 = max(0, Int(region.minY * 2)), y1 = min(rep.pixelsHigh, Int(region.maxY * 2))
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in y0..<y1 { for x in x0..<x1 {
        let o = y * row + x * spp
        let dr = abs(Int(data[o]) - target.r), dg = abs(Int(data[o + 1]) - target.g), db = abs(Int(data[o + 2]) - target.b)
        if dr + dg + db <= tolerance {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    } }
    guard maxX >= 0 else { return nil }
    return CGRect(x: Double(minX) / 2, y: Double(minY) / 2, width: Double(maxX - minX + 1) / 2, height: Double(maxY - minY + 1) / 2)
}

// MARK: - the cells

private struct CellSpec {
    let id: String
    let size: CGSize
}

private let cellSpecs: [CellSpec] = [
    CellSpec(id: "button", size: CGSize(width: 320, height: 76)),
    CellSpec(id: "field", size: CGSize(width: 320, height: 112)),
    CellSpec(id: "select", size: CGSize(width: 320, height: 112)),
    CellSpec(id: "card", size: CGSize(width: 320, height: 96)),
    CellSpec(id: "tag", size: CGSize(width: 320, height: 60)),
    CellSpec(id: "tabs", size: CGSize(width: 320, height: 76)),
    CellSpec(id: "stepflow", size: CGSize(width: 592, height: 632)),
    CellSpec(id: "notice", size: CGSize(width: 360, height: 160)),
    CellSpec(id: "agentcard", size: CGSize(width: 240, height: 124)),
    CellSpec(id: "appchip", size: CGSize(width: 296, height: 120)),
]

private struct ButtonCell: View {
    var body: some View {
        HStack(spacing: TBDKit.s3) {
            Button {} label: { Text("Primary").probe("button-primary.label") }.buttonStyle(TBDButtonStyle(.primary)).probe("button-primary")
            Button {} label: { Text("Secondary").probe("button-secondary.label") }.buttonStyle(TBDButtonStyle(.secondary)).probe("button-secondary")
        }
    }
}
private struct FieldCell: View {
    @State private var text = "Novak Dental"
    var body: some View { TBDField("Workspace name", text: $text).frame(width: 288) }
}
private struct SelectCell: View {
    @State private var choice = "new"
    var body: some View {
        TBDSelect("Destination", selection: $choice, options: [("new", "Create new project…"), ("sandbox", "studio-sandbox")]).frame(width: 288)
    }
}
private struct CardCell: View {
    var body: some View {
        Text("Card content").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.inkSoft)
            .frame(width: 240, height: 24, alignment: .leading)
            .tbdCard()
            .probe("card")
    }
}
private struct TagCell: View {
    var body: some View {
        HStack(spacing: TBDKit.s3) {
            TBDTag("Running", status: .live).probe("tag-live")
            TBDTag("Needs you", status: .needsYou).probe("tag-needs-you")
        }
    }
}
private struct TabsCell: View {
    var body: some View {
        HStack(spacing: TBDKit.s2) {
            TBDNavItem("Current", current: true) {}.frame(width: 112).probe("tab-current")
            TBDNavItem("Other", current: false) {}.frame(width: 112).probe("tab-idle")
        }
    }
}
private struct StepCell: View {
    @State private var step = 1
    var body: some View {
        TBDStepFlow(steps: [
            TBDStep("Provider") { Text("Choose a provider.").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft) },
            TBDStep("Key", optional: true, skipLabel: "Skip") { Text("Add the API key.").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft) },
            TBDStep("Model", nextLabel: "Save") { Text("Pick a model.").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft) },
        ], current: $step, size: CGSize(width: 560, height: TBDKit.stepflowHeight)) {}
        .clipShape(TBDBrickShape())
        .probe("stepflow")
    }
}
private struct NoticeCell: View {
    var body: some View {
        VStack(alignment: .leading, spacing: TBDKit.s3) {
            TBDNotice("Updated and running.", tone: .live).probe("notice-live")
            TBDNotice("Payment failed. Try again.", tone: .needsYou).probe("notice-needs-you")
        }
        .frame(width: 328)
    }
}
private struct AgentCell: View {
    var body: some View {
        TBDAgentCard(name: "Front desk", harness: "Claude Code", status: ("Live", .live))
            .frame(width: 208)
            .probe("agent-card")
    }
}
private struct AppChipCell: View {
    var body: some View {
        VStack(alignment: .leading, spacing: TBDKit.s2) {
            if let app = TBDApps.app("knowledge") {
                TBDAppChip(app: app).probe("appchip")
                TBDAppIcon(app: app, size: 16).probe("appchip-icon")
            }
        }
    }
}

// MARK: - measuring one cell

private func edge(_ p: inout Probe, _ color: String?, width: CGFloat = TBDKit.hair) {
    if let color { p.declared("edgeColor", color); p.declared("edgeWidth", Double(width)) }
    else { p.declared("edgeColor", "none"); p.declared("edgeWidth", 0.0) }
}

@MainActor private func measure(_ id: String, frames f: [String: CGRect], rep: NSBitmapImageRep, dark: Bool) -> [String: Probe] {
    var out: [String: Probe] = [:]
    let family = TBDFonts.family
    func h(_ c: Color, _ alpha: Double = 1) -> String { hex(c, dark: dark, alpha: alpha) }

    switch id {
    case "button":
        for (name, role) in [("button-primary", TBDButtonRole.primary), ("button-secondary", .secondary)] {
            var p = Probe()
            let pair = role.pair(.normal)
            guard let box = f[name], let label = f["\(name).label"] else { continue }
            p.declared("fontFamily", family); p.declared("fontSize", Double(TBDKit.textControl)); p.declared("fontWeight", weightNumber(TBDKit.weightLabel))
            p.measured("padL", rounded(label.minX - box.minX)); p.measured("padR", rounded(box.maxX - label.maxX))
            p.measured("height", rounded(box.height))
            p.declared("radius", Double(TBDKit.radiusBrick))
            p.declared("bg", h(pair.fill)); p.declared("color", h(pair.on))
            edge(&p, pair.edge.map { h($0) })
            out[name] = p
        }
    case "field":
        var label = Probe()
        label.declared("fontFamily", family); label.declared("fontSize", Double(TBDKit.textLabel)); label.declared("fontWeight", weightNumber(TBDKit.weightLabel))
        label.declared("color", h(TBDColor.ink))
        out["field-label"] = label
        var p = Probe()
        let ring = bbox(rep, region: CGRect(x: 0, y: 0, width: 320, height: 112), near: rgb(TBDColor.fieldEdge, dark: dark))
        p.declared("fontFamily", family); p.declared("fontSize", Double(TBDKit.textControl)); p.declared("fontWeight", weightNumber(TBDKit.weightBody))
        p.declared("padL", Double(TBDTokens.Control.paddingX)); p.declared("padR", Double(TBDTokens.Control.paddingX))
        if let ring { p.measured("height", rounded(ring.height)); p.measured("width", rounded(ring.width)) }
        p.declared("radius", Double(TBDKit.radiusBrick))
        p.declared("bg", h(TBDColor.fieldFill)); p.declared("color", h(TBDColor.fieldOn))
        edge(&p, h(TBDColor.fieldEdge))
        out["field-input"] = p
    case "select":
        var label = Probe()
        label.declared("fontFamily", family); label.declared("fontSize", Double(TBDKit.textLabel)); label.declared("fontWeight", weightNumber(TBDKit.weightLabel))
        label.declared("color", h(TBDColor.ink))
        out["select-label"] = label
        var p = Probe()
        let ring = bbox(rep, region: CGRect(x: 0, y: 0, width: 320, height: 112), near: rgb(TBDColor.fieldEdge, dark: dark))
        p.declared("fontFamily", family); p.declared("fontSize", Double(TBDKit.textControl)); p.declared("fontWeight", weightNumber(TBDKit.weightLabel))
        p.declared("padL", Double(TBDTokens.Control.paddingX)); p.declared("padR", Double(TBDTokens.Control.paddingX))
        if let ring { p.measured("height", rounded(ring.height)); p.measured("width", rounded(ring.width)) }
        p.declared("radius", Double(TBDKit.radiusBrick))
        p.declared("bg", h(TBDColor.fieldFill)); p.declared("color", h(TBDColor.fieldOn))
        edge(&p, h(TBDColor.fieldEdge))
        out["select-trigger"] = p
    case "card":
        guard let box = f["card"] else { break }
        var p = Probe()
        p.measured("padL", rounded((box.width - 240) / 2)); p.measured("padR", rounded((box.width - 240) / 2))
        p.measured("padT", rounded((box.height - 24) / 2)); p.measured("padB", rounded((box.height - 24) / 2))
        p.declared("radius", Double(TBDKit.radiusBrick))
        p.declared("bg", h(TBDColor.tile)); edge(&p, h(TBDColor.line))
        out["card"] = p
    case "tag":
        for (name, status) in [("tag-live", TBDStatus.live), ("tag-needs-you", .needsYou)] {
            guard let box = f[name] else { continue }
            let (fill, on, line): (Color, Color, Color) = status == .live
                ? (TBDColor.statusLiveFill, TBDColor.statusLiveOn, TBDColor.statusLiveEdge)
                : (TBDColor.statusNeedsYouFill, TBDColor.statusNeedsYouOn, TBDColor.statusNeedsYouEdge)
            var p = Probe()
            p.declared("fontFamily", family); p.declared("fontSize", Double(TBDKit.textTag)); p.declared("fontWeight", weightNumber(TBDKit.weightNav))
            p.declared("padL", Double(TBDKit.s3)); p.declared("padR", Double(TBDKit.s3))
            p.measured("height", rounded(box.height))
            p.declared("radius", "pill")
            p.declared("bg", h(fill)); p.declared("color", h(on)); edge(&p, h(line))
            out[name] = p
        }
    case "tabs":
        for (name, current) in [("tab-current", true), ("tab-idle", false)] {
            guard let box = f[name] else { continue }
            var p = Probe()
            p.declared("fontFamily", family); p.declared("fontSize", Double(TBDKit.textControl))
            p.declared("fontWeight", weightNumber(current ? TBDKit.weightLabel : TBDKit.weightNav))
            p.declared("padL", Double(TBDKit.s3)); p.declared("padR", Double(TBDKit.s3))
            p.measured("height", rounded(box.height))
            p.declared("radius", Double(TBDKit.radiusBrick))
            p.declared("bg", h(current ? TBDColor.tabCurrentFill : TBDColor.tabFill)); p.declared("color", h(current ? TBDColor.tabCurrentOn : TBDColor.tabOn))
            edge(&p, nil)   // TBDNavItemBody draws no ring in any state
            out[name] = p
        }
    case "stepflow":
        guard let box = f["stepflow"] else { break }
        var d = Probe()
        d.measured("width", rounded(box.width)); d.measured("height", rounded(box.height))
        d.declared("bg", h(TBDColor.tile))
        out["stepflow"] = d
        let steps: [(String, Font.Weight, String)] = [
            ("stepflow-step-done", TBDKit.weightNav, h(TBDColor.tealInk)),
            ("stepflow-step-current", TBDKit.weightLabel, h(TBDColor.ink)),
            ("stepflow-step-upcoming", TBDKit.weightNav, h(TBDColor.ink, 0.62)),
        ]
        for (name, weight, colour) in steps {
            var p = Probe()
            p.declared("fontFamily", family); p.declared("fontSize", Double(TBDKit.textTag)); p.declared("fontWeight", weightNumber(weight)); p.declared("color", colour)
            out[name] = p
        }
        var body = Probe(); body.declared("padL", 28.0); body.declared("padR", 28.0)   // TBDStepFlow: .padding(.horizontal, 28)
        out["stepflow-body"] = body
        var foot = Probe()
        foot.declared("padL", 28.0); foot.declared("padR", 28.0); foot.declared("padT", Double(TBDKit.s4)); foot.declared("padB", Double(TBDKit.s5))
        foot.declared("edgeColor", h(TBDColor.line)); foot.declared("edgeWidth", Double(TBDKit.hair))   // the Rectangle above the foot
        out["stepflow-foot"] = foot
        let region = CGRect(x: box.minX, y: box.maxY - 90, width: box.width, height: 90)
        let nextPair = TBDButtonRole.primary.pair(.normal), prevPair = TBDButtonRole.secondary.pair(.normal)
        var next = Probe()
        if let r = bbox(rep, region: CGRect(x: box.midX, y: region.minY, width: box.width / 2, height: region.height), near: rgb(nextPair.fill, dark: dark)) { next.measured("height", rounded(r.height)) }
        next.declared("bg", h(nextPair.fill)); next.declared("color", h(nextPair.on))
        out["stepflow-next"] = next
        var prev = Probe()
        if let r = bbox(rep, region: CGRect(x: box.minX, y: region.minY, width: 200, height: region.height), near: rgb(prevPair.edge ?? TBDColor.ink, dark: dark)) { prev.measured("height", rounded(r.height)) }
        prev.declared("bg", h(prevPair.fill)); prev.declared("color", h(prevPair.on)); edge(&prev, prevPair.edge.map { h($0) })
        out["stepflow-prev"] = prev
    case "notice":
        for (name, tone) in [("notice-live", TBDNoticeTone.live), ("notice-needs-you", .needsYou)] {
            guard let box = f[name] else { continue }
            let (fill, on, line): (Color, Color, Color) = tone == .live
                ? (TBDColor.statusLiveFill, TBDColor.statusLiveOn, TBDColor.statusLiveEdge)
                : (TBDColor.statusNeedsYouFill, TBDColor.statusNeedsYouOn, TBDColor.statusNeedsYouEdge)
            var p = Probe()
            p.declared("fontFamily", family); p.declared("fontSize", Double(TBDKit.textLabel)); p.declared("fontWeight", weightNumber(TBDKit.weightNav))
            p.declared("padL", Double(TBDKit.s4)); p.declared("padR", Double(TBDKit.s4)); p.declared("padT", Double(TBDKit.s3)); p.declared("padB", Double(TBDKit.s3))
            p.measured("height", rounded(box.height))
            p.declared("radius", Double(TBDKit.radiusBrick))
            p.declared("bg", h(fill)); p.declared("color", h(on)); edge(&p, h(line))
            out[name] = p
        }
    case "agentcard":
        guard let box = f["agent-card"] else { break }
        var c = Probe()
        c.measured("width", rounded(box.width)); c.measured("height", rounded(box.height))
        c.declared("padT", 10.0); c.declared("padR", 14.0); c.declared("padB", 12.0); c.declared("padL", 12.0)   // literals in TBDAgentCard
        c.declared("radius", Double(TBDKit.radiusBrick))
        c.declared("bg", h(TBDColor.tile)); edge(&c, h(TBDColor.lineStrong))
        out["agent-card"] = c
        var a = Probe()
        let ink = rgb(TBDColor.primaryFill, dark: dark)
        if let r = bbox(rep, region: CGRect(x: box.minX, y: box.minY, width: 50, height: 50), near: ink, tolerance: 8) { a.measured("width", rounded(r.width)); a.measured("height", rounded(r.height)) }
        a.declared("fontFamily", family); a.declared("fontSize", Double(TBDKit.textControl)); a.declared("fontWeight", weightNumber(TBDKit.weightHead))
        a.declared("radius", Double(TBDKit.radiusBrick)); a.declared("bg", h(TBDColor.primaryFill)); a.declared("color", h(TBDColor.primaryOn))
        out["agent-avatar"] = a
        var n = Probe()
        n.declared("fontFamily", family); n.declared("fontSize", Double(TBDKit.textBody)); n.declared("fontWeight", weightNumber(TBDKit.weightHead)); n.declared("color", h(TBDColor.ink))
        out["agent-name"] = n
        var m = Probe()
        m.declared("fontFamily", family); m.declared("fontSize", Double(TBDKit.textHint)); m.declared("fontWeight", weightNumber(TBDKit.weightNav)); m.declared("color", h(TBDColor.muted))
        out["agent-meta"] = m
    case "appchip":
        guard let box = f["appchip"] else { break }
        let app = TBDApps.app("knowledge")!
        var c = Probe()
        c.declared("padL", 6.0); c.declared("padR", 10.0)   // literals in TBDAppChip
        c.measured("height", rounded(box.height))
        c.declared("radius", Double(TBDKit.radiusBrick)); c.declared("bg", h(app.color)); c.declared("color", h(TBDColor.appOn)); edge(&c, nil)
        out["appchip"] = c
        var nm = Probe()
        nm.declared("fontFamily", family); nm.declared("fontSize", Double(TBDKit.textHint)); nm.declared("fontWeight", weightNumber(TBDKit.weightNav)); nm.declared("color", h(TBDColor.appOn))
        out["appchip-name"] = nm
        var ic = Probe()
        if let i = f["appchip-icon"] { ic.measured("width", rounded(i.width)); ic.measured("height", rounded(i.height)) }
        ic.declared("radius", Double(TBDKit.radiusSwatch)); ic.declared("bg", h(TBDColor.spotPaper)); edge(&ic, nil)   // TBDAppIcon clips; it draws no ring
        out["appchip-icon"] = ic
    default: break
    }
    return out
}

@MainActor private func cellView(_ id: String, store: FrameStore) -> AnyView {
    let size = cellSpecs.first { $0.id == id }!.size
    switch id {
    case "button": return AnyView(SCell(size: size, store: store, content: ButtonCell()))
    case "field": return AnyView(SCell(size: size, store: store, content: FieldCell()))
    case "select": return AnyView(SCell(size: size, store: store, content: SelectCell()))
    case "card": return AnyView(SCell(size: size, store: store, content: CardCell()))
    case "tag": return AnyView(SCell(size: size, store: store, content: TagCell()))
    case "tabs": return AnyView(SCell(size: size, store: store, content: TabsCell()))
    case "stepflow": return AnyView(SCell(size: size, store: store, content: StepCell()))
    case "notice": return AnyView(SCell(size: size, store: store, content: NoticeCell()))
    case "agentcard": return AnyView(SCell(size: size, store: store, content: AgentCell()))
    default: return AnyView(SCell(size: size, store: store, content: AppChipCell()))
    }
}

// MARK: - entry

@MainActor func runSameness(outDir: URL) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    TBDFonts.register()
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var probes: [String: [String: [String: [String: Any]]]] = ["light": [:], "dark": [:]]
    for dark in [false, true] {
        let theme = dark ? "dark" : "light"
        for spec in cellSpecs {
            let store = FrameStore()
            guard let rep = renderCell(cellView(spec.id, store: store), size: spec.size, dark: dark) else { throw CocoaError(.fileWriteUnknown) }
            guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            let url = outDir.appendingPathComponent("\(spec.id)-native-\(theme).png")
            try png.write(to: url)
            print(url.path)
            for (name, probe) in measure(spec.id, frames: store.frames, rep: rep, dark: dark) { probes[theme]?[name] = probe.props }
        }
    }
    let cells = Dictionary(uniqueKeysWithValues: cellSpecs.map { ($0.id, ["w": Double($0.size.width), "h": Double($0.size.height)]) })
    let json: [String: Any] = ["cells": cells, "probes": probes]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outDir.appendingPathComponent("native-metrics.json"))
    print("tbd-design-shots --sameness: \(cellSpecs.count) cells x 2 appearances -> \(outDir.path)")
}
