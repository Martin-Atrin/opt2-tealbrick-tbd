import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// Press-to-record hotkey control (v1 `HotkeyRecorderView`).
/// Normal:    [ 🌐 Fn   Change...  (…) ]
/// Recording: [ Press a key or shortcut...   Cancel ]  (accent border); Esc cancels.
/// While recording, every global hotkey stands down so it cannot swallow the keys being recorded.
struct TBDHotkeyRecorderView: View {
    let value: TBDHotkey?
    let defaultHotkey: TBDHotkey?
    var displayOverride: String?
    var defaultLabelOverride: String?
    /// Conflicts with other TBD hotkeys (TBDHotkeyConflictPolicy).
    var validation: (TBDHotkey) -> TBDHotkey.Validation = { _ in .allowed }
    var onRecordingChanged: (Bool) -> Void = { _ in }
    let onChange: (TBDHotkey?) -> Void

    @State private var recorder: TBDHotkeyRecorder?
    @State private var pendingLabel: String?
    @State private var message: String?
    @State private var messageBlocks = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: TBDTokens.Space.xs) {
            if recorder != nil { recordingView } else { normalView }
            if let message {
                HStack(spacing: TBDTokens.Space.xs) {
                    Image(systemName: messageBlocks ? "xmark.circle.fill" : "exclamationmark.triangle.fill").font(.system(size: 10))
                    Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(messageBlocks ? TBDTokens.alert : TBDTokens.muted)
                .frame(maxWidth: 280, alignment: .trailing)
            }
        }
        .onDisappear { stopRecording() }
    }

    private var normalView: some View {
        HStack(spacing: TBDTokens.Space.sm) {
            Text(value.map { displayOverride ?? $0.formattedLabel } ?? "Disabled")
                .foregroundStyle(value == nil ? TBDTokens.muted : TBDTokens.ink)
            Button(value == nil ? "Set Hotkey..." : "Change...") { startRecording(.standard) }
                .buttonStyle(TBDButtonStyle(.secondary))
            Menu {
                if value != nil {
                    Button("Disable Hotkey") { message = nil; onChange(nil) }
                    Divider()
                }
                Button("Reset to Default (\(defaultLabelOverride ?? Self.resetLabel(defaultHotkey)))") { resetToDefault() }
                    .disabled(value == defaultHotkey)
                Divider()
                Button("Record Either-Side Modifier") { startRecording(.generic) }
                Button("Record Specific-Side Modifier Chord") { startRecording(.sideSpecific) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 14))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Hotkey options: disable, reset to default, or record a modifier-only shortcut.")
            .accessibilityLabel("Hotkey options")
        }
    }

    private var recordingView: some View {
        HStack(spacing: TBDTokens.Space.sm) {
            Text(pendingLabel ?? "Press a key or shortcut...")
                .foregroundStyle(pendingLabel == nil ? TBDTokens.muted : TBDTokens.ink)
            Button("Cancel") { stopRecording() }.buttonStyle(TBDButtonStyle(.secondary))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).strokeBorder(TBDTokens.accent, lineWidth: TBDTokens.Stroke.bar))
    }

    static func resetLabel(_ hotkey: TBDHotkey?) -> String {
        guard let hotkey else { return "Disabled" }
        if hotkey == .fn { return "🌐 Fn" }
        return hotkey.kind == .modifier ? hotkey.longName : hotkey.shortSymbol
    }

    private func startRecording(_ mode: TBDHotkeyRecorder.CaptureMode) {
        if monitor != nil { stopRecording() }
        recorder = TBDHotkeyRecorder(mode: mode, additionalValidation: validation)
        pendingLabel = nil
        message = nil
        messageBlocks = false
        // Stand down global hotkeys before listening, so the first keyDown reaches the recorder.
        onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard var current = recorder else { return event }
            let flags = UInt64(event.modifierFlags.rawValue)
            let isKeyDown = event.type == .keyDown
            let result = isKeyDown ? current.keyDown(keyCode: event.keyCode, flags: flags)
                                   : current.flagsChanged(keyCode: event.keyCode, flags: flags)
            recorder = current
            pendingLabel = current.pendingLabel
            apply(result)
            // Key presses are consumed; modifier changes pass through (v1).
            return isKeyDown ? nil : event
        }
    }

    private func apply(_ result: TBDHotkeyRecorder.Result) {
        switch result {
        case .recording: break
        case .accepted(let hotkey, let warning):
            message = warning; messageBlocks = false
            stopRecording()
            onChange(hotkey)
        case .blocked(let text):
            message = text; messageBlocks = true
        case .stopped(let text):
            stopRecording()
            message = text; messageBlocks = true
        case .cancelled:
            stopRecording()
        }
    }

    private func stopRecording() {
        let wasRecording = recorder != nil
        recorder = nil
        pendingLabel = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // Balanced with startRecording even if the monitor failed to attach.
        if wasRecording { onRecordingChanged(false) }
    }

    private func resetToDefault() {
        guard let defaultHotkey else { message = nil; onChange(nil); return }
        switch TBDHotkeyRecorder.combine(defaultHotkey.validation, validation(defaultHotkey)) {
        case .blocked(let text): message = text; messageBlocks = true
        case .warned(let text): message = text; messageBlocks = false; onChange(defaultHotkey)
        case .allowed: message = nil; messageBlocks = false; onChange(defaultHotkey)
        }
    }
}

/// A settings row with a hotkey recorder and the saved value's conflict message (v1 transcriptionHotkeyRow).
struct TBDHotkeyRow: View {
    let title: String
    let help: String
    let surface: TBDHotkeySurface
    let context: TBDListeningContext
    var displayOverride: String?
    var defaultLabelOverride: String?
    let onChanged: () -> Void

    var body: some View {
        let prefs = context.env.preferences
        let snapshot = prefs.hotkeySnapshot
        let value = prefs.hotkey(for: surface)
        TBDSettingsRow(title, help: help) {
            VStack(alignment: .trailing, spacing: TBDTokens.Space.xs) {
                TBDHotkeyRecorderView(
                    value: value, defaultHotkey: surface.defaultHotkey,
                    displayOverride: displayOverride, defaultLabelOverride: defaultLabelOverride,
                    validation: { TBDHotkeyConflictPolicy.validation(candidate: $0, surface: surface, snapshot: prefs.hotkeySnapshot) },
                    onRecordingChanged: { recording in
                        if recording { context.hotkeyCoordinator.suspend() } else { context.hotkeyCoordinator.resume() }
                    },
                    onChange: { hotkey in
                        prefs.setHotkey(hotkey, for: surface)
                        context.reloadHotkeys()
                        onChanged()
                    })
                if let conflict = TBDHotkeyConflictPolicy.conflictMessage(for: value, surface: surface, snapshot: snapshot) {
                    HStack(spacing: TBDTokens.Space.xs) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        Text(conflict).font(.system(size: 11))
                    }
                    .foregroundStyle(TBDTokens.alert)
                }
            }
        }
    }
}

/// v1 Capture > Transcription hotkeys (off until the person records a key).
struct TBDTranscriptionHotkeySettings: View {
    let context: TBDListeningContext
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TBDHotkeyRow(title: "File transcription hotkey", help: "Opens the file picker from anywhere on macOS.",
                         surface: .fileTranscription, context: context) { tick += 1 }
            TBDHotkeyRow(title: "Video URL transcription hotkey", help: "Opens the video URL panel from anywhere on macOS.",
                         surface: .urlTranscription, context: context) { tick += 1 }
        }
        .id(tick)
    }
}
