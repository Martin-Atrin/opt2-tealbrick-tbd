import XCTest
@testable import TBDSpeech

final class EngineRegistryTests: XCTestCase {
    private func scratchDefaults() -> UserDefaults {
        let name = "tbd.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testEveryEngineHasACapabilityRow() {
        XCTAssertEqual(TBDEngineCapabilities.all.count, TBDSpeechEngineKind.allCases.count)
        for kind in TBDSpeechEngineKind.allCases {
            XCTAssertEqual(kind.capabilities.kind, kind)
            XCTAssertFalse(kind.capabilities.displayName.isEmpty)
            XCTAssertGreaterThan(kind.capabilities.approximateBytes, 0)
        }
    }

    func testStoredRawValuesStayStable() {
        // Preferences and transcripts store these; renaming them would orphan user data.
        XCTAssertEqual(TBDSpeechEngineKind(rawValue: "parakeetV3"), .parakeetV3)
        XCTAssertEqual(TBDSpeechEngineKind(rawValue: "parakeetV2"), .parakeetV2)
        XCTAssertEqual(TBDSpeechEngineKind(rawValue: "whisper"), .whisper)
    }

    func testCapabilityFlags() {
        let cohere = TBDSpeechEngineKind.cohere.capabilities
        XCTAssertFalse(cohere.wordTimestamps, "Cohere is plain text")
        XCTAssertFalse(cohere.diarizationCompatible)
        XCTAssertFalse(cohere.meetingLivePreview)
        XCTAssertFalse(cohere.livePreview)
        XCTAssertEqual(cohere.languages?.count, 14)
        XCTAssertEqual(cohere.defaultLanguage, "en")
        XCTAssertFalse(cohere.satisfiesMemory(physicalMemory: 8 << 30))
        XCTAssertTrue(cohere.satisfiesMemory(physicalMemory: 32 << 30))

        for kind in [TBDSpeechEngineKind.nemotronMultilingual, .nemotronEnglish, .parakeetUnified] {
            XCTAssertTrue(kind.capabilities.streaming, "\(kind) streams")
            XCTAssertTrue(kind.capabilities.wordTimestamps)
        }
        XCTAssertTrue(TBDSpeechEngineKind.parakeetV3.capabilities.tailPreview)
        XCTAssertFalse(TBDSpeechEngineKind.parakeetV3.capabilities.streaming)
        XCTAssertFalse(TBDSpeechEngineKind.whisper.capabilities.livePreview)
        XCTAssertEqual(TBDSpeechEngineKind.parakeetV3.capabilities.languages?.count, 25)
        XCTAssertTrue(TBDSpeechEngineKind.parakeetV2.capabilities.englishOnly)
        XCTAssertTrue(TBDSpeechEngineKind.nemotronEnglish.capabilities.englishOnly)
        XCTAssertFalse(TBDSpeechEngineKind.nemotronMultilingual.capabilities.englishOnly)
        for kind in TBDSpeechEngineKind.allCases where kind != .cohere {
            XCTAssertTrue(kind.capabilities.diarizationCompatible, "\(kind) has word timestamps")
        }
    }

    func testEffectiveLanguage() {
        XCTAssertNil(TBDSpeechEngineKind.parakeetV3.capabilities.effectiveLanguage("de"), "automatic detection")
        XCTAssertEqual(TBDSpeechEngineKind.parakeetV2.capabilities.effectiveLanguage("de"), "en", "fixed")
        XCTAssertEqual(TBDSpeechEngineKind.cohere.capabilities.effectiveLanguage(nil), "en")
        XCTAssertEqual(TBDSpeechEngineKind.cohere.capabilities.effectiveLanguage("ko"), "ko")
        XCTAssertEqual(TBDSpeechEngineKind.cohere.capabilities.effectiveLanguage("sv"), "en", "unsupported falls back")
        XCTAssertNil(TBDSpeechEngineKind.whisper.capabilities.effectiveLanguage(nil))
        XCTAssertEqual(TBDSpeechEngineKind.whisper.capabilities.effectiveLanguage("ko"), "ko")
    }

