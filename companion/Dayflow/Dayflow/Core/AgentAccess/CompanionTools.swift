//
//  CompanionTools.swift
//  Dayflow
//
//  Pure logic behind Settings > Tools: the `dayflow` terminal command and the
//  MCP config snippet. Foundation only, so it can be tested without launching
//  the app. Nothing here edits another app's configuration; the only file the
//  app ever creates or removes is its own symlink for the terminal command.
//

import Foundation

enum CompanionTools {
  static let terminalCommandName = "dayflow"
  static let defaultTerminalLinkPath = "/usr/local/bin/dayflow"

  /// The bundled CLI. Lives in Contents/Helpers, NOT Contents/MacOS: the
  /// filesystem is case-insensitive, so "dayflow" next to the "Dayflow" app
  /// executable would overwrite it.
  static func helperPath(bundleURL: URL) -> String {
    bundleURL.appendingPathComponent("Contents/Helpers/dayflow").path
  }

  // MARK: - MCP config snippet

  /// The entry to paste under `mcpServers` in any MCP client's configuration.
  static func mcpConfigSnippet(helperPath: String) -> String {
    """
    "dayflow": {
      "command": \(jsonString(helperPath)),
      "args": ["mcp"]
    }
    """
  }

  private static func jsonString(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
      let encoded = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return encoded
  }

  // MARK: - Terminal command

  enum TerminalCommandStatus: Equatable {
    case installed
    case notInstalled
    /// Something else sits at the link path. `target` is the symlink
    /// destination, or nil when it is not a symlink (a real file).
    case pointsElsewhere(target: String?)
  }

  enum TerminalCommandError: Error, Equatable {
    /// The link directory needs administrator access (the usual case for
    /// /usr/local/bin).
    case needsAdministrator
    /// A regular file, not a symlink, is in the way. It is left untouched.
    case occupiedByFile
  }

  static func terminalCommandStatus(
    linkPath: String = defaultTerminalLinkPath,
    expectedHelperPath: String,
    fileManager: FileManager = .default
  ) -> TerminalCommandStatus {
    // attributesOfItem does not follow symlinks, so a dangling link is seen.
    guard let attributes = try? fileManager.attributesOfItem(atPath: linkPath) else {
      return .notInstalled
    }
    guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
      let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkPath)
    else {
      return .pointsElsewhere(target: nil)
    }
    let resolved =
      destination.hasPrefix("/")
      ? destination
      : (linkPath as NSString).deletingLastPathComponent + "/" + destination
    let expected = expectedHelperPath
    return (destination == expected
      || (resolved as NSString).standardizingPath == (expected as NSString).standardizingPath)
      ? .installed : .pointsElsewhere(target: destination)
  }

  /// Links `linkPath` to the bundled helper. An existing symlink (for example
  /// one left by an older copy of the app) is replaced; a regular file is not.
  static func installTerminalCommand(
    linkPath: String = defaultTerminalLinkPath,
    helperPath: String,
    fileManager: FileManager = .default
  ) throws {
    if let attributes = try? fileManager.attributesOfItem(atPath: linkPath) {
      guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
        throw TerminalCommandError.occupiedByFile
      }
      do {
        try fileManager.removeItem(atPath: linkPath)
      } catch {
        throw TerminalCommandError.needsAdministrator
      }
    }
    do {
      try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: helperPath)
    } catch {
      throw TerminalCommandError.needsAdministrator
    }
  }

  /// Removes the link only when it is a symlink. Returns whether it removed one.
  @discardableResult
  static func removeTerminalCommand(
    linkPath: String = defaultTerminalLinkPath,
    fileManager: FileManager = .default
  ) -> Bool {
    guard let attributes = try? fileManager.attributesOfItem(atPath: linkPath),
      attributes[.type] as? FileAttributeType == .typeSymbolicLink
    else { return false }
    return (try? fileManager.removeItem(atPath: linkPath)) != nil
  }

  /// The command the user can run in Terminal when the automatic install
  /// cannot write to the link directory.
  static func manualInstallCommand(
    helperPath: String,
    linkPath: String = defaultTerminalLinkPath
  ) -> String {
    let directory = (linkPath as NSString).deletingLastPathComponent
    return
      "sudo mkdir -p \(shellWord(directory)) && sudo ln -sf \(shellEscape(helperPath)) \(shellWord(linkPath))"
  }

  /// Leaves plain paths readable and quotes anything that needs it.
  private static func shellWord(_ string: String) -> String {
    let plain = !string.isEmpty && string.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        || "_@%+=:,./-".unicodeScalars.contains($0)
    }
    return plain ? string : shellEscape(string)
  }

  /// Single-quote escaping for safe inclusion in a shell command.
  static func shellEscape(_ string: String) -> String {
    let sanitized = string.replacingOccurrences(of: "\0", with: "")
    let escaped = sanitized.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
  }
}
