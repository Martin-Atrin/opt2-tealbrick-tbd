import XCTest
@testable import TBDSpeech

/// Podcast link resolution, search and RSS parsing on canned responses. No network.
final class PodcastTests: XCTestCase {
    static let lookupJSON = """
    {"resultCount":3,"results":[
      {"wrapperType":"track","kind":"podcast","collectionId":1528594034,"collectionName":"Hard Fork","feedUrl":"https://feeds.example.com/hardfork.xml"},
      {"wrapperType":"podcastEpisode","kind":"podcast-episode","collectionName":"Hard Fork","trackId":1000700000001,"trackName":"Episode 120: Robots","episodeUrl":"https://cdn.example.com/hf120.mp3","trackTimeMillis":3723000,"releaseDate":"2026-05-01T07:00:00Z","description":"Robots everywhere."},
      {"wrapperType":"podcastEpisode","kind":"podcast-episode","collectionName":"Hard Fork","trackId":1000700000002,"trackName":"Episode 119: Chips","episodeUrl":"https://cdn.example.com/hf119.mp3","trackTimeMillis":0,"releaseDate":"bad"}
    ]}
    """

    static let searchJSON = """
    {"resultCount":2,"results":[
      {"wrapperType":"track","kind":"podcast","collectionId":1,"collectionName":"No Feed Show"},
      {"wrapperType":"track","kind":"podcast","collectionId":1528594034,"collectionName":"Hard Fork","feedUrl":"https://feeds.example.com/hardfork.xml","artworkUrl600":"https://img.example.com/a.jpg"}
    ]}
    """