    func testIdentifiers() {
        for kind in TBDSpeechEngineKind.allCases {
            XCTAssertEqual(TBDSpeechEngineKind(identifier: kind.cliID), kind)
            XCTAssertEqual(TBDSpeechEngineKind(identifier: kind.rawValue.uppercased()), kind)
        }
        XCTAssertEqual(TBDSpeechEngineKind(identifier: "nemotron"), .nemotronMultilingual)
        XCTAssertEqual(TBDSpeechEngineKind(identifier: "cohere"), .cohere)
        XCTAssertNil(TBDSpeechEngineKind(identifier: "mlx"))
        for model in TBDModelManager.Model.allCases {
            XCTAssertEqual(TBDModelManager.Model(identifier: model.cliID), model)
        }
        XCTAssertEqual(TBDModelManager.Model(identifier: "parakeet"), .parakeetV3)
    }

    func testNormalizedLanguage() {
        XCTAssertEqual(TBDListeningPreferences.normalizedLanguage("en-US"), "en")
        XCTAssertEqual(TBDListeningPreferences.normalizedLanguage(" DE_de "), "de")
        XCTAssertNil(TBDListeningPreferences.normalizedLanguage("auto"))
        XCTAssertNil(TBDListeningPreferences.normalizedLanguage(""))
        XCTAssertNil(TBDListeningPreferences.normalizedLanguage("12"))
    }

    // MARK: Live / final routing

    func testJobKindsMapToRoutes() {
        XCTAssertEqual(TBDJobKind.dictation.route, .live)
        XCTAssertEqual(TBDJobKind.meetingLive.route, .live)
        XCTAssertEqual(TBDJobKind.meetingFinal.route, .final)
        XCTAssertEqual(TBDJobKind.file.route, .final)
    }

    func testFinalRouteInheritsLiveUntilOverridden() {
        let prefs = TBDListeningPreferences(defaults: scratchDefaults())
        XCTAssertEqual(prefs.liveEngine, .parakeetV3)
        XCTAssertEqual(prefs.finalEngine, .parakeetV3)
        prefs.liveEngine = .nemotronEnglish
        XCTAssertEqual(prefs.finalEngine, .nemotronEnglish, "no override: follows live")
        prefs.finalEngineOverride = .nemotronEnglish
        prefs.liveEngine = .parakeetUnified
        XCTAssertEqual(prefs.finalEngine, .nemotronEnglish, "an explicit override equal to live stays put")
        prefs.finalEngineOverride = .cohere
        XCTAssertEqual(prefs.engine(for: .final), .cohere)
        XCTAssertEqual(prefs.engine(for: .live), .parakeetUnified)
        prefs.finalEngineOverride = nil
        XCTAssertEqual(prefs.finalEngine, .parakeetUnified)
    }

    func testSelectionCarriesTheEngineLanguage() {
        let prefs = TBDListeningPreferences(defaults: scratchDefaults())
        prefs.liveEngine = .whisper
        prefs.setLanguage("ko-KR", for: .whisper)
        prefs.finalEngineOverride = .cohere
        XCTAssertEqual(prefs.selection(for: .live), TBDEngineSelection(kind: .whisper, language: "ko"))
        XCTAssertEqual(prefs.selection(for: .final), TBDEngineSelection(kind: .cohere, language: "en"))
        prefs.setLanguage("fr", for: .cohere)
        XCTAssertEqual(prefs.selection(for: .final).language, "fr")
        prefs.setLanguage("sv", for: .cohere)
        XCTAssertNil(prefs.cohereLanguage, "unsupported Cohere language is not stored")
    }

