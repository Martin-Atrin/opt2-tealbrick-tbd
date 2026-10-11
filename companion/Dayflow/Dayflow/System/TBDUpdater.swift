import AppKit
import CryptoKit
import Foundation
import OSLog
import Security

// MARK: - Pure logic (unit-tested)

/// Version with the semver 2.0 precedence rules (build metadata ignored).
struct TBDSemver: Comparable, Equatable {
  let core: [Int]
  let prerelease: [String]

  /// Accepts "1", "1.2", "1.2.3", "v1.2.3", "1.2.3-beta.1" and "1.2.3+build".
  init?(_ raw: String) {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
    if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
    var pre: [String] = []
    if let dash = text.firstIndex(of: "-") {
      let tail = String(text[text.index(after: dash)...])
      text = String(text[..<dash])
      pre = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
      if pre.isEmpty || pre.contains(where: { $0.isEmpty }) { return nil }
    }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return nil }
    var numbers: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else {
        return nil
      }
      numbers.append(n)
    }
    while numbers.count < 3 { numbers.append(0) }
    core = numbers
    prerelease = pre
  }

  static func < (lhs: TBDSemver, rhs: TBDSemver) -> Bool {
    if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
    switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
    case (true, true): return false
    case (true, false): return false  // release > prerelease
    case (false, true): return true
    case (false, false):
      for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
        switch (Int(a), Int(b)) {
        case let (x?, y?): return x < y
        case (_?, nil): return true  // numeric < alphanumeric
        case (nil, _?): return false
        case (nil, nil): return a < b
        }
      }
      return lhs.prerelease.count < rhs.prerelease.count
    }
  }
}

/// One release record from the signed index. Field names accept both the Platform
/// registry spelling (`kind`, `minOs`) and the longer aliases (`productKind`, `minimumOS`).
struct TBDRelease: Decodable, Equatable {
  struct Artifact: Decodable, Equatable {
    let url: String
    let sha256: String
  }

  let product: String
  let kind: String
  let version: String
  let channel: String
  let artifact: Artifact?
  let minimumOS: String?
  let build: String?

  init(
    product: String, kind: String, version: String, channel: String,
    artifact: Artifact?, minimumOS: String? = nil, build: String? = nil
  ) {
    self.product = product
    self.kind = kind
    self.version = version
    self.channel = channel
    self.artifact = artifact
    self.minimumOS = minimumOS
    self.build = build
  }

  private enum Keys: String, CodingKey {
    case product, kind, productKind, version, channel, artifact, minOs, minimumOS, build
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    product = try c.decode(String.self, forKey: .product)
    kind =
      try c.decodeIfPresent(String.self, forKey: .productKind)
      ?? c.decode(String.self, forKey: .kind)
    version = try c.decode(String.self, forKey: .version)
    channel = try c.decode(String.self, forKey: .channel)
    artifact = try? c.decodeIfPresent(Artifact.self, forKey: .artifact)
    minimumOS =
      (try? c.decodeIfPresent(String.self, forKey: .minimumOS))
      ?? (try? c.decodeIfPresent(String.self, forKey: .minOs))
    if let text = try? c.decodeIfPresent(String.self, forKey: .build) {
      build = text
    } else if let number = try? c.decodeIfPresent(Int.self, forKey: .build) {
      build = String(number)
    } else {
      build = nil
    }
  }
}

struct TBDReleaseIndex: Decodable {
  let releases: [TBDRelease]
}

enum TBDUpdateError: LocalizedError, Equatable {
  case insecureURL
  case badStatus(Int)
  case tooLarge
  case invalidPublicKey
  case invalidSignature
  case malformedIndex
  case digestMismatch
  case unzipFailed
  case unexpectedBundleContents
  case codeSignatureInvalid
  case notAutoInstallable(String)
  case notWritable(String)
  case versionNotNewer
  case installFailed(String)

