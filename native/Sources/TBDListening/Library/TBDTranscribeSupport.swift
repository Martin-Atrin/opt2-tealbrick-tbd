import Foundation
import TBDSpeech

/// Platforms the link field names while you type (v1 `MediaPlatform`). Display only, never a gate.
enum TBDMediaPlatform: String, CaseIterable {
    case youtube, x, vimeo, facebook, tiktok, instagram, applePodcasts, soundcloud, twitch

    var displayName: String {
        switch self {
        case .youtube: "YouTube"
        case .x: "X"
        case .vimeo: "Vimeo"
        case .facebook: "Facebook"
        case .tiktok: "TikTok"
        case .instagram: "Instagram"
        case .applePodcasts: "Apple Podcasts"
        case .soundcloud: "SoundCloud"
        case .twitch: "Twitch"
        }
    }

    var isAudioFirst: Bool { self == .applePodcasts || self == .soundcloud }

    private static let hostSuffixes: [(String, TBDMediaPlatform)] = [
        ("youtube.com", .youtube), ("youtu.be", .youtube), ("youtube-nocookie.com", .youtube),
        ("x.com", .x), ("twitter.com", .x), ("vimeo.com", .vimeo), ("vimeopro.com", .vimeo),
        ("facebook.com", .facebook), ("fb.watch", .facebook), ("fb.com", .facebook),
        ("tiktok.com", .tiktok), ("instagram.com", .instagram), ("instagr.am", .instagram),
        ("podcasts.apple.com", .applePodcasts), ("podcast.apple.com", .applePodcasts),
        ("soundcloud.com", .soundcloud), ("twitch.tv", .twitch),
    ]

    /// Best effort by host suffix, so `www.`, `m.` and other subdomains match. Nil when unknown.
    static func recognize(_ text: String) -> TBDMediaPlatform? {
        guard let host = host(of: text) else { return nil }
        return hostSuffixes.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1
    }

    /// Host by hand: a stray character in the query must not hide the host.
    private static func host(of text: String) -> String? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty, !rest.contains(where: \.isWhitespace) else { return nil }
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { rest = String(rest[..<end]) }
        if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            rest = String(rest[rest.index(after: rest.startIndex)..<close])
        } else if let colon = rest.firstIndex(of: ":") { rest = String(rest[..<colon]) }
        if rest.hasSuffix(".") { rest.removeLast() }
        return rest.isEmpty ? nil : rest.lowercased()
    }
}

/// What the Transcribe page's link field holds right now.
enum TBDLinkInput: Equatable {
    case empty
    /// A link the downloader accepts; `url` is the text to queue (scheme added when the person left it out).
    case link(url: String, platform: TBDMediaPlatform?)
    /// Text that is not a link: searched in the Apple Podcasts directory.
    case podcastSearch(query: String)
    /// Looks like a link but cannot be used (wrong scheme, no host, credentials).
    case invalid

    static func classify(_ text: String) -> TBDLinkInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if !trimmed.contains("://"), let platform = TBDMediaPlatform.recognize(trimmed) {
            let url = "https://" + trimmed
            return TBDLinkDownloader.validate(url) != nil ? .link(url: url, platform: platform) : .invalid
        }
        if TBDLinkDownloader.validate(trimmed) != nil { return .link(url: trimmed, platform: TBDMediaPlatform.recognize(trimmed)) }
        return trimmed.contains("://") ? .invalid : .podcastSearch(query: trimmed)
    }

    var canSubmit: Bool {
        switch self { case .link, .podcastSearch: true; case .empty, .invalid: false }
    }

    /// The text to hand to the queue.
    var queueText: String? {
        switch self {
        case .link(let url, _): url
        case .podcastSearch(let query): query
        case .empty, .invalid: nil
        }
    }

    var title: String {
        switch self {
        case .link(_, let platform?): "Transcribe \(platform.displayName)"
        case .podcastSearch: "Find a podcast episode"
        default: "Transcribe YouTube & more"
        }
    }

    var caption: String {
        switch self {
        case .link(_, let platform?):
            "Ready to transcribe this \(platform.displayName) \(platform.isAudioFirst ? "audio" : "video"), on your Mac."
        case .link: "Ready to transcribe this link, entirely on your Mac."
        case .podcastSearch(let query): "Press Transcribe to search Apple Podcasts for “\(query)”."
        case .invalid: "Only http and https links work. Check the link."
        case .empty: "YouTube, X, Vimeo, TikTok, Instagram, Facebook, podcasts, and more, transcribed on your Mac."
        }
    }
}

/// Collects what a drop carried. v1 gathered every dropped item first and queued them once, in drop order.
enum TBDDropCollector {
    /// A file URL from a dropped item (`Data` from the pasteboard, or a `URL`). Non-file URLs give nil.
    static func decode(_ item: Any?) -> URL? {
        let url: URL?
        if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
        else if let value = item as? URL { url = value }
        else if let value = item as? NSURL { url = value as URL }
        else { url = nil }
        return url?.isFileURL == true ? url : nil
    }

    /// Every file or folder URL in `providers`, in provider order.
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        let type = "public.file-url"
        var found: [URL?] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
            let item: NSSecureCoding? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in continuation.resume(returning: item) }
            }
            found.append(decode(item))
        }
        return found.compactMap { $0 }
    }
}
