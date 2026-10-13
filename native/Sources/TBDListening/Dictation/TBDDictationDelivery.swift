import Foundation
import TBDSpeech

/// How one dictation take is finished, set by the hotkey that started it (v1 DictationHotkeyPlan.Spec).
struct TBDDictationTakeOptions: Equatable, Sendable {
    /// AI polish hotkey: run the cleanup model even when dictation cleanup is off.
    var aiPolish = false
    /// Clipboard-only hotkey: copy the text, never paste it.
    var clipboardOnly = false
}

/// The last step of a dictation: optional cleanup, then paste or copy. Pasteboard, paste and the cleanup
/// model are seams so the clipboard-only and AI-polish rules are testable without the system.
/// v1: DictationFlowCoordinator clipboard-only branch and DictationService `aiFormatterEnabled` override.
@MainActor
struct TBDDictationDelivery {
    enum Destination: Equatable { case pasted, copied, skipped }

    struct Outcome: Equatable {
        var text: String
        var destination: Destination
        /// Cleanup fell back to the raw text.
        var cleanupWarning: String
        /// Paste failed (text stays on the clipboard).
        var error: String?
    }

    var paste: @MainActor (String) async throws -> Void
    var copy: @MainActor (String) -> Void
    var cleanup: (String) async throws -> String
    /// Last text step after cleanup (insertion style); identity unless the controller sets it.
    var finish: @MainActor (String) -> String = { $0 }

    static func live(prompt: String) -> TBDDictationDelivery {
        TBDDictationDelivery(paste: { try TBDPasteService.paste($0) }, copy: { TBDPasteService.copy($0) },
                             cleanup: TBDCleanup.modelFormatter(prompt: prompt))
    }

    /// Whether the take goes through the cleanup model.
    static func usesCleanup(_ options: TBDDictationTakeOptions, cleanupSetting: Bool) -> Bool {
        cleanupSetting || options.aiPolish
    }

    func deliver(_ text: String, options: TBDDictationTakeOptions, cleanupSetting: Bool) async throws -> Outcome {
        var result = text
        var warning = ""
        if Self.usesCleanup(options, cleanupSetting: cleanupSetting) {
            let cleaned = try await TBDCleanup.apply(raw: text, enabled: true, formatter: cleanup)
            result = cleaned.text
            warning = cleaned.warning
        }
        try Task.checkCancellation()
        result = finish(result)
        if options.clipboardOnly {
            // v1: an empty take copies nothing; otherwise the transcript replaces the clipboard and is not pasted.
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Outcome(text: result, destination: .skipped, cleanupWarning: warning)
            }
            copy(result)
            return Outcome(text: result, destination: .copied, cleanupWarning: warning)
        }
        do {
            try await paste(result)
            return Outcome(text: result, destination: .pasted, cleanupWarning: warning)
        } catch {
            return Outcome(text: result, destination: .pasted, cleanupWarning: warning, error: error.localizedDescription)
        }
    }
}
