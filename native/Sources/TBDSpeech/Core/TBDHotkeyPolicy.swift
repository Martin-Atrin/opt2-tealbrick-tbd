import Foundation

/// The Listening hotkeys a person can set (v1 `HotkeyConflictPolicy.Surface` plus opt2's transform hotkey).
public enum TBDHotkeySurface: String, CaseIterable, Sendable {
    case handsFree, pushToTalk, meeting, fileTranscription, urlTranscription, dictationAIPolish, dictationClipboard, transform

    /// Name used in conflict messages (v1 wording).
    public var conflictName: String {
        switch self {
        case .handsFree: "hands-free mode"
        case .pushToTalk: "push to talk"
        case .meeting: "meeting recording"
        case .fileTranscription: "file transcription"
        case .urlTranscription: "video URL transcription"
        case .dictationAIPolish: "AI polish this dictation"
        case .dictationClipboard: "clipboard-only dictation"
        case .transform: "Transform"
        }
    }

    /// v1 defaults: Fn for both dictation keys (hold / double-tap), Command+Shift+M for meetings,
    /// everything else off until the person records a key.
    public var defaultHotkey: TBDHotkey? {
        switch self {
        case .handsFree, .pushToTalk: .fn
        case .meeting: TBDHotkey(modifiers: [.command, .shift], keyCode: 46)
        default: nil
        }
    }
}

/// Settings and runtime conflict rules. Ported from v1 `MacParakeetCore/Hotkey/HotkeyConflictPolicy.swift`;
/// a nil hotkey is v1's `.disabled`.
public enum TBDHotkeyConflictPolicy {
    public struct Snapshot: Equatable, Sendable {
        public var handsFree: TBDHotkey?
        public var pushToTalk: TBDHotkey?
        public var meeting: TBDHotkey?
        public var fileTranscription: TBDHotkey?
        public var urlTranscription: TBDHotkey?
        public var dictationAIPolish: TBDHotkey?
        public var dictationClipboard: TBDHotkey?
        /// Transform hotkeys by name (v1 named them "Transform <name>").
        public var transforms: [Named]
        public var meetingRecordingEnabled: Bool

        public init(handsFree: TBDHotkey?, pushToTalk: TBDHotkey?, meeting: TBDHotkey?, fileTranscription: TBDHotkey?,
                    urlTranscription: TBDHotkey?, dictationAIPolish: TBDHotkey? = nil, dictationClipboard: TBDHotkey? = nil,
                    transforms: [Named] = [], meetingRecordingEnabled: Bool = true) {
            self.handsFree = handsFree; self.pushToTalk = pushToTalk; self.meeting = meeting
            self.fileTranscription = fileTranscription; self.urlTranscription = urlTranscription
            self.dictationAIPolish = dictationAIPolish; self.dictationClipboard = dictationClipboard
            self.transforms = transforms; self.meetingRecordingEnabled = meetingRecordingEnabled
        }

        public func hotkey(for surface: TBDHotkeySurface) -> TBDHotkey? {
            switch surface {
            case .handsFree: handsFree
            case .pushToTalk: pushToTalk
            case .meeting: meeting
            case .fileTranscription: fileTranscription
            case .urlTranscription: urlTranscription
            case .dictationAIPolish: dictationAIPolish
            case .dictationClipboard: dictationClipboard
            case .transform: transforms.first?.hotkey
            }
        }
    }

    public struct Named: Equatable, Sendable {
        public let name: String
        public let hotkey: TBDHotkey?
        public let mode: TBDHotkey.ConflictMode
        public init(name: String, hotkey: TBDHotkey?, mode: TBDHotkey.ConflictMode = .exclusive) {
            self.name = name; self.hotkey = hotkey; self.mode = mode
        }
    }

    public struct Conflict: Equatable, Sendable {
        public let name: String
        public let hotkey: TBDHotkey
    }

    public static func disabledMessage(_ conflict: Conflict) -> String {
        "Disabled — conflicts with \(conflict.name) (\(conflict.hotkey.formattedLabel))."
    }

