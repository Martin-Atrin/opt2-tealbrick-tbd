import AppKit
import Combine
import SwiftUI
import MacParakeet

@MainActor
final class StatusBarController: NSObject {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private var audioStatusTimer: Timer?
  private var cancellable: AnyCancellable?

  override init() {
    super.init()
    popover.behavior = .transient
    popover.animates = true

    if let button = statusItem.button {
      button.imageScaling = .scaleProportionallyDown
      button.imagePosition = .imageOnly

      let isRecording = AppState.shared.isRecording
      button.image = menuBarIcon(isRecording: isRecording)
      button.target = self
      button.action = #selector(togglePopover(_:))
    }

    audioStatusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateIcon(isRecording: AppState.shared.isRecording) }
    }
    // Observe recording state changes and update icon
    cancellable = AppState.shared.$isRecording
      .removeDuplicates()
      .sink { [weak self] isRecording in
        self?.updateIcon(isRecording: isRecording)
      }
  }

  private func updateIcon(isRecording: Bool) {
    let audio = TBDListeningRuntime.shared
    if audio.voiceNoteRecording || audio.meetingStatus.hasPrefix("Recording") {
      statusItem.button?.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Audio recording")
      statusItem.button?.toolTip = audio.voiceNoteRecording ? "TBD — recording voice note" : "TBD — " + audio.meetingStatus
    } else {
      statusItem.button?.image = menuBarIcon(isRecording: isRecording)
    }
  }

  private func menuBarIcon(isRecording: Bool) -> NSImage? {
    let name = "TealbrickLogo"
    guard let image = NSImage(named: name)?.copy() as? NSImage else { return nil }
    image.size = NSSize(width: 22, height: 18)
    image.isTemplate = true
    statusItem.button?.toolTip = isRecording ? "Tealbrick — recording" : "Tealbrick — paused"
    return image
  }

  @objc private func togglePopover(_ sender: Any?) {
    if popover.isShown {
      popover.performClose(sender)
    } else {
      showPopover()
    }
  }

  private func showPopover() {
    guard let button = statusItem.button else { return }
    popover.contentSize = NSSize(width: 320, height: 640)
    popover.contentViewController = NSHostingController(
      rootView: StatusMenuView(dismissMenu: { [weak self] in
        self?.popover.performClose(nil)
      })
    )
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }
}
