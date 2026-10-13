// tbd-design-shots: renders the TBD design proof screens and the TBDDesign component sheet to PNG, light and dark.
// Usage: swift run tbd-design-shots <outDir> [prefix]   (writes <prefix>-settings-models-<theme>.png, <prefix>-components-<theme>.png)
// The views are the real TBDDesign / TBDListening views in an offscreen NSHostingView at 2x. Settings use an isolated
// UserDefaults suite and an in-memory key store, so this never reads or writes the person's settings or Keychain.
import AppKit
import SwiftUI
import TBDDesign
import TBDListening
import TBDModels

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write(Data("usage: tbd-design-shots <outDir> [prefix]\n".utf8)); exit(2) }
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let prefix = args.count >= 3 ? args[2] : "tbd"
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
TBDFonts.register()

@MainActor func render<V: View>(_ view: V, size: CGSize, dark: Bool, to name: String) throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
    rep.size = size
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        host.cacheDisplay(in: host.bounds, to: rep)
    }
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    let url = outDir.appendingPathComponent("\(name).png")
    try png.write(to: url)
    print(url.path)
}

/// An isolated registry with a stored Anthropic key, so the form opens in its "key stored" state.
func isolatedRegistry() -> TBDModelRegistry {
    let suite = "tbd.design-shots.\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let registry = TBDModelRegistry(defaults: defaults, credentials: TBDMemorySecretStore())
    _ = try? TBDAgentModelSetup.save(provider: .anthropic, endpoint: "", apiKey: "demo-key-not-real", model: TBDAgentModelSetup.defaultModel, registry: registry)
    return registry
}

/// Settings → Models as the companion lays it out (TBDModelsView): page header, page picker, the one-form setup.
struct ModelsProof: View {
    let registry: TBDModelRegistry
    @State private var page = "Tasks"
    var body: some View {
        VStack(alignment: .leading, spacing: TBDKit.s6) {
            TBDPageHeader("Models", label: "Settings")
            TBDSegmented(selection: $page, options: ["Tasks", "Connections", "Transcription", "Advanced"].map { ($0, $0) })
            Text("Choose a connection once and reuse it. No automatic fallback between providers.")
                .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
            TBDAgentModelForm(registry: registry) {}
            Spacer(minLength: 0)
        }
        .padding(TBDKit.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TBDColor.paper)
    }
}

struct Row<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .center, spacing: TBDKit.s4) {
            Text(title).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted).frame(width: 110, alignment: .leading)
            content
        }
    }
}

