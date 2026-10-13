import XCTest
@testable import TBDListening

/// PARITY WP1: the host's Settings tabs and menu-bar rows must reach real Listening screens
/// (v1 showed "Unknown section" and "Unknown Listening action" for five of them).
final class HostWiringTests: XCTestCase {
    func testEverySectionTheHostSendsResolvesToItsOwnPage() {
        // Companion Settings sends "capture" (Capture tab) and "system" (System tab).
        XCTAssertEqual(TBDListeningSettingsSection.resolve("capture"), .capture)
        XCTAssertEqual(TBDListeningSettingsSection.resolve("system"), .system)
        XCTAssertEqual(TBDListeningSettingsSection.resolve("engine"), .engine)
        XCTAssertEqual(TBDListeningSettingsSection.resolve("ai"), .ai)
        XCTAssertEqual(TBDListeningSettingsSection.resolve("dictation"), .dictation)
        XCTAssertEqual(TBDListeningSettingsSection.resolve("meetings"), .meetings)
        for section in TBDListeningSettingsSection.allCases {
            XCTAssertEqual(TBDListeningSettingsSection.resolve(section.rawValue), section)
        }
    }

    func testAnUnknownSectionOpensCaptureNotAnEmptyPage() {
        XCTAssertEqual(TBDListeningSettingsSection.resolve("audioAI"), .capture)
        XCTAssertEqual(TBDListeningSettingsSection.resolve(""), .capture)
    }

    func testCaptureWorkflowDefaultsToDictationAndIsRemembered() throws {
        let suite = "tbd.tests.capture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TBDCaptureWorkflow.stored(defaults), .dictation)
        defaults.set("meetings", forKey: TBDCaptureWorkflow.defaultsKey)
        XCTAssertEqual(TBDCaptureWorkflow.stored(defaults), .meetings)
        defaults.set("bogus", forKey: TBDCaptureWorkflow.defaultsKey)
        XCTAssertEqual(TBDCaptureWorkflow.stored(defaults), .dictation)
        XCTAssertEqual(TBDCaptureWorkflow.allCases.map(\.title), ["Dictation", "Transcription", "Meetings"])
    }

    func testEveryMenuActionHasItsV1Effect() {
        let expected: [TBDListeningAction: TBDListeningAction.Effect] = [
            .dictation: .toggleDictation,
            .meeting: .toggleMeeting,
            .meetingPanel: .show(page: "meetings"),
            .transcribeFile: .pickFiles,
            .transcribeURL: .promptForURL,
            .history: .show(page: "dictations"),
            .openLibrary: .show(page: "library"),
            .transform: .chooseTransform,
        ]
        XCTAssertEqual(Set(expected.keys), Set(TBDListeningAction.allCases))
        for action in TBDListeningAction.allCases {
            XCTAssertEqual(action.effect, expected[action], "\(action)")
        }
    }

    func testEveryPageAnActionShowsExists() {
        for action in TBDListeningAction.allCases {
            guard case .show(let page) = action.effect else { continue }
            XCTAssertEqual(TBDListeningTab(rawValue: page)?.rawValue, page, "\(action) shows a page Listening does not have")
        }
    }
}
