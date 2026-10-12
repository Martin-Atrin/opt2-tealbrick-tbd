import Foundation

// Podcast links and search (ported from the donor CLI). Listening's only network calls besides
// model downloads: the public iTunes Search/Lookup API (itunes.apple.com), the show's RSS feed
// and the episode audio file. Nothing is sent except the link id or the search words.

public enum TBDPodcastError: Error, LocalizedError, Equatable {
    case invalidURL
    case emptyQuery
    case requestFailed(String)
    case unexpectedResponse
    case noResults
    case episodeNotFound
    case noPlayableAudio
    case feedUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Not a valid Apple Podcasts link."
        case .emptyQuery: "Enter something to search for."
        case .requestFailed(let reason): "The podcast lookup failed: \(reason)"
        case .unexpectedResponse: "Unexpected response from Apple Podcasts."
        case .noResults: "No podcasts matched that search."
        case .episodeNotFound: "That episode could not be found on Apple Podcasts."
        case .noPlayableAudio: "No downloadable audio is published for that episode."
        case .feedUnreadable(let reason): "The podcast feed could not be read: \(reason)"
        }
    }
}

/// A resolved episode with a direct audio URL.
public struct TBDPodcastEpisode: Sendable, Equatable, Codable {
    public let audioURL: String
    public let title: String
    public let show: String?
    public let summary: String?
    public let durationSeconds: Int?
    /// yyyy-MM-dd
    public let releaseDate: String?
    public let feedURL: String?

    public init(audioURL: String, title: String, show: String? = nil, summary: String? = nil, durationSeconds: Int? = nil,
                releaseDate: String? = nil, feedURL: String? = nil) {
        self.audioURL = audioURL; self.title = title; self.show = show; self.summary = summary
        self.durationSeconds = durationSeconds; self.releaseDate = releaseDate; self.feedURL = feedURL
    }

    /// "Show — Episode" (or the episode title alone).
    public var displayTitle: String { show.map { "\($0) — \(title)" } ?? title }
}

/// A show from the directory search.
public struct TBDPodcastShow: Sendable, Equatable, Codable {
    public let name: String?
    public let feedURL: String?
    public let collectionID: Int?
    public let artworkURL: String?
}

/// Apple Podcasts link parsing (`podcasts.apple.com/…/id<show>?i=<episode>`).
public enum TBDPodcastURL {
    private static let hosts: Set<String> = ["podcasts.apple.com", "podcast.apple.com"]

    public static func isApplePodcasts(_ string: String) -> Bool { collectionID(string) != nil }

    /// The `id<digits>` show id, searched from the end so a slug like "id123-show" is not mistaken for it.
    public static func collectionID(_ string: String) -> String? {
        guard let components = components(string) else { return nil }
        for segment in components.path.split(separator: "/").reversed() {
            let lowered = segment.lowercased()
            guard lowered.hasPrefix("id") else { continue }
            let digits = lowered.dropFirst(2)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return String(digits) }
        }
        return nil
    }

    /// The `i=` episode id, or nil for a show link.
    public static func episodeID(_ string: String) -> String? {
        guard let value = components(string)?.queryItems?.first(where: { $0.name == "i" })?.value,
              !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    private static func components(_ string: String) -> URLComponents? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard let components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              let host = components.host?.lowercased(), hosts.contains(host) else { return nil }
        return components
    }
}

// MARK: - iTunes API

struct TBDItunesResponse: Decodable {
    let resultCount: Int
    let results: [TBDItunesResult]
}

struct TBDItunesResult: Decodable {
    let wrapperType: String?
    let kind: String?
    let trackName: String?
    let collectionName: String?
    let trackId: Int?
    let collectionId: Int?
    let feedUrl: String?
    let episodeUrl: String?
    let artworkUrl600: String?
    let artworkUrl100: String?
    let description: String?
    let shortDescription: String?
    let releaseDate: String?
    let trackTimeMillis: Int?
}

/// Resolves Apple Podcasts links and free-text searches to episodes. The fetcher is injectable
/// so tests run on fixtures without the network.
public struct TBDPodcastResolver: Sendable {
    public typealias Fetcher = @Sendable (URL) async throws -> Data

