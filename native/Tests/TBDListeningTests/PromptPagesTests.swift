import XCTest
import TBDSpeech
@testable import TBDListening

/// PARITY WP3: Prompts and Transforms are Listening pages again, in the earlier rail order
/// (… Meetings, Prompts, Transforms …), and meeting Ask reads its quick prompts from the library.
final class PromptPagesTests: XCTestCase {
    func testPromptsAndTransformsFollowMeetingsInRailOrder() throws {
        let order = TBDListeningTab.allCases
        let meetings = try XCTUnwrap(order.firstIndex(of: .meetings))
        XCTAssertEqual(order.firstIndex(of: .prompts), meetings + 1)
        XCTAssertEqual(order.firstIndex(of: .transforms), meetings + 2)
        XCTAssertEqual(TBDListeningTab.prompts.title, "Prompts")
        XCTAssertEqual(TBDListeningTab.transforms.title, "Transforms")
        XCTAssertEqual(TBDListeningTab(rawValue: "prompts"), .prompts)
        XCTAssertEqual(TBDListeningTab(rawValue: "transforms"), .transforms)
    }

    func testAskQuickPromptsComeFromTheLibrary() throws {
        let suite = "tbd.tests.ask.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let db = try TBDListeningDatabase(inMemory: ())
        try db.preparePromptLibrary(preferences: TBDListeningPreferences(defaults: defaults))
        let whyID = try XCTUnwrap(db.pinnedQuickPrompts().first { $0.label == "Why?" }?.id)
        try db.setQuickPromptPinned(id: whyID, pinned: false)
        let custom = try db.saveQuickPrompt(TBDQuickPromptItem(label: "Risks?", prompt: "List risks.", isPinned: true))

        XCTAssertEqual(TBDAskPrompts.followUps(db).map(\.label), ["Tell me more", "Give an example", "Counter-argument?", "TL;DR", "Risks?"])
        XCTAssertEqual(TBDAskPrompts.followUps(db).last?.id, custom.id)
        XCTAssertEqual(TBDAskPrompts.starters(db).count, 15, "every visible quick prompt")
        // Without a library the shipped lists keep Ask working.
        XCTAssertEqual(TBDAskPrompts.followUps(nil), TBDQuickPrompt.followUps)
        XCTAssertEqual(TBDAskPrompts.starters(nil).count, 14)
    }
}
