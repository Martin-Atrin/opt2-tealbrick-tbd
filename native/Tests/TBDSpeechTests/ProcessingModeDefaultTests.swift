import XCTest
@testable import TBDSpeech

/// C119: the processing mode matches v1 for a fresh install and never changes on upgrade.
final class ProcessingModeDefaultTests: XCTestCase {
    private func fresh() throws -> (UserDefaults, String) {
        let suite = "tbd.tests.mode.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testFreshInstallIsRawAndStoredOnce() throws {
        let (d, suite) = try fresh(); defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TBDListeningPreferences(defaults: d).processingMode, .raw)
        XCTAssertEqual(d.string(forKey: "tbd.listening.processingMode"), "raw")
    }

    func testV1UpgradeKeepsItsModeIncludingRetiredModes() throws {
        let (d, suite) = try fresh(); defer { d.removePersistentDomain(forName: suite) }
        d.set("formal", forKey: "processingMode")
        XCTAssertEqual(TBDListeningPreferences(defaults: d).processingMode, .clean)
        let (r, suite2) = try fresh(); defer { r.removePersistentDomain(forName: suite2) }
        r.set("raw", forKey: "processingMode"); r.set("parakeet", forKey: "tbd.listening.engine")
        XCTAssertEqual(TBDListeningPreferences(defaults: r).processingMode, .raw)
    }

    func testExistingOpt2InstallKeepsCleaning() throws {
        let (d, suite) = try fresh(); defer { d.removePersistentDomain(forName: suite) }
        d.set(true, forKey: "tbd.listening.practiceCompleted")
        XCTAssertEqual(TBDListeningPreferences(defaults: d).processingMode, .clean)
        XCTAssertEqual(d.string(forKey: "tbd.listening.processingMode"), "clean")
    }

    func testStoredValueWinsAndSpokenPunctuationFollowsV1() throws {
        let (d, suite) = try fresh(); defer { d.removePersistentDomain(forName: suite) }
        d.set("raw", forKey: "tbd.listening.processingMode"); d.set("clean", forKey: "processingMode")
        let prefs = TBDListeningPreferences(defaults: d)
        XCTAssertEqual(prefs.processingMode, .raw)
        XCTAssertTrue(prefs.spokenPunctuation)
        d.set(false, forKey: "spokenPunctuationEnabled")
        XCTAssertFalse(prefs.spokenPunctuation)
        prefs.spokenPunctuation = true
        XCTAssertTrue(prefs.spokenPunctuation)
    }
}