    static let searchBase = "https://itunes.apple.com/search"
    static let lookupBase = "https://itunes.apple.com/lookup"
    private let fetch: Fetcher

    public init(fetcher: Fetcher? = nil) {
        fetch = fetcher ?? { url in
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("TBD-Listening/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw TBDPodcastError.requestFailed("HTTP \(http.statusCode)")
            }
            return data
        }
    }

    private func get(_ url: URL) async throws -> Data {
        do { return try await fetch(url) } catch let error as TBDPodcastError { throw error } catch is CancellationError {
            throw CancellationError()
        } catch { throw TBDPodcastError.requestFailed(error.localizedDescription) }
    }

    private func decode(_ data: Data) throws -> TBDItunesResponse {
        guard let response = try? JSONDecoder().decode(TBDItunesResponse.self, from: data) else { throw TBDPodcastError.unexpectedResponse }
        return response
    }

    // MARK: Links

    static func lookupURL(collectionID: String, episodeID: String?) -> URL {
        var components = URLComponents(string: lookupBase)!
        // A show lookup returns the show plus recent episodes (newest first). Episode ids are
        // not looked up directly; the show's rows are filtered by trackId.
        components.queryItems = [URLQueryItem(name: "id", value: collectionID), URLQueryItem(name: "entity", value: "podcastEpisode"),
                                 URLQueryItem(name: "limit", value: episodeID == nil ? "2" : "200")]
        return components.url!
    }

    /// The episode an Apple Podcasts link names, or the newest episode for a show link.
    public func resolve(url: String) async throws -> TBDPodcastEpisode {
        guard let collectionID = TBDPodcastURL.collectionID(url) else { throw TBDPodcastError.invalidURL }
        let episodeID = TBDPodcastURL.episodeID(url)
        let response = try decode(try await get(Self.lookupURL(collectionID: collectionID, episodeID: episodeID)))
        guard !response.results.isEmpty else { throw TBDPodcastError.episodeNotFound }
        let episode: TBDItunesResult
        if let episodeID {
            guard let match = response.results.first(where: { $0.trackId.map(String.init) == episodeID }) else { throw TBDPodcastError.episodeNotFound }
            episode = match
        } else {
            guard let latest = response.results.first(where: { $0.episodeUrl?.isEmpty == false }) else { throw TBDPodcastError.noPlayableAudio }
            episode = latest
        }
        guard let audio = episode.episodeUrl, !audio.isEmpty else { throw TBDPodcastError.noPlayableAudio }
        return TBDPodcastEpisode(
            audioURL: audio,
            // A missing episode name reads as a placeholder rather than mislabelling it as the show.
            title: Self.firstNonEmpty(episode.trackName) ?? "Podcast episode",
            show: Self.firstNonEmpty(episode.collectionName),
            summary: Self.firstNonEmpty(episode.description, episode.shortDescription),
            durationSeconds: episode.trackTimeMillis.flatMap { $0 > 0 ? $0 / 1000 : nil },
            releaseDate: Self.isoDate(episode.releaseDate),
            feedURL: Self.firstNonEmpty(response.results.compactMap(\.feedUrl).first))
    }

    // MARK: Search