    func testOverridingEngineSetsBothRoutesWithoutWriting() {
        let defaults = scratchDefaults()
        let prefs = TBDListeningPreferences(defaults: defaults)
        prefs.finalEngineOverride = .parakeetV2
        prefs.overridingEngine(.cohere)
        XCTAssertEqual(prefs.liveEngine, .cohere)
        XCTAssertEqual(prefs.finalEngine, .cohere)
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(prefs.finalEngine, .parakeetV2)
    }

    func testServiceKeepsOneEnginePerRoute() async {
        let prefs = TBDListeningPreferences(defaults: scratchDefaults())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-models-\(UUID().uuidString)")
        let service = TBDSpeechService(preferences: prefs, modelsRoot: root)
        prefs.liveEngine = .parakeetUnified
        prefs.finalEngineOverride = .cohere
        let live = await service.engine(for: prefs.selection(for: .live))
        let final = await service.engine(for: prefs.selection(for: .final))
        XCTAssertEqual(live.kind, .parakeetUnified)
        XCTAssertEqual(final.kind, .cohere)
        var keys = await service.residentKeys
        XCTAssertEqual(keys, ["parakeetUnified|en", "cohere|en"])
        prefs.liveEngine = .nemotronEnglish
        _ = await service.engine(for: prefs.selection(for: .live))
        keys = await service.residentKeys
        XCTAssertEqual(keys, ["nemotronEnglish|en", "cohere|en"], "the old live engine is retired")
        XCTAssertFalse(service.isReady(.live), "nothing is downloaded in an empty models folder")
        await service.shutdown()
    }

    func testMeetingPlanDropsPreviewForEnginesWithoutTimestamps() {
        let final = TBDEngineSelection(kind: .parakeetV3)
        XCTAssertNil(TBDMeetingSpeechPlan.resolve(live: TBDEngineSelection(kind: .cohere), final: final).preview)
        XCTAssertNil(TBDMeetingSpeechPlan.resolve(live: TBDEngineSelection(kind: .parakeetV2), final: final, previewEnabled: false).preview)
        let plan = TBDMeetingSpeechPlan.resolve(live: TBDEngineSelection(kind: .nemotronEnglish), final: final)
        XCTAssertEqual(plan.preview?.kind, .nemotronEnglish)
        XCTAssertEqual(plan.final.kind, .parakeetV3)
    }

    func testModelManagerReportsNothingInAnEmptyFolder() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-models-\(UUID().uuidString)")
        let manager = TBDModelManager(modelsRoot: root)
        for status in manager.status() {
            XCTAssertFalse(status.downloaded, "\(status.model)")
            XCTAssertEqual(status.bytes, 0)
        }
        XCTAssertEqual(manager.folder(.nemotronMultilingual).lastPathComponent, "nemotron-multilingual")
        XCTAssertTrue(TBDNemotronEngine.variantDirectory(language: "de", modelsRoot: root).path.hasSuffix("nemotron-multilingual/latin/1120ms"))
        XCTAssertTrue(TBDNemotronEngine.variantDirectory(language: nil, modelsRoot: root).path.hasSuffix("nemotron-multilingual/multilingual/1120ms"))
        XCTAssertTrue(manager.folder(.cohere).path.hasSuffix("cohere-transcribe/q8"))
    }

    func testCohereOverlapMerge() {
        XCTAssertEqual(TBDCohereEngine.mergeOnOverlap("the quick brown fox jumps", "brown fox jumps over the dog"),
                       "the quick brown fox jumps over the dog")
        XCTAssertEqual(TBDCohereEngine.mergeOnOverlap("hello there", "general kenobi"), "hello there general kenobi")
        XCTAssertEqual(TBDCohereEngine.mergeOnOverlap("we will meet tomor", "meet tomorrow at noon"), "we will meet tomorrow at noon",
                       "a word cut at the window edge is completed")
        XCTAssertEqual(TBDCohereEngine.mergeOnOverlap("今日は天気がいいです", "天気がいいですね"), "今日は天気がいいですね")
    }
}