  var errorDescription: String? {
    switch self {
    case .insecureURL: return "The update address is not a secure https address."
    case .badStatus(let code): return "The update server answered with status \(code)."
    case .tooLarge: return "The update download is larger than allowed."
    case .invalidPublicKey: return "The built-in update key is not valid."
    case .invalidSignature: return "The update list has no valid signature. It was ignored."
    case .malformedIndex: return "The update list could not be read."
    case .digestMismatch: return "The downloaded file does not match its published checksum."
    case .unzipFailed: return "The downloaded file could not be unpacked."
    case .unexpectedBundleContents: return "The download does not contain exactly one TBD.app."
    case .codeSignatureInvalid:
      return "The downloaded app failed the code signature check. It was not installed."
    case .notAutoInstallable(let why): return why
    case .notWritable(let path):
      return "TBD cannot write to \(path). Move TBD to the Applications folder or install the update manually."
    case .versionNotNewer: return "The downloaded app is not newer than the running app."
    case .installFailed(let why): return "The update could not be installed: \(why)"
    }
  }
}

enum TBDUpdateVerifier {
  /// DER prefix of an Ed25519 SubjectPublicKeyInfo; 32 raw key bytes follow.
  static let spkiPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])

  /// Raw 32-byte key from an SPKI PEM or base64 DER (44 bytes, prefix checked).
  static func publicKey(fromPEM pem: String) throws -> Curve25519.Signing.PublicKey {
    let b64 =
      pem
      .split(whereSeparator: \.isNewline)
      .filter { !$0.hasPrefix("-----") }
      .joined()
    guard let der = Data(base64Encoded: b64), der.count == 44, der.prefix(12) == spkiPrefix else {
      throw TBDUpdateError.invalidPublicKey
    }
    do { return try Curve25519.Signing.PublicKey(rawRepresentation: der.suffix(32)) } catch {
      throw TBDUpdateError.invalidPublicKey
    }
  }

  /// `signature` is the text of the `.sig` file: base64 of the 64-byte Ed25519 signature.
  static func verifyIndex(body: Data, signature: Data, publicKeyPEM: String) throws {
    let key = try publicKey(fromPEM: publicKeyPEM)
    guard
      let text = String(data: signature, encoding: .utf8),
      let raw = Data(
        base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      raw.count == 64,
      key.isValidSignature(raw, for: body)
    else { throw TBDUpdateError.invalidSignature }
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Compares hex digests; the expected value may carry a `sha256:` prefix.
  static func digestMatches(actualHex: String, expected: String) -> Bool {
    var want = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if want.hasPrefix("sha256:") { want.removeFirst(7) }
    guard want.count == 64, want.allSatisfy({ $0.isHexDigit }) else { return false }
    return want == actualHex.lowercased()
  }

  static func isWellFormedDigest(_ text: String) -> Bool {
    var hex = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if hex.hasPrefix("sha256:") { hex.removeFirst(7) }
    return hex.count == 64 && hex.allSatisfy { $0.isHexDigit }
  }

  static func verifySHA256(data: Data, expected: String) throws {
    guard digestMatches(actualHex: sha256Hex(data), expected: expected) else {
      throw TBDUpdateError.digestMismatch
    }
  }

  static func sha256Hex(ofFile url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func osVersion(_ text: String) -> OperatingSystemVersion? {
    let parts = text.split(separator: ".").map { Int($0) }
    guard (1...3).contains(parts.count), !parts.contains(where: { $0 == nil }) else { return nil }
    let n = parts.compactMap { $0 }
    return OperatingSystemVersion(
      majorVersion: n[0], minorVersion: n.count > 1 ? n[1] : 0, patchVersion: n.count > 2 ? n[2] : 0)
  }

  static func isSecureURL(_ url: URL?) -> Bool {
    guard let url, url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return false }
    return true
  }

  /// Highest valid release newer than `currentVersion`, or nil.
  static func selectUpdate(
    from releases: [TBDRelease],
    currentVersion: String,
    channels: Set<String> = ["stable"],
    os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
  ) -> TBDRelease? {
    guard let current = TBDSemver(currentVersion) else { return nil }
    var best: (TBDRelease, TBDSemver)?
    for release in releases {
      guard
        release.product == "tbd", release.kind == "desktop",
        channels.contains(release.channel),
        let artifact = release.artifact,
        isSecureURL(URL(string: artifact.url)),
        isWellFormedDigest(artifact.sha256),
        let version = TBDSemver(release.version), version > current
      else { continue }
      if let minimum = release.minimumOS {
        guard let need = osVersion(minimum), osAtLeast(os, need) else { continue }
      }
      if best == nil || version > best!.1 { best = (release, version) }
    }
    return best?.0
  }

  static func osAtLeast(_ have: OperatingSystemVersion, _ need: OperatingSystemVersion) -> Bool {
    (have.majorVersion, have.minorVersion, have.patchVersion)
      >= (need.majorVersion, need.minorVersion, need.patchVersion)
  }

  /// Code requirement string for the downloaded bundle. The team id comes from the running app.
  static func requirement(teamID: String) -> String? {
    guard teamID.count == 10, teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) })
    else { return nil }
    return
      "anchor apple generic and identifier \"com.tealbrick.tbd\" and certificate leaf[subject.OU] = \"\(teamID)\""
  }
}