    public static func blockedMessage(_ conflict: Conflict) -> String {
        "Conflicts with \(conflict.name) (\(conflict.hotkey.formattedLabel))."
    }

    /// Recorder validation: blocks a candidate that conflicts with another TBD hotkey.
    public static func validation(candidate: TBDHotkey?, surface: TBDHotkeySurface, snapshot: Snapshot) -> TBDHotkey.Validation {
        guard let candidate else { return .allowed }
        if surface == .transform { return transformValidation(candidate: candidate, snapshot: snapshot) }
        guard let conflict = conflict(for: candidate, surface: surface, snapshot: snapshot) else { return .allowed }
        return .blocked(blockedMessage(conflict))
    }

    /// Message under a row whose saved hotkey conflicts (it is then disabled at runtime, except hands-free
    /// against push to talk, where hands-free keeps working as a tap key).
    public static func conflictMessage(for hotkey: TBDHotkey?, surface: TBDHotkeySurface, snapshot: Snapshot) -> String? {
        guard let hotkey, surface != .transform, let conflict = conflict(for: hotkey, surface: surface, snapshot: snapshot) else { return nil }
        let disables = !(surface == .handsFree && conflict.name == TBDHotkeySurface.pushToTalk.conflictName)
        return disables ? disabledMessage(conflict) : blockedMessage(conflict)
    }

    public static func conflict(for hotkey: TBDHotkey, surface: TBDHotkeySurface, snapshot s: Snapshot) -> Conflict? {
        let dictation = dictationPeers(s)
        switch surface {
        case .handsFree:
            return dictationPeerConflict(candidate: hotkey, peer: s.pushToTalk, peerName: TBDHotkeySurface.pushToTalk.conflictName)
                ?? overlapping(hotkey, s.dictationAIPolish, .dictationAIPolish)
                ?? overlapping(hotkey, s.dictationClipboard, .dictationClipboard)
                ?? firstConflict(for: hotkey, selfMode: .bareModifierDictation, among: dictation)
        case .pushToTalk:
            return dictationPeerConflict(candidate: hotkey, peer: s.handsFree, peerName: TBDHotkeySurface.handsFree.conflictName)
                ?? overlapping(hotkey, s.dictationAIPolish, .dictationAIPolish)
                ?? overlapping(hotkey, s.dictationClipboard, .dictationClipboard)
                ?? firstConflict(for: hotkey, selfMode: .bareModifierDictation, among: dictation)
        case .meeting:
            return firstConflict(for: hotkey, among: [
                Named(name: TBDHotkeySurface.handsFree.conflictName, hotkey: s.handsFree, mode: .bareModifierDictation),
                Named(name: TBDHotkeySurface.pushToTalk.conflictName, hotkey: s.pushToTalk, mode: .bareModifierDictation),
                Named(name: TBDHotkeySurface.fileTranscription.conflictName, hotkey: s.fileTranscription),
                Named(name: TBDHotkeySurface.urlTranscription.conflictName, hotkey: s.urlTranscription),
                Named(name: TBDHotkeySurface.dictationAIPolish.conflictName, hotkey: s.dictationAIPolish, mode: .bareModifierDictation),
                Named(name: TBDHotkeySurface.dictationClipboard.conflictName, hotkey: s.dictationClipboard),
            ] + s.transforms)
        case .fileTranscription:
            return firstConflict(for: hotkey, among: transcriptionPeers(other: .urlTranscription, s.urlTranscription, s))
        case .urlTranscription:
            return firstConflict(for: hotkey, among: transcriptionPeers(other: .fileTranscription, s.fileTranscription, s))
        case .dictationAIPolish:
            return overlapping(hotkey, s.handsFree, .handsFree)
                ?? overlapping(hotkey, s.pushToTalk, .pushToTalk)
                ?? overlapping(hotkey, s.dictationClipboard, .dictationClipboard)
                ?? firstConflict(for: hotkey, selfMode: .bareModifierDictation, among: dictation)
        case .dictationClipboard:
            return overlapping(hotkey, s.handsFree, .handsFree)
                ?? overlapping(hotkey, s.pushToTalk, .pushToTalk)
                ?? overlapping(hotkey, s.dictationAIPolish, .dictationAIPolish)
                ?? firstConflict(for: hotkey, among: dictation)
        case .transform:
            return firstConflict(for: hotkey, among: transformReserved(s))
        }
    }

