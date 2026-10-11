import CryptoKit
import XCTest

@testable import TBD

final class TBDUpdaterTests: XCTestCase {
  private func pem(for key: Curve25519.Signing.PublicKey) -> String {
    let der = TBDUpdateVerifier.spkiPrefix + key.rawRepresentation
    return "-----BEGIN PUBLIC KEY-----\n\(der.base64EncodedString())\n-----END PUBLIC KEY-----\n"
  }

  private func release(
    _ version: String, product: String = "tbd", kind: String = "desktop",
    channel: String = "stable", minOS: String? = nil, url: String = "https://example.com/TBD.zip",
    sha: String = String(repeating: "a", count: 64)
  ) -> TBDRelease {
    TBDRelease(
      product: product, kind: kind, version: version, channel: channel,
      artifact: .init(url: url, sha256: sha), minimumOS: minOS)
  }

  private let os14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)

  // MARK: signature

  func testSignatureAcceptsValid() throws {
    let priv = Curve25519.Signing.PrivateKey()
    let body = Data(#"{"releases":[]}"#.utf8)
    let sig = Data(try priv.signature(for: body).base64EncodedString().utf8) + Data("\n".utf8)
    XCTAssertNoThrow(
      try TBDUpdateVerifier.verifyIndex(
        body: body, signature: sig, publicKeyPEM: pem(for: priv.publicKey)))
  }

  func testSignatureRejectsTamperedBody() throws {
    let priv = Curve25519.Signing.PrivateKey()
    let body = Data(#"{"releases":[]}"#.utf8)
    let sig = Data(try priv.signature(for: body).base64EncodedString().utf8)
    XCTAssertThrowsError(
      try TBDUpdateVerifier.verifyIndex(
        body: Data(#"{"releases":[1]}"#.utf8), signature: sig, publicKeyPEM: pem(for: priv.publicKey))
    ) { XCTAssertEqual($0 as? TBDUpdateError, .invalidSignature) }
  }

  func testSignatureRejectsWrongKeyAndGarbage() throws {
    let priv = Curve25519.Signing.PrivateKey()
    let other = Curve25519.Signing.PrivateKey()
    let body = Data("abc".utf8)
    let sig = Data(try priv.signature(for: body).base64EncodedString().utf8)
    XCTAssertThrowsError(
      try TBDUpdateVerifier.verifyIndex(body: body, signature: sig, publicKeyPEM: pem(for: other.publicKey)))
    XCTAssertThrowsError(
      try TBDUpdateVerifier.verifyIndex(
        body: body, signature: Data("not base64!".utf8), publicKeyPEM: pem(for: priv.publicKey)))
    XCTAssertThrowsError(
      try TBDUpdateVerifier.verifyIndex(body: body, signature: Data(), publicKeyPEM: pem(for: priv.publicKey)))
  }

  func testPinnedKeyParses() throws {
    XCTAssertNoThrow(try TBDUpdateVerifier.publicKey(fromPEM: TBDUpdater.publicKeyPEM))
    XCTAssertThrowsError(try TBDUpdateVerifier.publicKey(fromPEM: "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----"))
  }

  // MARK: selection

  func testSelectionPicksHighestMatching() {
    let list = [
      release("0.2.0"), release("0.3.0"), release("0.9.0", kind: "app"),
      release("0.8.0", product: "knowledge"), release("0.7.0", channel: "dev"),
      release("0.6.0", channel: "beta"), release("0.5.0", minOS: "15.0"),
    ]
    XCTAssertEqual(
      TBDUpdateVerifier.selectUpdate(from: list, currentVersion: "0.1.0", os: os14)?.version, "0.3.0")
    XCTAssertEqual(
      TBDUpdateVerifier.selectUpdate(
        from: list, currentVersion: "0.1.0", channels: ["stable", "beta"], os: os14)?.version, "0.6.0")
    XCTAssertEqual(
      TBDUpdateVerifier.selectUpdate(
        from: list, currentVersion: "0.1.0", os: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))?.version,
      "0.5.0")
  }

  func testSelectionIgnoresOlderEqualAndInsecure() {
    XCTAssertNil(TBDUpdateVerifier.selectUpdate(from: [release("0.3.0")], currentVersion: "0.3.0", os: os14))
    XCTAssertNil(TBDUpdateVerifier.selectUpdate(from: [release("0.2.0")], currentVersion: "0.3.0", os: os14))
    XCTAssertNil(
      TBDUpdateVerifier.selectUpdate(
        from: [release("0.4.0", url: "http://example.com/TBD.zip")], currentVersion: "0.3.0", os: os14))
    XCTAssertNil(
      TBDUpdateVerifier.selectUpdate(from: [release("0.4.0", sha: "xyz")], currentVersion: "0.3.0", os: os14))
    XCTAssertNil(TBDUpdateVerifier.selectUpdate(from: [release("0.4.0")], currentVersion: "garbage", os: os14))
  }

  func testRecordDecodingAcceptsBothSpellings() throws {
    let json = Data(
      #"""
      {"releases":[
        {"product":"tbd","kind":"desktop","version":"1.0.0","channel":"stable","minOs":"14.0","artifact":{"url":"https://x.test/a.zip","sha256":"sha256:\#(String(repeating: "b", count: 64))"}},
        {"product":"tbd","productKind":"desktop","version":"1.1.0","channel":"stable","minimumOS":"14.0","build":7,"artifact":{"url":"https://x.test/b.zip","sha256":"\#(String(repeating: "c", count: 64))"}},
        {"product":"knowledge","kind":"app","version":"0.1.0","channel":"stable","artifact":null}
      ]}
      """#.utf8)
    let index = try JSONDecoder().decode(TBDReleaseIndex.self, from: json)
    XCTAssertEqual(index.releases.count, 3)
    XCTAssertEqual(index.releases[0].minimumOS, "14.0")
    XCTAssertEqual(index.releases[1].kind, "desktop")
    XCTAssertEqual(index.releases[1].build, "7")
    XCTAssertEqual(
      TBDUpdateVerifier.selectUpdate(from: index.releases, currentVersion: "1.0.0", os: os14)?.version, "1.1.0")
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