// MARK: - Network helpers

/// Refuses redirects that leave https.
private final class TBDHTTPSRedirectGuard: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(TBDUpdateVerifier.isSecureURL(request.url) ? request : nil)
  }
}

/// One file download with progress. https only, also across redirects.
private final class TBDFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let destination: URL
  private let maxBytes: Int64
  private let onProgress: @Sendable (Double) -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?

  init(destination: URL, maxBytes: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
    self.destination = destination
    self.maxBytes = maxBytes
    self.onProgress = onProgress
  }

  func run(_ url: URL) async throws {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.httpCookieStorage = nil
    config.urlCache = nil
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      lock.lock()
      continuation = cont
      lock.unlock()
      session.downloadTask(with: URLRequest(url: url)).resume()
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    lock.lock()
    let cont = continuation
    continuation = nil
    lock.unlock()
    cont?.resume(with: result)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(TBDUpdateVerifier.isSecureURL(request.url) ? request : nil)
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
      downloadTask.cancel()
      finish(.failure(TBDUpdateError.tooLarge))
      return
    }
    if totalBytesExpectedToWrite > 0 {
      onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
  ) {
    let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { return finish(.failure(TBDUpdateError.badStatus(status))) }
    do {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: location, to: destination)
      finish(.success(()))
    } catch {
      finish(.failure(error))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { finish(.failure(error)) }
  }
}

// MARK: - Updater

@MainActor
final class TBDUpdater: ObservableObject {
  static let shared = TBDUpdater()