/// Every TBDDesign component in every state (forced like the kit's .is-hover / .is-focus specimen classes).
struct ComponentSheet: View {
    @State private var text = "claude-opus-5-5"
    @State private var empty = ""
    @State private var choice = "Anthropic"
    @State private var on = true
    @State private var off = false
    @State private var step = 1
    private let states: [(String, TBDControlState?)] = [("Default", nil), ("Hover", .hover), ("Pressed", .pressed), ("Focus", .focus)]
    var body: some View {
        HStack(alignment: .top, spacing: TBDKit.s8) {
            VStack(alignment: .leading, spacing: TBDKit.s4) {
                TBDPageHeader("TBDDesign", label: "Components")
                ForEach([("Primary", TBDButtonRole.primary), ("Secondary", .secondary), ("Quiet", .quiet), ("Destructive", .destructive), ("Confirm", .destructiveConfirm)], id: \.0) { name, role in
                    Row(title: name) {
                        ForEach(states, id: \.0) { label, state in
                            Button(label) {}.buttonStyle(TBDButtonStyle(role)).environment(\.tbdForcedState, state)
                        }
                        Button("Disabled") {}.buttonStyle(TBDButtonStyle(role)).disabled(true)
                    }
                }
                Row(title: "Icon, large") {
                    Button {} label: { Image(systemName: "plus") }.buttonStyle(TBDButtonStyle(.icon))
                    Button {} label: { Image(systemName: "mic") }.buttonStyle(TBDButtonStyle(.icon)).environment(\.tbdForcedState, .hover)
                    Button("Save and continue") {}.buttonStyle(TBDButtonStyle(.primary, size: .large))
                }
                Row(title: "Fields") {
                    TBDField("Model ID", text: $text).frame(width: 200)
                    TBDField("Hover", text: $text).frame(width: 160).environment(\.tbdForcedState, .hover)
                    TBDField("Focus", text: $empty, prompt: "Placeholder").frame(width: 160).environment(\.tbdForcedState, .focus)
                }
                Row(title: "") {
                    TBDField("Invalid", text: $empty, prompt: "https://", error: "Enter an https address.").frame(width: 200)
                    TBDField("Disabled", text: $text).frame(width: 160).disabled(true)
                    TBDSelect("Select", selection: $choice, options: [("Anthropic", "Anthropic"), ("Compatible", "Anthropic-compatible")]).frame(width: 200)
                }
                Row(title: "Tags") {
                    TBDTag("Idle"); TBDTag("Online", status: .live); TBDTag("Running", status: .busy)
                    TBDTag("Needs you", status: .needsYou); TBDTag("Not deployed", status: .open)
                    TBDCount(3); TBDCount(12, ink: true)
                }
                Row(title: "Chips") {
                    TBDFilterChip("Meetings", isOn: $on); TBDFilterChip("Dictation", isOn: $off)
                    TBDFilterChip("Hover", isOn: $off).environment(\.tbdForcedState, .hover)
                    TBDChip("Listening", color: TBDColor.teal)
                }
                Row(title: "Switch") {
                    Toggle("Clean up voice notes", isOn: $on).toggleStyle(TBDSwitchStyle()).frame(width: 240)
                    Toggle("Off", isOn: $off).toggleStyle(TBDSwitchStyle()).frame(width: 120)
                }
                Row(title: "Segmented") {
                    TBDSegmented(selection: $choice, options: [("Anthropic", "Anthropic"), ("Compatible", "Anthropic-compatible")])
                    TBDStatusPill("Recording 02:14", tone: TBDColor.brick)
                }
                Row(title: "Notices") {
                    TBDNotice("Saved. Go back to Chat.", tone: .live).frame(width: 220)
                    TBDNotice("The API key was refused.", tone: .needsYou).frame(width: 220)
                    TBDNotice("Neutral notice.").frame(width: 160)
                }
            }
            VStack(alignment: .leading, spacing: TBDKit.s4) {
                TBDKicker("StepFlow (C126, C128)")
                TBDStepFlow(steps: [
                    TBDStep("Provider") { Text("Choose a provider.").font(TBDTokens.Typography.body) },
                    TBDStep("Key", optional: true, skipLabel: "Skip, add the key later") {
                        TBDField("API key", text: $empty, prompt: "sk-ant-…", secure: true, hint: "Kept in your Keychain.")
                    },
                    TBDStep("Model", nextLabel: "Save") { Text("Pick a model.") },
                ], current: $step, size: CGSize(width: 480, height: 330)) {}
                .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
                .clipShape(TBDBrickShape())
                Text("Card").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink).frame(maxWidth: .infinity, alignment: .leading).tbdCard()
                Text("Tinted panel").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink).frame(maxWidth: .infinity, alignment: .leading).tbdPanelTint()
                Text("Floating surface").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink).padding(TBDKit.s4).tbdFloating()
            }
            .frame(width: 480)
        }
        .padding(TBDKit.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TBDColor.paper)
    }
}

MainActor.assumeIsolated {
    do {
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            try render(ModelsProof(registry: isolatedRegistry()), size: CGSize(width: 760, height: 860), dark: dark, to: "\(prefix)-settings-models-\(theme)")
            try render(ComponentSheet(), size: CGSize(width: 1560, height: 900), dark: dark, to: "\(prefix)-components-\(theme)")
        }
    } catch {
        FileHandle.standardError.write(Data("tbd-design-shots: \(error)\n".utf8)); exit(1)
    }
}
