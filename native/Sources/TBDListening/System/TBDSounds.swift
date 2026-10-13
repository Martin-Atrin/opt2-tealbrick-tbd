import AppKit

/// The start and stop cues for dictation capture, and the completion chime (v1 `SoundManager`: no sound files were
/// bundled in v1, so it used these macOS system sounds at these volumes).
enum TBDSoundCue: CaseIterable {
    case recordStart, recordStop, complete

    var systemName: NSSound.Name {
        switch self { case .recordStart: "Tink"; case .recordStop: "Pop"; case .complete: "Glass" }
    }
    /// Capture cues play twice per take, so they sit below the once-per-file chime.
    var volume: Float { isCaptureCue ? 0.4 : 1.0 }
    /// Each take owes its own cue, so a cue still playing restarts.
    var restartsWhilePlaying: Bool { isCaptureCue }
    private var isCaptureCue: Bool { self != .complete }
}

@MainActor
final class TBDSounds {
    static let shared = TBDSounds()
    private var sounds: [TBDSoundCue: NSSound] = [:]

    /// "Play sound effects" in macOS Sound settings; on when the key is absent.
    static func systemSoundEffectsEnabled(globalDomain: [String: Any]? = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)) -> Bool {
        globalDomain?["com.apple.sound.uiaudio.enabled"] as? Bool ?? true
    }

    func play(_ cue: TBDSoundCue) {
        guard Self.systemSoundEffectsEnabled() else { return }
        // A private copy: NSSound(named:) is shared per name and volume must not leak between cues.
        let sound: NSSound
        if let cached = sounds[cue] { sound = cached }
        else {
            guard let copy = NSSound(named: cue.systemName)?.copy() as? NSSound else { return }
            copy.volume = cue.volume
            sounds[cue] = copy
            sound = copy
        }
        if sound.isPlaying {
            guard cue.restartsWhilePlaying else { return }
            sound.stop()
        }
        sound.play()
    }
}
