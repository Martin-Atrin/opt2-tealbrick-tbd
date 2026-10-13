import XCTest
@testable import TBDModels

/// C137: which model Daily uses when the person has or has not chosen one.
final class TBDDailyRecapChoiceTests: XCTestCase {
    func testFreshInstallWithAgentRouteUsesAgent() {
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: nil, chosen: false, agentRouteReady: true), .provider("agent"))
    }

    func testFreshInstallWithoutAgentRouteNeedsChoice() {
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: nil, chosen: false, agentRouteReady: false), .needsChoice)
    }

    func testExplicitNoneStaysNoneEvenWithAgentRoute() {
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: "none", chosen: true, agentRouteReady: true), .provider("none"))
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: "none", chosen: true, agentRouteReady: false), .provider("none"))
    }

    func testExplicitGeminiStaysGemini() {
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: "gemini", chosen: true, agentRouteReady: true), .provider("gemini"))
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: "gemini", chosen: true, agentRouteReady: false), .provider("gemini"))
    }

    func testStoredNonNoneWithoutMarkerCountsAsChosen() {
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: "claude", chosen: false, agentRouteReady: true), .provider("claude"))
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: "local", chosen: false, agentRouteReady: false), .provider("local"))
    }

    func testStoredNoneWithoutMarkerIsNotChosen() {
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: "none", chosen: false, agentRouteReady: true), .provider("agent"))
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: "none", chosen: false, agentRouteReady: false), .needsChoice)
    }

    func testExplicitAgentChoiceStaysAgentEvenWhenRouteIsNotReady() {
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: "agent", chosen: true, agentRouteReady: false), .provider("agent"))
    }

    func testEmptyStoredValueIsNoChoice() {
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: "", chosen: false, agentRouteReady: true), .provider("agent"))
        XCTAssertEqual(TBDDailyRecapChoice.resolve(storedRaw: "", chosen: true, agentRouteReady: false), .needsChoice)
    }

    func testAgentRouteIsNotReadWhenTheChoiceIsAlreadyExplicit() {
        var reads = 0
        _ = TBDDailyRecapChoice.resolve(storedRaw: "gemini", chosen: true, agentRouteReady: { reads += 1; return true }())
        XCTAssertEqual(reads, 0)
        _ = TBDDailyRecapChoice.resolve(storedRaw: nil, chosen: false, agentRouteReady: { reads += 1; return true }())
        XCTAssertEqual(reads, 1)
    }
}