    static let feedXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
    <channel>
      <title>Hard Fork</title>
      <item>
        <title><![CDATA[Episode 121: The Big One]]></title>
        <description>Show notes with <a href="x">a link</a> inside.</description>
        <itunes:duration>1:02:03</itunes:duration>
        <pubDate>Fri, 08 May 2026 07:00:00 GMT</pubDate>
        <enclosure url="https://cdn.example.com/hf121.mp3" type="audio/mpeg" length="1"/>
      </item>
      <item>
        <title>Episode 120: Robots</title>
        <itunes:summary>Robots everywhere.</itunes:summary>
        <itunes:duration>3723</itunes:duration>
        <pubDate>Fri, 01 May 2026 07:00:00 +0000</pubDate>
        <enclosure url="https://cdn.example.com/hf120.m4a?token=1" type="" length="1"/>
      </item>
      <item>
        <title>Trailer video</title>
        <enclosure url="https://cdn.example.com/trailer.mov" type="video/quicktime" length="1"/>
      </item>
    </channel>
    </rss>
    """

    /// Fetcher that serves canned bodies by URL prefix and records what was requested.
    final class Fixtures: @unchecked Sendable {
        let lock = NSLock()
        var requested: [URL] = []
        func fetcher() -> TBDPodcastResolver.Fetcher {
            { url in
                self.lock.withLock { self.requested.append(url) }
                let string = url.absoluteString
                if string.hasPrefix(TBDPodcastResolver.lookupBase) { return Data(PodcastTests.lookupJSON.utf8) }
                if string.hasPrefix(TBDPodcastResolver.searchBase) { return Data(PodcastTests.searchJSON.utf8) }
                if string == "https://feeds.example.com/hardfork.xml" { return Data(PodcastTests.feedXML.utf8) }
                throw URLError(.fileDoesNotExist)
            }
        }
    }

    func testApplePodcastsLinkParsing() {
        let episode = "https://podcasts.apple.com/us/podcast/hard-fork/id1528594034?i=1000700000001"
        XCTAssertTrue(TBDPodcastURL.isApplePodcasts(episode))
        XCTAssertEqual(TBDPodcastURL.collectionID(episode), "1528594034")
        XCTAssertEqual(TBDPodcastURL.episodeID(episode), "1000700000001")
        XCTAssertEqual(TBDPodcastURL.collectionID("podcasts.apple.com/us/podcast/id99"), "99", "scheme optional")
        XCTAssertNil(TBDPodcastURL.episodeID("https://podcasts.apple.com/us/podcast/x/id1"))
        XCTAssertNil(TBDPodcastURL.collectionID("https://example.com/podcast/id123"), "other hosts are not Apple Podcasts")
        XCTAssertNil(TBDPodcastURL.collectionID("https://podcasts.apple.com/us/podcast/id12a"))
    }

    func testLookupURLs() {
        let show = TBDPodcastResolver.lookupURL(collectionID: "42", episodeID: nil).absoluteString
        XCTAssertTrue(show.contains("id=42") && show.contains("entity=podcastEpisode") && show.contains("limit=2"))
        XCTAssertTrue(TBDPodcastResolver.lookupURL(collectionID: "42", episodeID: "7").absoluteString.contains("limit=200"))
        let search = TBDPodcastResolver.searchURL(term: "hard fork", limit: 500).absoluteString
        XCTAssertTrue(search.hasPrefix("https://itunes.apple.com/search?") && search.contains("term=hard%20fork") && search.contains("limit=50"))
    }

    func testResolvesAnEpisodeLink() async throws {
        let resolver = TBDPodcastResolver(fetcher: Fixtures().fetcher())
        let episode = try await resolver.resolve(url: "https://podcasts.apple.com/us/podcast/hard-fork/id1528594034?i=1000700000001")
        XCTAssertEqual(episode.audioURL, "https://cdn.example.com/hf120.mp3")
        XCTAssertEqual(episode.title, "Episode 120: Robots")
        XCTAssertEqual(episode.show, "Hard Fork")
        XCTAssertEqual(episode.durationSeconds, 3723)
        XCTAssertEqual(episode.releaseDate, "2026-05-01")
        XCTAssertEqual(episode.feedURL, "https://feeds.example.com/hardfork.xml")
        XCTAssertEqual(episode.displayTitle, "Hard Fork — Episode 120: Robots")
    }

    func testShowLinkResolvesTheNewestEpisodeAndUnknownEpisodesFail() async throws {
        let resolver = TBDPodcastResolver(fetcher: Fixtures().fetcher())
        let latest = try await resolver.resolve(url: "https://podcasts.apple.com/us/podcast/hard-fork/id1528594034")
        XCTAssertEqual(latest.audioURL, "https://cdn.example.com/hf120.mp3")
        do {
            _ = try await resolver.resolve(url: "https://podcasts.apple.com/us/podcast/hard-fork/id1528594034?i=5")
            XCTFail("expected episodeNotFound")
        } catch let error as TBDPodcastError {
            XCTAssertEqual(error, .episodeNotFound)
        }
        do {
            _ = try await resolver.resolve(url: "https://example.com/x")
            XCTFail("expected invalidURL")
        } catch let error as TBDPodcastError {
            XCTAssertEqual(error, .invalidURL)
        }
    }

    func testFeedParsing() throws {
        let episodes = try TBDPodcastFeed.parse(Data(Self.feedXML.utf8))
        XCTAssertEqual(episodes.count, 2, "the video-only item is skipped")
        XCTAssertEqual(episodes[0].title, "Episode 121: The Big One", "CDATA text is kept")
        XCTAssertEqual(episodes[0].summary, "Show notes with a link inside.")
        XCTAssertEqual(episodes[0].durationSeconds, 3723)
        XCTAssertEqual(episodes[0].releaseDate, "2026-05-08")
        XCTAssertEqual(episodes[0].show, "Hard Fork")
        XCTAssertEqual(episodes[1].audioURL, "https://cdn.example.com/hf120.m4a?token=1", "audio recognised by extension when type is empty")
        XCTAssertEqual(episodes[1].summary, "Robots everywhere.")
        XCTAssertThrowsError(try TBDPodcastFeed.parse(Data("<rss><channel><item>".utf8)))
    }

    func testDurationAndDateParsing() {
        XCTAssertEqual(TBDPodcastFeed.duration("62:03"), 3723)
        XCTAssertEqual(TBDPodcastFeed.duration("45"), 45)
        XCTAssertNil(TBDPodcastFeed.duration("0"))
        XCTAssertNil(TBDPodcastFeed.duration("1:xx"))
        XCTAssertEqual(TBDPodcastFeed.isoDate("8 May 2026 07:00:00 +0000"), "2026-05-08")
        XCTAssertNil(TBDPodcastFeed.isoDate("yesterday"))
        XCTAssertEqual(TBDPodcastResolver.isoDate("2026-05-01T07:00:00Z"), "2026-05-01")
        XCTAssertNil(TBDPodcastResolver.isoDate("May 1"))
    }

    func testFreeTextParsing() {
        XCTAssertEqual(TBDPodcastMatcher.parse("hard fork episode 120").show, "hard fork")
        XCTAssertEqual(TBDPodcastMatcher.parse("hard fork episode 120").hints, ["120"])
        XCTAssertEqual(TBDPodcastMatcher.parse("lex fridman #400").hints, ["400"])
        XCTAssertEqual(TBDPodcastMatcher.parse("hard fork ep robots").hints, ["robots"])
        XCTAssertEqual(TBDPodcastMatcher.parse("the daily").hints, [])
        let numbersOnly = TBDPodcastMatcher.parse("120 121")
        XCTAssertEqual(numbersOnly.show, "120 121", "without show words the first words become the show")
    }

    func testFreeTextSearchPicksTheEpisode() async throws {
        let fixtures = Fixtures()
        let resolver = TBDPodcastResolver(fetcher: fixtures.fetcher())
        let episode = try await resolver.resolve(query: "hard fork episode 120")
        XCTAssertEqual(episode.audioURL, "https://cdn.example.com/hf120.m4a?token=1")
        XCTAssertEqual(episode.show, "Hard Fork")
        XCTAssertEqual(episode.feedURL, "https://feeds.example.com/hardfork.xml")
        let newest = try await resolver.resolve(query: "hard fork")
        XCTAssertEqual(newest.title, "Episode 121: The Big One")
        let requested = fixtures.lock.withLock { fixtures.requested.map(\.host) }
        XCTAssertTrue(requested.allSatisfy { $0 == "itunes.apple.com" || $0 == "feeds.example.com" }, "only the directory and the feed are contacted")
        let shows = try await resolver.searchShows("hard fork")
        XCTAssertEqual(shows.count, 2)
        do {
            _ = try await resolver.searchShows("  ")
            XCTFail("expected emptyQuery")
        } catch let error as TBDPodcastError {
            XCTAssertEqual(error, .emptyQuery)
        }
    }

    func testLinkDownloaderRouting() throws {
        let search = try XCTUnwrap(TBDLinkDownloader.linkOrPodcastSearch("hard fork 120"))
        XCTAssertEqual(search.scheme, TBDLinkDownloader.podcastSearchScheme)
        XCTAssertEqual(TBDLinkDownloader.podcastQuery(search), "hard fork 120")
        XCTAssertEqual(TBDLinkDownloader.linkOrPodcastSearch("https://youtu.be/x")?.host, "youtu.be")
        XCTAssertNil(TBDLinkDownloader.linkOrPodcastSearch("ftp://example.com/a.mp3"), "non-http links are refused, not searched")
        XCTAssertNil(TBDLinkDownloader.linkOrPodcastSearch("   "))
        XCTAssertTrue(TBDLinkDownloader.isDirectAudio(URL(string: "https://cdn.example.com/a.mp3")!))
        XCTAssertFalse(TBDLinkDownloader.isDirectAudio(URL(string: "https://www.youtube.com/watch?v=1")!))
        XCTAssertEqual(TBDLinkDownloader.audioExtension(for: URL(string: "https://x/y")!, mimeType: "audio/mp4"), "m4a")
        XCTAssertEqual(TBDLinkDownloader.audioExtension(for: URL(string: "https://x/y.ogg")!, mimeType: nil), "ogg")
    }
}