    /// Hands-free and push to talk may share one key (hold / double-tap); any other overlap conflicts.
    public static func dictationPeerConflict(candidate: TBDHotkey, peer: TBDHotkey?, peerName: String) -> Conflict? {
        guard let peer, candidate.overlaps(with: peer) else { return nil }
        if TBDDictationHotkeyPlan.isSharedGesture(handsFree: candidate, pushToTalk: peer) { return nil }
        return Conflict(name: peerName, hotkey: peer)
    }

    private static func overlapping(_ candidate: TBDHotkey, _ peer: TBDHotkey?, _ surface: TBDHotkeySurface) -> Conflict? {
        guard let peer, candidate.overlaps(with: peer) else { return nil }
        return Conflict(name: surface.conflictName, hotkey: peer)
    }

    public static func firstConflict(for hotkey: TBDHotkey, selfMode: TBDHotkey.ConflictMode = .exclusive, among candidates: [Named]) -> Conflict? {
        for candidate in candidates {
            guard let other = candidate.hotkey else { continue }
            if hotkey.conflicts(with: other, selfMode: selfMode, otherMode: candidate.mode) {
                return Conflict(name: candidate.name, hotkey: other)
            }
        }
        return nil
    }

    /// Runtime check for immediate-action hotkeys: every peer it conflicts with, without duplicates.
    public static func conflictingHotkeys(for hotkey: TBDHotkey, among candidates: [Named]) -> [TBDHotkey] {
        var result: [TBDHotkey] = []
        for candidate in candidates {
            guard let other = candidate.hotkey, hotkey.conflicts(with: other, otherMode: candidate.mode), !result.contains(other) else { continue }
            result.append(other)
        }
        return result
    }

    /// Peers an immediate-action hotkey (meeting, file, URL) must not collide with at runtime
    /// (v1 `AppHotkeyCoordinator.setupMeetingHotkey` and siblings).
    public static func runtimePeers(of surface: TBDHotkeySurface, snapshot s: Snapshot) -> [Named] {
        var peers: [Named] = [
            Named(name: TBDHotkeySurface.handsFree.conflictName, hotkey: s.handsFree, mode: .bareModifierDictation),
            Named(name: TBDHotkeySurface.pushToTalk.conflictName, hotkey: s.pushToTalk, mode: .bareModifierDictation),
        ]
        for other in [TBDHotkeySurface.meeting, .fileTranscription, .urlTranscription] where other != surface {
            peers.append(Named(name: other.conflictName, hotkey: s.hotkey(for: other)))
        }
        peers.append(Named(name: TBDHotkeySurface.dictationAIPolish.conflictName, hotkey: s.dictationAIPolish, mode: .bareModifierDictation))
        peers.append(Named(name: TBDHotkeySurface.dictationClipboard.conflictName, hotkey: s.dictationClipboard))
        return peers
    }

    private static func dictationPeers(_ s: Snapshot) -> [Named] {
        var peers: [Named] = []
        if s.meetingRecordingEnabled { peers.append(Named(name: TBDHotkeySurface.meeting.conflictName, hotkey: s.meeting)) }
        peers.append(Named(name: TBDHotkeySurface.fileTranscription.conflictName, hotkey: s.fileTranscription))
        peers.append(Named(name: TBDHotkeySurface.urlTranscription.conflictName, hotkey: s.urlTranscription))
        return peers + s.transforms
    }

