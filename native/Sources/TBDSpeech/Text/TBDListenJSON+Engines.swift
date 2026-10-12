import Foundation

/// JSON shapes for the engine, model, stats, vocabulary, snippet, config and delete commands of
/// `tbd-listen`. Same contract as `TBDListenJSON`: sorted keys, nil fields present as null, add
/// fields only.
extension TBDListenJSON {
    /// One engine with its capabilities (`engines list`).
    public struct Engine: Encodable, Equatable {
        public let id: String
        public let cliID: String
        public let name: String
        public let model: String
        public let summary: String
        public let languageMode: String
        public let defaultLanguage: String?
        public let languages: [String]?
        public let wordTimestamps: Bool
        public let streaming: Bool
        public let livePreview: Bool
        public let diarization: Bool
        public let meetingLivePreview: Bool
        public let approximateBytes: Int64
        public let minimumMemoryBytes: UInt64?
        public let memoryOK: Bool
        public let downloaded: Bool
        public let live: Bool
        public let final: Bool

        enum CodingKeys: String, CodingKey {
            case id, cliID, name, model, summary, languageMode, defaultLanguage, languages, wordTimestamps, streaming, livePreview,
                 diarization, meetingLivePreview, approximateBytes, minimumMemoryBytes, memoryOK, downloaded, live, final
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(cliID, forKey: .cliID); try c.encode(name, forKey: .name)
            try c.encode(model, forKey: .model); try c.encode(summary, forKey: .summary); try c.encode(languageMode, forKey: .languageMode)
            try c.encode(defaultLanguage, forKey: .defaultLanguage); try c.encode(languages, forKey: .languages)
            try c.encode(wordTimestamps, forKey: .wordTimestamps); try c.encode(streaming, forKey: .streaming)
            try c.encode(livePreview, forKey: .livePreview); try c.encode(diarization, forKey: .diarization)
            try c.encode(meetingLivePreview, forKey: .meetingLivePreview); try c.encode(approximateBytes, forKey: .approximateBytes)
            try c.encode(minimumMemoryBytes, forKey: .minimumMemoryBytes); try c.encode(memoryOK, forKey: .memoryOK)
            try c.encode(downloaded, forKey: .downloaded); try c.encode(live, forKey: .live); try c.encode(final, forKey: .final)
        }

        public init(_ capabilities: TBDEngineCapabilities, downloaded: Bool, live: Bool, final: Bool) {
            id = capabilities.kind.rawValue; cliID = capabilities.kind.cliID; name = capabilities.displayName
            model = capabilities.modelName; summary = capabilities.summary; languageMode = capabilities.languageMode.rawValue
            defaultLanguage = capabilities.defaultLanguage; languages = capabilities.languages
            wordTimestamps = capabilities.wordTimestamps; streaming = capabilities.streaming; livePreview = capabilities.livePreview
            diarization = capabilities.diarizationCompatible; meetingLivePreview = capabilities.meetingLivePreview
            approximateBytes = capabilities.approximateBytes; minimumMemoryBytes = capabilities.minimumMemoryBytes
            memoryOK = capabilities.satisfiesMemory(); self.downloaded = downloaded; self.live = live; self.final = final
        }
    }

    /// One model folder (`models list`, `models download`, `models delete`).
    public struct Model: Encodable, Equatable {
        public let id: String
        public let model: String
        public let title: String
        public let engine: String?
        public let downloaded: Bool
        public let bytes: Int64
        public let approximateBytes: Int64
        public let path: String

        enum CodingKeys: String, CodingKey { case id, model, title, engine, downloaded, bytes, approximateBytes, path }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(model, forKey: .model); try c.encode(title, forKey: .title)
            try c.encode(engine, forKey: .engine); try c.encode(downloaded, forKey: .downloaded); try c.encode(bytes, forKey: .bytes)
            try c.encode(approximateBytes, forKey: .approximateBytes); try c.encode(path, forKey: .path)
        }