  enum State: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case downloading(progress: Double)
    case readyToInstall
    case failed(String)
  }

  nonisolated static let indexURL = URL(
    string:
      "https://raw.githubusercontent.com/Martin-Atrin/opt2-tealbrick-platform/main/registry/index.json"
  )!
  nonisolated static let channelKey = "tbd.updates.channel"
  nonisolated static let lastCheckKey = "tbd.updates.lastCheck"
  nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60
  nonisolated static let maxIndexBytes = 5 * 1024 * 1024
  nonisolated static let maxArtifactBytes: Int64 = 2 * 1024 * 1024 * 1024

  /// Release signing key (public). kid ccd73c250bdf847b.
  nonisolated static let publicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MCowBQYDK2VwAyEAH7nxFrNugQLVOqEXVIB4aOg83Jn19UCosd27fqnoPPI=
    -----END PUBLIC KEY-----
    """

  @Published private(set) var state: State = .idle
  @Published private(set) var latest: TBDRelease?

  private let logger = Logger(subsystem: "com.tealbrick.tbd", category: "updater")
  private let defaults = UserDefaults.standard
  private var started = false
  private var timer: Timer?
  private var busy = false

  private init() {}

  var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  private var channels: Set<String> {
    defaults.string(forKey: Self.channelKey) == "beta" ? ["stable", "beta"] : ["stable"]
  }

  /// Starts the automatic check (at most once per 24 hours). Never installs by itself.
  func start() {
    guard !started else { return }
    started = true
    checkIfDue()
    timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.checkIfDue() }
    }
  }

  private func checkIfDue() {
    let last = defaults.double(forKey: Self.lastCheckKey)
    if last > 0, Date().timeIntervalSince1970 - last < Self.checkInterval { return }
    Task { await check(automatic: true) }
  }

  /// Fetches and verifies the signed index, then publishes the result in `state`.
  func check(automatic: Bool = false) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    state = .checking
    defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
    do {
      let index = try await Self.fetchVerifiedIndex()
      if let release = TBDUpdateVerifier.selectUpdate(
        from: index.releases, currentVersion: currentVersion, channels: channels)
      {
        latest = release
        state = .available(version: release.version)
      } else {
        latest = nil
        state = .upToDate
      }
    } catch {
      logger.error("update check failed: \(error.localizedDescription, privacy: .public)")
      state = automatic ? .idle : .failed(error.localizedDescription)
    }
  }

  private nonisolated static func fetchVerifiedIndex() async throws -> TBDReleaseIndex {
    async let body = fetch(indexURL)
    async let signature = fetch(indexURL.appendingPathExtension("sig"))
    let (bodyData, sigData) = try await (body, signature)
    try TBDUpdateVerifier.verifyIndex(body: bodyData, signature: sigData, publicKeyPEM: publicKeyPEM)
    guard let index = try? JSONDecoder().decode(TBDReleaseIndex.self, from: bodyData) else {
      throw TBDUpdateError.malformedIndex
    }
    return index
  }

  private nonisolated static func fetch(_ url: URL) async throws -> Data {
    guard TBDUpdateVerifier.isSecureURL(url) else { throw TBDUpdateError.insecureURL }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 30
    config.httpCookieStorage = nil
    config.urlCache = nil
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request, delegate: TBDHTTPSRedirectGuard())
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw TBDUpdateError.badStatus(status) }
    guard data.count <= maxIndexBytes else { throw TBDUpdateError.tooLarge }
    return data
  }

  // MARK: Install

  /// Downloads, verifies, replaces the running app and relaunches. Requires a user click.
  func downloadAndInstall() async {
    guard !busy, let release = latest, let artifact = release.artifact else { return }
    busy = true
    defer { busy = false }
    var work: URL?
    do {
      let appURL = Bundle.main.bundleURL
      let teamID = try Self.autoInstallPreconditions(appURL: appURL)
      guard let url = URL(string: artifact.url), TBDUpdateVerifier.isSecureURL(url) else {
        throw TBDUpdateError.insecureURL
      }
      state = .downloading(progress: 0)
      // Same volume as the running app, so the final swap is atomic.
      let dir = try FileManager.default.url(
        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
      work = dir
      let zip = dir.appendingPathComponent("TBD-update.zip")
      let downloader = TBDFileDownloader(destination: zip, maxBytes: Self.maxArtifactBytes) { p in
        Task { @MainActor in
          if case .downloading = TBDUpdater.shared.state {
            TBDUpdater.shared.state = .downloading(progress: p)
          }
        }
      }
      try await downloader.run(url)

      let expected = artifact.sha256
      let newApp = try await Task.detached(priority: .userInitiated) {
        let actual = try TBDUpdateVerifier.sha256Hex(ofFile: zip)
        guard TBDUpdateVerifier.digestMatches(actualHex: actual, expected: expected) else {
          throw TBDUpdateError.digestMismatch
        }
        let extracted = dir.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try Self.unzip(zip, into: extracted)
        let app = try Self.singleApp(in: extracted)
        try Self.verifyCodeSignature(of: app, teamID: teamID)
        try Self.verifyBundleVersion(of: app)
        return app
      }.value

      state = .readyToInstall
      try Self.replace(appURL, with: newApp)
      try? FileManager.default.removeItem(at: dir)
      Self.relaunch(appURL)
    } catch {
      if let work { try? FileManager.default.removeItem(at: work) }
      logger.error("update install failed: \(error.localizedDescription, privacy: .public)")
      state = .failed(error.localizedDescription)
    }
  }

  /// Returns the running app's team id, or throws when the app cannot be updated in place.
  private static func autoInstallPreconditions(appURL: URL) throws -> String {
    guard appURL.pathExtension == "app" else {
      throw TBDUpdateError.notAutoInstallable("This copy of TBD is not an app bundle. Install the update manually.")
    }
    guard let team = runningTeamIdentifier() else {
      throw TBDUpdateError.notAutoInstallable(
        "This copy of TBD is not signed with a developer team. Download the update manually from the TBD website.")
    }
    if appURL.path.contains("/AppTranslocation/") {
      throw TBDUpdateError.notAutoInstallable(
        "TBD runs from a temporary location. Move TBD to the Applications folder and open it again.")
    }
    let parent = appURL.deletingLastPathComponent().path
    guard FileManager.default.isWritableFile(atPath: parent) else {
      throw TBDUpdateError.notWritable(parent)
    }
    return team
  }

  static func runningTeamIdentifier() -> String? {
    var selfCode: SecCode?
    guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let dict = info as? [String: Any]
    else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
  }

  private nonisolated static func unzip(_ zip: URL, into dir: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", zip.path, dir.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { throw TBDUpdateError.unzipFailed }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw TBDUpdateError.unzipFailed }
  }

  private nonisolated static func singleApp(in dir: URL) throws -> URL {
    let items = try FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [])
    let apps = items.filter { $0.pathExtension == "app" }
    guard apps.count == 1, apps[0].lastPathComponent == "TBD.app" else {
      throw TBDUpdateError.unexpectedBundleContents
    }
    let values = try apps[0].resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard values.isSymbolicLink != true, values.isDirectory == true else {
      throw TBDUpdateError.unexpectedBundleContents
    }
    return apps[0]
  }

  private nonisolated static func verifyCodeSignature(of app: URL, teamID: String) throws {
    guard let text = TBDUpdateVerifier.requirement(teamID: teamID) else {
      throw TBDUpdateError.codeSignatureInvalid
    }
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard
      SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
      SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { throw TBDUpdateError.codeSignatureInvalid }
    let flags = SecCSFlags(
      rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
      throw TBDUpdateError.codeSignatureInvalid
    }
  }

  private nonisolated static func verifyBundleVersion(of app: URL) throws {
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    guard
      let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
      plist["CFBundleIdentifier"] as? String == "com.tealbrick.tbd",
      let newText = plist["CFBundleShortVersionString"] as? String,
      let new = TBDSemver(newText), let cur = current.flatMap(TBDSemver.init), new > cur
    else { throw TBDUpdateError.versionNotNewer }
  }

  /// Atomic swap on the same volume; the old bundle ends in the system replacement directory.
  private static func replace(_ appURL: URL, with newApp: URL) throws {
    do {
      _ = try FileManager.default.replaceItemAt(
        appURL, withItemAt: newApp, backupItemName: nil, options: [.usingNewMetadataOnly])
    } catch {
      throw TBDUpdateError.installFailed(error.localizedDescription)
    }
  }

  private static func relaunch(_ appURL: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    // The path is passed as an argument ($1), never spliced into the script text.
    process.arguments = ["-c", "sleep 1; open \"$1\"", "sh", appURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try? process.run()
    AppDelegate.allowTermination = true
    NSApp.terminate(nil)
  }
}