    private static func transcriptionPeers(other: TBDHotkeySurface, _ otherHotkey: TBDHotkey?, _ s: Snapshot) -> [Named] {
        var peers: [Named] = [
            Named(name: TBDHotkeySurface.handsFree.conflictName, hotkey: s.handsFree, mode: .bareModifierDictation),
            Named(name: TBDHotkeySurface.pushToTalk.conflictName, hotkey: s.pushToTalk, mode: .bareModifierDictation),
        ]
        if s.meetingRecordingEnabled { peers.append(Named(name: TBDHotkeySurface.meeting.conflictName, hotkey: s.meeting)) }
        peers.append(Named(name: other.conflictName, hotkey: otherHotkey))
        peers.append(Named(name: TBDHotkeySurface.dictationAIPolish.conflictName, hotkey: s.dictationAIPolish, mode: .bareModifierDictation))
        peers.append(Named(name: TBDHotkeySurface.dictationClipboard.conflictName, hotkey: s.dictationClipboard))
        return peers + s.transforms
    }

    /// v1 `TransformShortcutReservedHotkey` list (AppDelegate.reservedTransformHotkeys).
    private static func transformReserved(_ s: Snapshot) -> [Named] {
        var reserved: [Named] = [
            Named(name: "hands-free dictation", hotkey: s.handsFree, mode: .bareModifierDictation),
            Named(name: TBDHotkeySurface.pushToTalk.conflictName, hotkey: s.pushToTalk, mode: .bareModifierDictation),
            Named(name: TBDHotkeySurface.dictationClipboard.conflictName, hotkey: s.dictationClipboard),
            Named(name: TBDHotkeySurface.fileTranscription.conflictName, hotkey: s.fileTranscription),
            Named(name: TBDHotkeySurface.urlTranscription.conflictName, hotkey: s.urlTranscription),
            Named(name: TBDHotkeySurface.dictationAIPolish.conflictName, hotkey: s.dictationAIPolish, mode: .bareModifierDictation),
        ]
        if s.meetingRecordingEnabled { reserved.append(Named(name: TBDHotkeySurface.meeting.conflictName, hotkey: s.meeting)) }
        return reserved
    }

    /// v1 `TransformShortcutCollisionChecker`: a key with ⌃, ⌥, ⇧ or ⌘, not an Option dead key, not reserved.
    private static func transformValidation(candidate: TBDHotkey, snapshot: Snapshot) -> TBDHotkey.Validation {
        guard candidate.kind == .chord, !candidate.modifiers.subtracting([.fn]).isEmpty else {
            return .blocked("Shortcut must include a modifier key (\u{2303}, \u{2325}, \u{21E7}, or \u{2318}).")
        }
        let deadKeys: Set<UInt16> = [14, 32, 34, 45, 50]   // E, U, I, N, `
        if candidate.modifiers == [.option], let code = candidate.keyCode, deadKeys.contains(code) {
            return .blocked("This shortcut produces a special character on Mac. Pick another combo.")
        }
        if let conflict = firstConflict(for: candidate, among: transformReserved(snapshot)) {
            return .blocked("This shortcut conflicts with \(conflict.name).")
        }
        return .allowed
    }
}

/// Which dictation hotkeys run, in which gesture mode. Ported from v1 `AppHotkeyCoordinator.dictationHotkeyPlan`.
public struct TBDDictationHotkeyPlan: Equatable, Sendable {
    /// v1 `AppHotkeyCoordinator.holdToTalkStopTailMs`: keep recording this long after a push-to-talk release.
    public static let holdToTalkStopTailMs = 200

    public struct Spec: Equatable, Sendable {
        public let hotkey: TBDHotkey
        public let gestureMode: TBDHotkeyGestureController.Mode
        public let startupDebounceMs: Int
        public let holdToTalkStopTailMs: Int
        /// AI polish: run the cleanup model on this take even when dictation cleanup is off.
        public let aiPolish: Bool
        /// Copy the text to the clipboard instead of pasting it.
        public let clipboardOnly: Bool

        public init(hotkey: TBDHotkey, gestureMode: TBDHotkeyGestureController.Mode,
                    startupDebounceMs: Int = TBDFnKeyStateMachine.defaultStartupDebounceMs, holdToTalkStopTailMs: Int = 0,
                    aiPolish: Bool = false, clipboardOnly: Bool = false) {
            self.hotkey = hotkey; self.gestureMode = gestureMode; self.startupDebounceMs = startupDebounceMs
            self.holdToTalkStopTailMs = max(0, holdToTalkStopTailMs); self.aiPolish = aiPolish; self.clipboardOnly = clipboardOnly
        }
    }