        public init(_ status: TBDModelManager.Status, path: URL) {
            id = status.model.cliID; model = status.model.rawValue; title = status.model.title
            engine = status.model.engine?.rawValue; downloaded = status.downloaded; bytes = status.bytes
            approximateBytes = status.model.approximateBytes; self.path = path.path
        }
    }

    /// `models status`: routes, readiness and every model.
    public struct ModelsStatus: Encodable, Equatable {
        public let schemaVersion: Int
        public let liveEngine: String
        public let finalEngine: String
        public let liveReady: Bool
        public let finalReady: Bool
        public let vadReady: Bool
        public let speakerDetectionReady: Bool
        public let totalBytes: Int64
        public let modelsPath: String
        public let models: [Model]

        public init(liveEngine: TBDSpeechEngineKind, finalEngine: TBDSpeechEngineKind, liveReady: Bool, finalReady: Bool,
                    vadReady: Bool, speakerDetectionReady: Bool, totalBytes: Int64, modelsPath: String, models: [Model]) {
            schemaVersion = TBDListenJSON.schemaVersion
            self.liveEngine = liveEngine.rawValue; self.finalEngine = finalEngine.rawValue; self.liveReady = liveReady
            self.finalReady = finalReady; self.vadReady = vadReady; self.speakerDetectionReady = speakerDetectionReady
            self.totalBytes = totalBytes; self.modelsPath = modelsPath; self.models = models
        }
    }

    /// `stats`.
    public struct Stats: Encodable, Equatable {
        public let schemaVersion: Int
        public let dictations: Int
        public let dictationWords: Int
        public let dictationDurationMs: Int
        public let dictationsToday: Int
        public let wordsPerMinute: Int
        public let transcriptions: Int
        public let transcriptionsByKind: [String: Int]
        public let transcriptionDurationMs: Int
        public let modelsBytes: Int64
        public let storageBytes: Int64

        public init(dictation: TBDListeningDatabase.DictationStats, transcriptions: [TBDTranscription], modelsBytes: Int64, storageBytes: Int64) {
            schemaVersion = TBDListenJSON.schemaVersion
            dictations = dictation.count; dictationWords = dictation.words; dictationDurationMs = dictation.durationMs
            dictationsToday = dictation.today; wordsPerMinute = dictation.wordsPerMinute
            self.transcriptions = transcriptions.count
            transcriptionsByKind = Dictionary(uniqueKeysWithValues: TBDSourceKind.allCases.map { kind in
                (kind.rawValue, transcriptions.filter { $0.sourceKind == kind }.count)
            })
            transcriptionDurationMs = transcriptions.reduce(0) { $0 + $1.durationMs }
            self.modelsBytes = modelsBytes; self.storageBytes = storageBytes
        }
    }

    /// `vocabulary list|add|remove`.
    public struct CustomWord: Encodable, Equatable {
        public let id: String
        public let word: String
        public let replacement: String?
        public let enabled: Bool

        enum CodingKeys: String, CodingKey { case id, word, replacement, enabled }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(word, forKey: .word)
            try c.encode(replacement, forKey: .replacement); try c.encode(enabled, forKey: .enabled)
        }
        public init(_ word: TBDCustomWord) { id = word.id; self.word = word.word; replacement = word.replacement; enabled = word.isEnabled }
    }

    /// `snippets list|add|remove`.
    public struct Snippet: Encodable, Equatable {
        public let id: String
        public let trigger: String
        public let expansion: String
        public let enabled: Bool
        public let useCount: Int
        public init(_ snippet: TBDSnippet) {
            id = snippet.id; trigger = snippet.trigger; expansion = snippet.expansion; enabled = snippet.isEnabled; useCount = snippet.useCount
        }
    }

    /// `config show|get|set`: one key.
    public struct ConfigEntry: Encodable, Equatable {
        public let key: String
        public let value: TBDConfigValue
        public init(key: String, value: TBDConfigValue) { self.key = key; self.value = value }
    }

    /// `delete`.
    public struct Deleted: Encodable, Equatable {
        public let id: String
        public let kind: String
        public let deleted: Bool
        public let removedFiles: [String]
        public init(id: String, kind: String, deleted: Bool, removedFiles: [String]) {
            self.id = id; self.kind = kind; self.deleted = deleted; self.removedFiles = removedFiles
        }
    }

    /// `transcribe --podcast --resolve-only` and podcast search results.
    public struct PodcastShow: Encodable, Equatable {
        public let name: String?
        public let feedURL: String?
        public let collectionID: Int?
        enum CodingKeys: String, CodingKey { case name, feedURL, collectionID }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name); try c.encode(feedURL, forKey: .feedURL); try c.encode(collectionID, forKey: .collectionID)
        }
        public init(_ show: TBDPodcastShow) { name = show.name; feedURL = show.feedURL; collectionID = show.collectionID }
    }
}