    static func searchURL(term: String, limit: Int) -> URL {
        var components = URLComponents(string: searchBase)!
        components.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "entity", value: "podcast"),
                                 URLQueryItem(name: "limit", value: String(max(1, min(limit, 50))))]
        return components.url!
    }

    /// Shows matching the words.
    public func searchShows(_ query: String, limit: Int = 10) async throws -> [TBDPodcastShow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw TBDPodcastError.emptyQuery }
        return try decode(try await get(Self.searchURL(term: term, limit: limit))).results.map {
            TBDPodcastShow(name: $0.collectionName, feedURL: $0.feedUrl, collectionID: $0.collectionId, artworkURL: $0.artworkUrl600 ?? $0.artworkUrl100)
        }
    }

    /// Episodes of a show, newest first, from its RSS feed.
    public func episodes(feedURL: String) async throws -> [TBDPodcastEpisode] {
        guard let url = URL(string: feedURL), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw TBDPodcastError.feedUnreadable("invalid feed URL")
        }
        return try TBDPodcastFeed.parse(try await get(url))
    }

    /// Free text such as "hard fork episode 120" or "lex fridman 400": the show words find the
    /// show, the remaining hints (numbers, words after "episode"/"ep"/"#") pick the episode;
    /// without hints, the newest episode.
    public func resolve(query: String) async throws -> TBDPodcastEpisode {
        let (showQuery, hints) = TBDPodcastMatcher.parse(query)
        let shows = try await searchShows(showQuery.isEmpty ? query : showQuery)
        guard let show = shows.first(where: { $0.feedURL?.isEmpty == false }), let feed = show.feedURL else { throw TBDPodcastError.noResults }
        let episodes = try await episodes(feedURL: feed)
        guard let episode = TBDPodcastMatcher.select(episodes, hints: hints) else { throw TBDPodcastError.noPlayableAudio }
        return TBDPodcastEpisode(audioURL: episode.audioURL, title: episode.title, show: show.name ?? episode.show, summary: episode.summary,
                                 durationSeconds: episode.durationSeconds, releaseDate: episode.releaseDate, feedURL: feed)
    }

    // MARK: Helpers

    static func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    /// "2026-05-01T07:00:00Z" → "2026-05-01".
    static func isoDate(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 10 else { return nil }
        let day = Array(raw.prefix(10))
        return day[4] == "-" && day[7] == "-" ? String(day) : nil
    }
}

// MARK: - RSS

/// RSS feed parsing: one episode per `<item>` with an audio enclosure.
public enum TBDPodcastFeed {
    static let audioExtensions = [".mp3", ".m4a", ".mp4", ".ogg", ".opus", ".aac", ".wav", ".flac", ".wma", ".webm"]

    static func isAudioURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("/audio") || audioExtensions.contains { lower.contains($0) }
    }

    /// "1:02:03", "62:03", "3723" → seconds.
    static func duration(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.contains(":") {
            let parts = raw.split(separator: ":").map { Int($0) }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            let values = parts.compactMap { $0 }
            let seconds = switch values.count {
            case 3: values[0] * 3600 + values[1] * 60 + values[2]
            case 2: values[0] * 60 + values[1]
            case 1: values[0]
            default: 0
            }
            return seconds > 0 ? seconds : nil
        }
        return Int(raw).flatMap { $0 > 0 ? $0 : nil }
    }

    static let pubDateFormats = ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss z", "EEE, d MMM yyyy HH:mm Z",
                                 "EEE, d MMM yyyy HH:mm z", "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss z"]

    /// RFC 822 pubDate → yyyy-MM-dd (UTC).
    static func isoDate(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.timeZone = TimeZone(secondsFromGMT: 0)
        for format in pubDateFormats {
            input.dateFormat = format
            if let date = input.date(from: raw) {
                let output = DateFormatter()
                output.locale = Locale(identifier: "en_US_POSIX")
                output.timeZone = TimeZone(identifier: "UTC")
                output.dateFormat = "yyyy-MM-dd"
                return output.string(from: date)
            }
        }
        return nil
    }

    public static func parse(_ data: Data) throws -> [TBDPodcastEpisode] {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { throw TBDPodcastError.feedUnreadable(parser.parserError?.localizedDescription ?? "malformed XML") }
        return delegate.episodes
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var episodes: [TBDPodcastEpisode] = []
        private var channelTitle = ""
        private var inItem = false
        private var inChannelTitle = false
        // A stack keeps text of fields with nested tags (`<description>a <b>b</b></description>`).
        private var stack: [String] = []
        private var title = "", summary = "", itunesSummary = "", duration = "", pubDate = ""
        private var enclosure: String?
        private var enclosureIsAudio = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            let element = name.lowercased()
            if element == "item" {
                inItem = true
                stack = []
                title = ""; summary = ""; itunesSummary = ""; duration = ""; pubDate = ""
                enclosure = nil; enclosureIsAudio = false
                return
            }
            guard inItem else {
                if element == "title", channelTitle.isEmpty { inChannelTitle = true }
                return
            }
            stack.append(element)
            if element == "enclosure", let url = attributes["url"] ?? attributes["URL"], !url.isEmpty {
                let type = (attributes["type"] ?? "").lowercased()
                if type.hasPrefix("audio") || TBDPodcastFeed.isAudioURL(url) {
                    enclosure = url
                    enclosureIsAudio = true
                } else if enclosure == nil {
                    enclosure = url   // weak fallback
                }
            }
        }

        private func append(_ text: String) {
            if inChannelTitle { channelTitle += text; return }
            guard inItem else { return }
            if stack.contains("title") { title += text }
            else if stack.contains("description") { summary += text }
            else if stack.contains("itunes:summary") || stack.contains("summary") { itunesSummary += text }
            else if stack.contains("itunes:duration") || stack.contains("duration") { duration += text }
            else if stack.contains("pubdate") { pubDate += text }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            if let text = String(data: block, encoding: .utf8) { append(text) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let element = name.lowercased()
            if inChannelTitle, element == "title" { inChannelTitle = false; return }
            guard element == "item" else {
                if inItem, stack.last == element { stack.removeLast() }
                else if inItem, let index = stack.lastIndex(of: element) { stack.remove(at: index) }
                return
            }
            inItem = false
            guard let audio = enclosure, enclosureIsAudio || TBDPodcastFeed.isAudioURL(audio) else { return }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            episodes.append(TBDPodcastEpisode(
                audioURL: audio.trimmingCharacters(in: .whitespacesAndNewlines),
                title: cleanTitle.isEmpty ? "Untitled" : cleanTitle,
                show: TBDPodcastResolver.firstNonEmpty(channelTitle),
                summary: TBDPodcastResolver.firstNonEmpty(summary, itunesSummary),
                durationSeconds: TBDPodcastFeed.duration(duration),
                releaseDate: TBDPodcastFeed.isoDate(pubDate)))
        }
    }
}

