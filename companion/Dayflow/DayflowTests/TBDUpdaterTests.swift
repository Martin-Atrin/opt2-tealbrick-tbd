import XCTest

@testable import TBD

final class TBDUpdaterTests: XCTestCase {
  private let os14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)

  // MARK: helper answer

  private func answer(
    version: String = "0.3.0", url: String = "https://example.com/TBD.zip",
    sha: String = String(repeating: "a", count: 64), minOs: String? = nil
  ) -> [String: Any] {
    var d: [String: Any] = ["version": version, "url": url, "sha256": sha, "notarized": true]
    if let minOs { d["minOs"] = minOs }
    return d
  }

  func testNullMeansUpToDate() throws {
    XCTAssertNil(try TBDUpdateOffer.parse(NSNull(), currentVersion: "0.1.0", os: os14))
  }

  func testValidAnswerBecomesOffer() throws {
    let offer = try XCTUnwrap(
      try TBDUpdateOffer.parse(answer(minOs: "14.0"), currentVersion: "0.1.0", os: os14))
    XCTAssertEqual(offer.version, "0.3.0")
    XCTAssertEqual(offer.notarized, true)
  }

  func testAnswerIgnoredWhenNotNewerOrOSTooOld() throws {
    XCTAssertNil(try TBDUpdateOffer.parse(answer(version: "0.3.0"), currentVersion: "0.3.0", os: os14))
    XCTAssertNil(try TBDUpdateOffer.parse(answer(version: "0.2.0"), currentVersion: "0.3.0", os: os14))
    XCTAssertNil(try TBDUpdateOffer.parse(answer(minOs: "15.0"), currentVersion: "0.1.0", os: os14))
  }

  func testAnswerRefusedWhenUnsafeOrMalformed() {
    let bad: [Any] = [
      answer(url: "http://example.com/TBD.zip"),
      answer(sha: "xyz"),
      answer(version: "garbage"),
      answer(minOs: "fourteen"),
      ["version": "1.0.0"],
      "text",
    ]
    for value in bad {
      XCTAssertThrowsError(try TBDUpdateOffer.parse(value, currentVersion: "0.1.0", os: os14)) {
        XCTAssertEqual($0 as? TBDUpdateError, .malformedAnswer)
      }
    }
  }

  func testShaPrefixIsNormalised() throws {
    let hex = String(repeating: "B", count: 64)
    let offer = try XCTUnwrap(
      try TBDUpdateOffer.parse(answer(sha: "sha256:" + hex), currentVersion: "0.1.0", os: os14))
    XCTAssertEqual(offer.sha256, hex.lowercased())
  }

  // MARK: semver

  func testSemverOrdering() throws {
    func v(_ s: String) throws -> TBDSemver { try XCTUnwrap(TBDSemver(s)) }
    XCTAssertTrue(try v("1.2.3") < v("1.10.0"))
    XCTAssertTrue(try v("1.0.0-alpha") < v("1.0.0"))
    XCTAssertTrue(try v("1.0.0-alpha") < v("1.0.0-alpha.1"))
    XCTAssertTrue(try v("1.0.0-alpha.1") < v("1.0.0-alpha.beta"))
    XCTAssertTrue(try v("1.0.0-alpha.beta") < v("1.0.0-beta"))
    XCTAssertTrue(try v("1.0.0-beta.2") < v("1.0.0-beta.11"))
    XCTAssertTrue(try v("1.0.0-rc.1") < v("1.0.0"))
    XCTAssertEqual(try v("1.0.0+build5"), try v("1.0.0"))
    XCTAssertEqual(try v("v2.1"), try v("2.1.0"))
    XCTAssertNil(TBDSemver("1.x.0"))
    XCTAssertNil(TBDSemver("1.0.0-"))
    XCTAssertNil(TBDSemver(""))
  }

  // MARK: sha256 and requirement

  func testSHA256MismatchRefused() throws {
    let data = Data("hello".utf8)
    let good = TBDUpdateVerifier.sha256Hex(data)
    XCTAssertEqual(good, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    XCTAssertNoThrow(try TBDUpdateVerifier.verifySHA256(data: data, expected: good))
    XCTAssertNoThrow(try TBDUpdateVerifier.verifySHA256(data: data, expected: "sha256:" + good.uppercased()))
    XCTAssertThrowsError(try TBDUpdateVerifier.verifySHA256(data: Data("hellp".utf8), expected: good)) {
      XCTAssertEqual($0 as? TBDUpdateError, .digestMismatch)
    }
    XCTAssertThrowsError(try TBDUpdateVerifier.verifySHA256(data: data, expected: ""))
    XCTAssertThrowsError(try TBDUpdateVerifier.verifySHA256(data: data, expected: "abc"))
  }

  func testRequirementOnlyForWellFormedTeamID() {
    XCTAssertNotNil(TBDUpdateVerifier.requirement(teamID: "ABCDE12345"))
    XCTAssertNil(TBDUpdateVerifier.requirement(teamID: "ABC\" or true"))
    XCTAssertNil(TBDUpdateVerifier.requirement(teamID: ""))
  }
}