    public struct Conflict: Equatable, Sendable {
        public let hotkey: TBDHotkey
        public let conflicts: [TBDHotkey]
    }

    public let specs: [Spec]
    public let conflict: Conflict?

    public static func isSharedGesture(handsFree: TBDHotkey?, pushToTalk: TBDHotkey?) -> Bool {
        handsFree != nil && handsFree == pushToTalk
    }

    public static func make(handsFree: TBDHotkey?, pushToTalk: TBDHotkey?, aiPolish: TBDHotkey? = nil, clipboard: TBDHotkey? = nil) -> TBDDictationHotkeyPlan {
        var base = TBDDictationHotkeyPlan(specs: [], conflict: nil)
        if isSharedGesture(handsFree: handsFree, pushToTalk: pushToTalk), let key = handsFree {
            base = .init(specs: [Spec(hotkey: key, gestureMode: .doubleTapAndHold, holdToTalkStopTailMs: holdToTalkStopTailMs)], conflict: nil)
        } else if let handsFree, let pushToTalk, handsFree.overlaps(with: pushToTalk) {
            base = .init(specs: [Spec(hotkey: handsFree, gestureMode: .singleTapToggle)],
                         conflict: Conflict(hotkey: pushToTalk, conflicts: [handsFree]))
        } else {
            var specs: [Spec] = []
            if let handsFree { specs.append(Spec(hotkey: handsFree, gestureMode: .singleTapToggle)) }
            if let pushToTalk {
                specs.append(Spec(hotkey: pushToTalk, gestureMode: .holdOnly,
                                  startupDebounceMs: pushToTalkStartupDebounceMs(handsFree: handsFree, pushToTalk: pushToTalk),
                                  holdToTalkStopTailMs: holdToTalkStopTailMs))
            }
            base = .init(specs: specs, conflict: nil)
        }
        let withClipboard = appending(clipboard.map { Spec(hotkey: $0, gestureMode: .singleTapToggle, clipboardOnly: true) }, to: base)
        return appending(aiPolish.map { Spec(hotkey: $0, gestureMode: .singleTapToggle, aiPolish: true) }, to: withClipboard)
    }

    private static func appending(_ spec: Spec?, to plan: TBDDictationHotkeyPlan) -> TBDDictationHotkeyPlan {
        guard let spec else { return plan }
        let conflicting = plan.specs.map(\.hotkey).filter { spec.hotkey.overlaps(with: $0) }
        guard conflicting.isEmpty else {
            return .init(specs: plan.specs, conflict: plan.conflict ?? Conflict(hotkey: spec.hotkey, conflicts: conflicting))
        }
        return .init(specs: plan.specs + [spec], conflict: plan.conflict)
    }

    /// Fn push to talk next to an Fn+key hands-free chord waits the full tap threshold before arming,
    /// so the chord does not start a provisional push-to-talk take.
    static func pushToTalkStartupDebounceMs(handsFree: TBDHotkey?, pushToTalk: TBDHotkey) -> Int {
        guard pushToTalk == .fn, let handsFree, handsFree.kind == .chord, handsFree.modifiers.contains(.fn) else {
            return TBDFnKeyStateMachine.defaultStartupDebounceMs
        }
        return TBDFnKeyStateMachine.defaultTapThresholdMs
    }

    /// v1 `shouldResumeDictationHotkey`: whether a hotkey keeps control of a take after a reload.
    public static func shouldResume(_ spec: Spec, activeMode: TBDFnKeyStateMachine.RecordingMode?, activeSpec: Spec?) -> Bool {
        guard TBDHotkeyGestureController.resumeMode(activeMode, for: spec.gestureMode) != nil else { return false }
        guard let activeSpec else {
            // Takes started outside a hotkey stay with the regular dictation keys.
            return !spec.aiPolish && !spec.clipboardOnly
        }
        return spec.aiPolish == activeSpec.aiPolish && spec.clipboardOnly == activeSpec.clipboardOnly
    }

