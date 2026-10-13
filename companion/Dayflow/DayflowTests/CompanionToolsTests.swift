import XCTest

@testable import TBD

/// Pure logic behind Settings > Tools. Every test uses a throwaway directory
/// with real files and symlinks; nothing touches /usr/local/bin.
final class CompanionToolsTests: XCTestCase {
  private var root: URL!
  private var fileManager: FileManager { .default }

  private var helperPath: String { root.appendingPathComponent("App/Contents/Helpers/dayflow").path }
  private var linkPath: String { root.appendingPathComponent("bin/dayflow").path }

  override func setUpWithError() throws {
    root = fileManager.temporaryDirectory.appendingPathComponent(
      "CompanionToolsTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
      at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: root.appendingPathComponent("App/Contents/Helpers"), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: helperPath))
  }

  override func tearDownWithError() throws {
    // Restore write access in case a test made the directory read-only.
    try? fileManager.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("bin").path)
    try? fileManager.removeItem(at: root)
  }

  // MARK: - Paths and MCP config

  func testHelperPathIsInContentsHelpersNotMacOS() {
    let bundle = URL(fileURLWithPath: "/Applications/Tealbrick.app")
    XCTAssertEqual(
      CompanionTools.helperPath(bundleURL: bundle),
      "/Applications/Tealbrick.app/Contents/Helpers/dayflow")
  }

  func testMCPConfigSnippetExactText() {
    XCTAssertEqual(
      CompanionTools.mcpConfigSnippet(helperPath: "/Applications/Tealbrick.app/Contents/Helpers/dayflow"),
      """
      "dayflow": {
        "command": "/Applications/Tealbrick.app/Contents/Helpers/dayflow",
        "args": ["mcp"]
      }
      """)
  }

  func testMCPConfigSnippetIsValidJSONWhenWrappedInAnObject() throws {
    let path = "/Applications/Tealbrick.app/Contents/Helpers/dayflow"
    let wrapped = "{" + CompanionTools.mcpConfigSnippet(helperPath: path) + "}"
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(wrapped.utf8)) as? [String: Any])
    let entry = try XCTUnwrap(object["dayflow"] as? [String: Any])
    XCTAssertEqual(entry["command"] as? String, path)
    XCTAssertEqual(entry["args"] as? [String], ["mcp"])
    XCTAssertEqual(Set(entry.keys), ["command", "args"])
  }

  func testMCPConfigSnippetEscapesQuotesAndBackslashesInThePath() throws {
    let path = "/Apps/My \"Tealbrick\"\\Beta.app/Contents/Helpers/dayflow"
    let snippet = CompanionTools.mcpConfigSnippet(helperPath: path)
    XCTAssertTrue(
      snippet.contains("\"command\": \"/Apps/My \\\"Tealbrick\\\"\\\\Beta.app/Contents/Helpers/dayflow\","),
      snippet)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(("{" + snippet + "}").utf8)) as? [String: Any])
    let entry = try XCTUnwrap(object["dayflow"] as? [String: Any])
    XCTAssertEqual(entry["command"] as? String, path)
  }

  // MARK: - Terminal command status

  func testStatusIsNotInstalledWhenNothingIsAtTheLinkPath() {
    XCTAssertEqual(
      CompanionTools.terminalCommandStatus(linkPath: linkPath, expectedHelperPath: helperPath),
      .notInstalled)
  }

  func testStatusIsInstalledWhenLinkPointsAtTheBundledHelper() throws {
    try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: helperPath)
    XCTAssertEqual(
      CompanionTools.terminalCommandStatus(linkPath: linkPath, expectedHelperPath: helperPath),
      .installed)
  }

  func testStatusIsInstalledForARelativeLinkToTheHelper() throws {
    try fileManager.createSymbolicLink(
      atPath: linkPath, withDestinationPath: "../App/Contents/Helpers/dayflow")
    XCTAssertEqual(
      CompanionTools.terminalCommandStatus(linkPath: linkPath, expectedHelperPath: helperPath),
      .installed)
  }

  func testStatusPointsElsewhereForALinkToAnotherCopyOfTheApp() throws {
    let other = root.appendingPathComponent("Old.app/Contents/Helpers/dayflow").path
    try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: other)
    XCTAssertEqual(
      CompanionTools.terminalCommandStatus(linkPath: linkPath, expectedHelperPath: helperPath),
      .pointsElsewhere(target: other))
  }

  func testStatusPointsElsewhereWithNoTargetForARegularFile() throws {
    try Data("binary".utf8).write(to: URL(fileURLWithPath: linkPath))
    XCTAssertEqual(
      CompanionTools.terminalCommandStatus(linkPath: linkPath, expectedHelperPath: helperPath),
      .pointsElsewhere(target: nil))
  }

  func testStatusSeesADanglingLinkInsteadOfReportingNotInstalled() throws {
    let missing = root.appendingPathComponent("Gone.app/Contents/Helpers/dayflow").path
    try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: missing)
    XCTAssertEqual(
      CompanionTools.terminalCommandStatus(linkPath: linkPath, expectedHelperPath: helperPath),
      .pointsElsewhere(target: missing))
  }

  // MARK: - Install and remove

  func testInstallCreatesASymlinkToTheHelper() throws {
    try CompanionTools.installTerminalCommand(linkPath: linkPath, helperPath: helperPath)
    XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: linkPath), helperPath)
    XCTAssertEqual(
      CompanionTools.terminalCommandStatus(linkPath: linkPath, expectedHelperPath: helperPath),
      .installed)
  }

  func testInstallReplacesALinkLeftByAnotherCopyOfTheApp() throws {
    let other = root.appendingPathComponent("Old.app/Contents/Helpers/dayflow").path
    try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: other)
    try CompanionTools.installTerminalCommand(linkPath: linkPath, helperPath: helperPath)
    XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: linkPath), helperPath)
  }

  func testInstallNeverOverwritesARegularFile() throws {
    try Data("mine".utf8).write(to: URL(fileURLWithPath: linkPath))
    XCTAssertThrowsError(
      try CompanionTools.installTerminalCommand(linkPath: linkPath, helperPath: helperPath)
    ) { error in
      XCTAssertEqual(error as? CompanionTools.TerminalCommandError, .occupiedByFile)
    }
    XCTAssertEqual(try String(contentsOfFile: linkPath, encoding: .utf8), "mine")
  }

  func testInstallReportsAdministratorNeededWhenTheDirectoryIsNotWritable() throws {
    try XCTSkipIf(geteuid() == 0, "root can write to a read-only directory")
    try fileManager.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: root.appendingPathComponent("bin").path)
    XCTAssertThrowsError(
      try CompanionTools.installTerminalCommand(linkPath: linkPath, helperPath: helperPath)
    ) { error in
      XCTAssertEqual(error as? CompanionTools.TerminalCommandError, .needsAdministrator)
    }
    XCTAssertEqual(
      CompanionTools.terminalCommandStatus(linkPath: linkPath, expectedHelperPath: helperPath),
      .notInstalled)
  }

  func testRemoveDeletesOnlyTheSymlink() throws {
    try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: helperPath)
    XCTAssertTrue(CompanionTools.removeTerminalCommand(linkPath: linkPath))
    XCTAssertEqual(
      CompanionTools.terminalCommandStatus(linkPath: linkPath, expectedHelperPath: helperPath),
      .notInstalled)
    XCTAssertTrue(fileManager.fileExists(atPath: helperPath), "the bundled helper stays")
  }

  func testRemoveLeavesARegularFileAlone() throws {
    try Data("mine".utf8).write(to: URL(fileURLWithPath: linkPath))
    XCTAssertFalse(CompanionTools.removeTerminalCommand(linkPath: linkPath))
    XCTAssertEqual(try String(contentsOfFile: linkPath, encoding: .utf8), "mine")
  }

  func testRemoveDoesNothingWhenNotInstalled() {
    XCTAssertFalse(CompanionTools.removeTerminalCommand(linkPath: linkPath))
  }

  // MARK: - Manual command

  func testManualInstallCommandExactText() {
    XCTAssertEqual(
      CompanionTools.manualInstallCommand(
        helperPath: "/Applications/Tealbrick.app/Contents/Helpers/dayflow"),
      "sudo mkdir -p /usr/local/bin && sudo ln -sf '/Applications/Tealbrick.app/Contents/Helpers/dayflow' /usr/local/bin/dayflow"
    )
  }

  func testManualInstallCommandQuotesPathsThatNeedIt() {
    XCTAssertEqual(
      CompanionTools.manualInstallCommand(helperPath: "/Apps/Bob's App.app/Contents/Helpers/dayflow"),
      "sudo mkdir -p /usr/local/bin && sudo ln -sf '/Apps/Bob'\\''s App.app/Contents/Helpers/dayflow' /usr/local/bin/dayflow"
    )
    XCTAssertEqual(
      CompanionTools.manualInstallCommand(helperPath: "/h", linkPath: "/opt/my bin/dayflow"),
      "sudo mkdir -p '/opt/my bin' && sudo ln -sf '/h' '/opt/my bin/dayflow'")
  }
}
