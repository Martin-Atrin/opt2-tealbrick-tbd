import XCTest
@testable import TBDListening

/// Small fixes from the PARITY re-check (copy that described removed or outdated behaviour).
final class SmallFixesTests: XCTestCase {
    @MainActor
    func testLinkPromptDoesNotAskForAPreinstalledYtDlp() {
        let text = TBDFileQueue.linkPromptText
        XCTAssertFalse(text.contains("already installed"))
        XCTAssertTrue(text.contains("TBD's own yt-dlp"))
    }

    /// The Companion setup screen must not promise Flow (focus sessions, nudges), which is not in this app.
    func testSetupCopyDoesNotPromiseFlow() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("companion/Dayflow/Dayflow/App/TBDCompanionSetup.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(source.contains("focus sessions"))
        XCTAssertFalse(source.contains("nudges"))
        XCTAssertTrue(source.contains("Daily recap"))
    }
}