    /// v1 `AppHotkeyCoordinator.menuTitle`.
    public static func menuTitle(handsFree: TBDHotkey?, pushToTalk: TBDHotkey?, aiPolish: TBDHotkey? = nil, clipboard: TBDHotkey? = nil) -> String {
        if handsFree == nil && pushToTalk == nil {
            if aiPolish != nil && clipboard != nil { return "Dictation: AI polish / Clipboard-only" }
            if let aiPolish { return "AI polish: Tap \(aiPolish.longName)" }
            if let clipboard { return "Clipboard-only: Tap \(clipboard.longName)" }
            return "Dictation Shortcuts: Disabled"
        }
        if isSharedGesture(handsFree: handsFree, pushToTalk: pushToTalk), let key = pushToTalk {
            return "Dictation: Hold \(key.longName) / Double-tap \(key.longName)"
        }
        if let handsFree, let pushToTalk, handsFree.overlaps(with: pushToTalk) {
            return "Dictation Shortcuts: Conflict on \(handsFree.longName) / \(pushToTalk.longName)"
        }
        guard let handsFree else { return "Push-to-talk: Hold \(pushToTalk!.longName)" }
        guard let pushToTalk else { return "Hands-free: Tap \(handsFree.longName)" }
        return "Dictation: Hold \(pushToTalk.longName) / Tap \(handsFree.longName)"
    }

    /// v1 `SettingsDictationHotkeyDisplay`: labels when both dictation rows share one key.
    public static func pushToTalkLabelOverride(pushToTalk: TBDHotkey?, handsFree: TBDHotkey?) -> String? {
        guard isSharedGesture(handsFree: handsFree, pushToTalk: pushToTalk), let key = pushToTalk, key != .fn else { return nil }
        return "Hold \(sharedGestureLabel(key))"
    }

    public static func handsFreeLabelOverride(handsFree: TBDHotkey?, pushToTalk: TBDHotkey?) -> String? {
        guard isSharedGesture(handsFree: handsFree, pushToTalk: pushToTalk), let key = handsFree else { return nil }
        return "Double-tap \(sharedGestureLabel(key))"
    }

    private static func sharedGestureLabel(_ key: TBDHotkey) -> String { key == .fn ? "Fn" : key.shortSymbol }

    // MARK: Stored values (v1 SettingsViewModel.resolveDictationHotkeyTriggers)

    /// Hands-free default that does not overlap the push-to-talk key.
    static func defaultHandsFree(avoiding pushToTalk: TBDHotkey?) -> TBDHotkey? {
        if pushToTalk == .fn { return .fn }
        guard let pushToTalk, TBDHotkey.fn.overlaps(with: pushToTalk) else { return .fn }
        return nil
    }

    /// Resolves stored dictation hotkeys. `nil` input means "never stored"; `.some(nil)` means stored as disabled.
    /// Returns the values to use and whether each must be written back.
    public static func resolveStored(handsFree storedHandsFree: TBDHotkey??, pushToTalk storedPushToTalk: TBDHotkey??)
        -> (handsFree: TBDHotkey?, pushToTalk: TBDHotkey?, persistHandsFree: Bool, persistPushToTalk: Bool) {
        let fnSpace = TBDHotkey(modifiers: [.fn], keyCode: 49)
        guard let handsFree = storedHandsFree else {
            let pushToTalk = storedPushToTalk ?? .fn
            return (defaultHandsFree(avoiding: pushToTalk), pushToTalk, true, storedPushToTalk == nil)
        }
        guard let pushToTalk = storedPushToTalk else {
            guard let handsFree else { return (nil, nil, false, true) }
            if handsFree == fnSpace { return (.fn, .fn, true, true) }
            let resolved = defaultHandsFree(avoiding: handsFree)
            return (resolved, handsFree, resolved != handsFree, true)
        }
        if handsFree == fnSpace, pushToTalk == .fn { return (.fn, .fn, true, false) }
        if let handsFree, let pushToTalk, handsFree != pushToTalk, handsFree.overlaps(with: pushToTalk) {
            return (defaultHandsFree(avoiding: pushToTalk), pushToTalk, true, false)
        }
        return (handsFree, pushToTalk, false, false)
    }
}