// MARK: - Episode matching

/// Splits free text into show words and episode hints and picks the episode (donor heuristics).
public enum TBDPodcastMatcher {
    static let episodeMarkers = ["episode", "ep", "ep.", "#"]

    public static func parse(_ query: String) -> (show: String, hints: [String]) {
        let words = query.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        var showWords: [String] = []
        var hints: [String] = []
        var inEpisode = false
        for word in words {
            let clean = word.trimmingCharacters(in: .punctuationCharacters)
            let lower = clean.lowercased()
            if episodeMarkers.contains(where: { lower == $0 || lower.hasPrefix($0) }) {
                inEpisode = true
                let digits = lower.filter(\.isNumber)
                if !digits.isEmpty { hints.append(digits) }
                continue
            }
            if !clean.isEmpty, clean.allSatisfy(\.isNumber) {
                hints.append(clean)
                inEpisode = true
                continue
            }
            if inEpisode {
                if !clean.isEmpty { hints.append(clean) }
            } else {
                showWords.append(clean.isEmpty ? word : clean)
            }
        }
        if showWords.isEmpty, !words.isEmpty {
            let split = min(3, words.count)
            showWords = Array(words[..<split])
            if words.count > split { hints = Array(words[split...]) }
        }
        return (showWords.joined(separator: " "), hints)
    }

    /// Best title match for the hints (an episode number scores 10, a word 1); newest when no hints or no match.
    public static func select(_ episodes: [TBDPodcastEpisode], hints: [String]) -> TBDPodcastEpisode? {
        guard !episodes.isEmpty else { return nil }
        guard !hints.isEmpty else { return episodes.first }
        var best: (episode: TBDPodcastEpisode, score: Int)?
        for episode in episodes {
            let title = episode.title.lowercased()
            var score = 0
            for hint in hints {
                let lower = hint.lowercased()
                if !hint.isEmpty, hint.allSatisfy(\.isNumber) {
                    if title.contains(" \(lower)") || title.contains(":\(lower)") || title.contains("#\(lower)")
                        || title.hasPrefix("ep \(lower)") || title.hasPrefix("ep\(lower)") || title.hasPrefix("episode \(lower)") || title.hasPrefix(lower + " ") {
                        score += 10
                    }
                } else if title.contains(lower) {
                    score += 1
                }
            }
            if score > 0, score > (best?.score ?? 0) { best = (episode, score) }
        }
        return best?.episode ?? episodes.first
    }
}
