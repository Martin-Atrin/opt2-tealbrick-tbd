import XCTest
@testable import TBDSpeech

final class TBDSpeechTests: XCTestCase {
    func testVersion() { XCTAssertFalse(TBDSpeech.version.isEmpty) }
}
