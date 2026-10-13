import AppKit
import TBDSpeech

/// Text transforms: take the selected text in any app, run it through the "general" model route
/// with a Transform from the library and paste the result over the selection. Each run is saved
/// to Transform history.
@MainActor
final class TBDTransformController {
    var onMessage: ((String) -> Void)?
    private let env: TBDListeningEnvironment
    private var running: Task<Void, Never>?

    init(env: TBDListeningEnvironment) { self.env = env }

    private var transforms: [TBDPrompt] { (try? env.database?.prompts(category: .transform)) ?? [] }

    /// Legacy single transform hotkey: runs the current Transform (last one chosen from the menu).
    func run() {
        let all = transforms
        guard let transform = all.first(where: { $0.id == env.preferences.transformPromptID }) ?? all.first(where: \.isVisible) ?? all.first else {
            onMessage?("Create a Transform on the Transforms page first.")
            return
        }
        run(transform)
    }

    /// Per-Transform hotkey.
    func run(id: String) {
        guard let transform = transforms.first(where: { $0.id == id }) else { return }
        run(transform)
    }

    /// Menu action: pick a Transform shown in the menu at the pointer, then run it.
    func chooseAndRun() {
        let menu = NSMenu(title: "Transform")
        let shown = transforms.filter(\.isVisible)
        for transform in shown {
            let item = NSMenuItem(title: transform.name, action: #selector(TBDMenuTarget.fire(_:)), keyEquivalent: "")
            item.target = TBDMenuTarget.shared
            item.representedObject = transform.id
            item.state = transform.id == env.preferences.transformPromptID ? .on : .off
            if let hotkey = transform.hotkey.flatMap({ try? TBDHotkey.parse($0) }) { item.toolTip = hotkey.displayName }
            menu.addItem(item)
        }
        if shown.isEmpty {
            let item = NSMenuItem(title: "No Transforms in the menu", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        TBDMenuTarget.shared.handler = { [weak self] id in
            guard let self, let transform = self.transforms.first(where: { $0.id == id }) else { return }
            self.env.preferences.transformPromptID = id
            self.run(transform)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func run(_ transform: TBDPrompt) {
        guard running == nil else { return }
        guard TBDPasteService.isTrusted else {
            TBDPasteService.requestTrust()
            onMessage?("Transforms need the Accessibility permission to read and replace the selection.")
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        running = Task {
            defer { running = nil }
            guard let selection = await TBDPasteService.selectedText() else {
                env.overlay.show(.message("Select some text first"))
                return
            }
            env.overlay.show(.processing(transform.derivedRunningLabel))
            do {
                let result = try await TBDPromptRunner.transform(selection, with: transform, sourceAppBundleID: app?.bundleIdentifier,
                                                                 sourceAppName: app?.localizedName, database: env.database)
                try TBDPasteService.paste(result)
                env.overlay.hide()
                env.changed()
            } catch {
                env.overlay.show(.message(error.localizedDescription))
                onMessage?(error.localizedDescription)
            }
        }
    }
}

/// Target object for AppKit menu items built in code.
@MainActor
final class TBDMenuTarget: NSObject {
    static let shared = TBDMenuTarget()
    var handler: ((String) -> Void)?
    @objc func fire(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { handler?(id) }
    }
}
