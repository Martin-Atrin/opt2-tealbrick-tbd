import Foundation

/// A preference value as `tbd-listen config` prints it.
public enum TBDConfigValue: Equatable, Sendable, Encodable, CustomStringConvertible {
    case string(String)
    case bool(Bool)
    case null

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var description: String {
        switch self {
        case .string(let value): value
        case .bool(let value): value ? "true" : "false"
        case .null: "(default)"
        }
    }
}

public enum TBDConfigError: Error, LocalizedError, Equatable {
    case unknownKey(String)
    case invalidValue(key: String, value: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .unknownKey(let key): "Unknown key \(key). Keys: \(TBDListeningPreferences.configKeys.joined(separator: ", "))."
        case .invalidValue(let key, let value, let expected): "Invalid value \(value) for \(key). Expected \(expected)."
        }
    }
}

/// Read and write Listening preferences by name (`tbd-listen config`). Keys and values match
/// the Settings screen; no other preferences are reachable this way.
extension TBDListeningPreferences {
    public func configValue(_ key: String) throws -> TBDConfigValue {
        func optional(_ value: String?) -> TBDConfigValue { value.map(TBDConfigValue.string) ?? .null }
        switch key {
        case "liveEngine": return .string(liveEngine.rawValue)
        case "finalEngine": return optional(finalEngineOverride?.rawValue)
        case "whisperLanguage": return optional(whisperLanguage)
        case "nemotronLanguage": return optional(nemotronLanguage)
        case "cohereLanguage": return optional(cohereLanguage)
        case "dictationLivePreview": return .bool(dictationLivePreview)
        case "meetingLivePreview": return .bool(meetingLivePreview)
        case "keepAudio": return .bool(keepsAllFreshAudio)
        case "keepHistory": return .bool(keepHistory)
        case "removeFillers": return .bool(removeFillers)
        case "dictationCleanup": return .bool(dictationCleanup)
        case "diarize": return .bool(diarize)
        case "calendarReminders": return .bool(calendarReminders)
        case "calendarAutoStart": return .bool(calendarAutoStart)
        // `dictationHotkey` in the CLI names the v1 push-to-talk key.
        case "dictationHotkey": return .string(hotkey(for: .pushToTalk)?.serialized ?? "")
        case "transformHotkey": return optional(transformHotkey.isEmpty ? nil : transformHotkey)
        case "microphoneUID": return optional(microphoneUID)
        case "youtubeAudioQuality": return .string(youtubeAudioQuality.configValue)
        default: throw TBDConfigError.unknownKey(key)
        }
    }

    /// Every config key with its current value, in `configKeys` order.
    public func configSnapshot() -> [(key: String, value: TBDConfigValue)] {
        Self.configKeys.compactMap { key in (try? configValue(key)).map { (key, $0) } }
    }

    /// Sets a key from text. Empty, "default" or "auto" clears optional keys (for `finalEngine`:
    /// follow the live engine again).
    public func setConfig(_ key: String, to text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let clears = value.isEmpty || ["default", "auto", "none", "live"].contains(value.lowercased())
        func engine() throws -> TBDSpeechEngineKind {
            guard let kind = TBDSpeechEngineKind(identifier: value) else {
                throw TBDConfigError.invalidValue(key: key, value: text, expected: TBDSpeechEngineKind.allCases.map(\.cliID).joined(separator: ", "))
            }
            return kind
        }
        func bool() throws -> Bool {
            switch value.lowercased() {
            case "true", "on", "yes", "1": return true
            case "false", "off", "no", "0": return false
            default: throw TBDConfigError.invalidValue(key: key, value: text, expected: "true or false")
            }
        }
        func language(_ kind: TBDSpeechEngineKind) throws {
            if clears { setLanguage(nil, for: kind); return }
            guard let normalized = Self.normalizedLanguage(value) else {
                throw TBDConfigError.invalidValue(key: key, value: text, expected: "an ISO 639-1 code such as en, de or ko, or auto")
            }
            if let languages = kind.capabilities.languages, !languages.contains(normalized) {
                throw TBDConfigError.invalidValue(key: key, value: text, expected: languages.joined(separator: ", "))
            }
            setLanguage(normalized, for: kind)
        }
        switch key {
        case "liveEngine": liveEngine = try engine()
        case "finalEngine": finalEngineOverride = clears ? nil : try engine()
        case "whisperLanguage": try language(.whisper)
        case "nemotronLanguage": try language(.nemotronMultilingual)
        case "cohereLanguage": try language(.cohere)
        case "dictationLivePreview": dictationLivePreview = try bool()
        case "meetingLivePreview": meetingLivePreview = try bool()
        case "keepAudio": setKeepsAllFreshAudio(try bool())
        case "keepHistory": keepHistory = try bool()
        case "removeFillers": removeFillers = try bool()
        case "dictationCleanup": dictationCleanup = try bool()
        case "diarize": diarize = try bool()
        case "calendarReminders": calendarReminders = try bool()
        case "calendarAutoStart": calendarAutoStart = try bool()
        case "dictationHotkey":
            guard let hotkey = try? TBDHotkey.parse(value) else { throw TBDConfigError.invalidValue(key: key, value: text, expected: "a hotkey such as fn or ctrl+opt+space") }
            // One key for both: hold to talk, double-tap for hands-free (v1 shared gesture).
            setHotkey(hotkey, for: .pushToTalk); setHotkey(hotkey, for: .handsFree)
        case "transformHotkey": transformHotkey = clears ? "" : value
        case "microphoneUID": microphoneUID = clears ? nil : value
        case "youtubeAudioQuality":
            guard let quality = clears ? .m4a : TBDYtDlpAudioQuality(configValue: value) else {
                throw TBDConfigError.invalidValue(key: key, value: text, expected: "m4a or best-available")
            }
            youtubeAudioQuality = quality
        default: throw TBDConfigError.unknownKey(key)
        }
    }

    /// In-memory language override for this process only (argument domain; nothing is written).
    public func overridingLanguage(_ language: String?, for kind: TBDSpeechEngineKind) {
        let key: String
        switch kind {
        case .whisper: key = Key.whisperLanguage
        case .nemotronMultilingual: key = Key.nemotronLanguage
        case .cohere: key = Key.cohereLanguage
        default: return
        }
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[key] = Self.normalizedLanguage(language) ?? ""
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}

/// `keepAudio` in `tbd-listen config` is a view of the per-kind retention policies: true when no
/// kind removes audio after transcription. Setting it changes only "keep forever" and "remove audio
/// after transcription" policies; day-based expiry stays as the person set it.
extension TBDListeningPreferences {
    var keepsAllFreshAudio: Bool { TBDRetentionKind.allCases.allSatisfy(keepsAudio) }

    func setKeepsAllFreshAudio(_ keep: Bool) {
        var settings = retention
        for kind in TBDRetentionKind.allCases where kind.modes.contains(.deleteAudioAfterTranscription) {
            switch (keep, settings[kind].mode) {
            case (true, .deleteAudioAfterTranscription): settings[kind] = TBDRetentionPolicy(mode: .keepForever, days: settings[kind].days)
            case (false, .keepForever): settings[kind] = TBDRetentionPolicy(mode: .deleteAudioAfterTranscription, days: settings[kind].days)
            default: break
            }
        }
        retention = settings
    }
}
