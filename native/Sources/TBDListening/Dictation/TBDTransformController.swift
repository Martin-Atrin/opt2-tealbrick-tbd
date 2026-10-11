import AppKit
import TBDSpeech

/// Text transforms: take the selected text in any app, run it through the "general" model route
/// with a saved prompt and paste the result over the selection.
@MainActor
final class TBDTransformController {
    var onMessage: ((String) -> Void)?
    private let env: TBDListeningEnvironment
    private var running: Task<Void, Never>?

    init(env: TBDListeningEnvironment) { self.env = env }

    /// Hotkey: runs the current prompt.
    func run() {
        let prompts = env.preferences.transformPrompts
        guard let prompt = prompts.first(where: { $0.id == env.preferences.transformPromptID }) ?? prompts.first else { return }
        run(prompt)
    }

    /// Menu action: pick a prompt at the pointer, then run it.
    func chooseAndRun() {
        let menu = NSMenu(title: "Transform")
        for prompt in env.preferences.transformPrompts {
            let item = NSMenuItem(title: prompt.name, action: #selector(TBDMenuTarget.fire(_:)), keyEquivalent: "")
            item.target = TBDMenuTarget.shared
            item.representedObject = prompt.id
            item.state = prompt.id == env.preferences.transformPromptID ? .on : .off
            menu.addItem(item)
        }
        TBDMenuTarget.shared.handler = { [weak self] id in
            guard let self, let prompt = self.env.preferences.transformPrompts.first(where: { $0.id == id }) else { return }
            self.env.preferences.transformPromptID = id
            self.run(prompt)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func run(_ prompt: TBDTransformPrompt) {
        guard running == nil else { return }
        guard TBDPasteService.isTrusted else {
            TBDPasteService.requestTrust()
            onMessage?("Transforms need the Accessibility permission to read and replace the selection.")
            return
        }
        running = Task {
            defer { running = nil }
            guard let selection = await TBDPasteService.selectedText() else {
                env.overlay.show(.message("Select some text first"))
                return
            }
            env.overlay.show(.processing("\(prompt.name)…"))
            do {
                let result = try await TBDListeningAI.transform(selection, instruction: prompt.instruction)
                try TBDPasteService.paste(result.trimmingCharacters(in: .whitespacesAndNewlines))
                env.overlay.hide()
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
