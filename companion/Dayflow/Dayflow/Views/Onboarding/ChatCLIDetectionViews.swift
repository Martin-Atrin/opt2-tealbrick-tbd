import AppKit
import Foundation
import TBDDesign
import SwiftUI

struct CLIDetectionReport {
  let state: CLIDetectionState
  let resolvedPath: String?
  let stdout: String?
  let stderr: String?
}

struct CLIDetector {
  /// Detect if a CLI tool is installed by running `tool --version` via login shell.
  /// This replicates exactly what happens when user types in Terminal.app.
  static func detect(tool: CLITool) async -> CLIDetectionReport {
    if tool == .codex, let resolution = CodexExecutableResolver.shared.resolve() {
      return CLIDetectionReport(
        state: .installed(version: resolution.versionSummary),
        resolvedPath: resolution.executableURL.path,
        stdout: resolution.versionSummary,
        stderr: nil
      )
    }

    let result = LoginShellRunner.run("\(tool.executableName) --version", timeout: 10)

    if result.exitCode == 0 {
      let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
      let summary = firstLine.isEmpty ? "\(tool.shortName) detected" : firstLine
      return CLIDetectionReport(
        state: .installed(version: summary), resolvedPath: tool.executableName,
        stdout: result.stdout, stderr: result.stderr)
    }

    if result.exitCode == 127 || result.stderr.contains("command not found") {
      return CLIDetectionReport(
        state: .notFound, resolvedPath: nil, stdout: result.stdout, stderr: result.stderr)
    }

    let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedPath = tool == .codex ? nil : tool.executableName
    if message.isEmpty {
      return CLIDetectionReport(
        state: .failed(message: String(localized: "Exit code \(result.exitCode)")),
        resolvedPath: resolvedPath,
        stdout: result.stdout, stderr: result.stderr)
    }
    return CLIDetectionReport(
      state: .failed(message: message), resolvedPath: resolvedPath, stdout: result.stdout,
      stderr: result.stderr)
  }

  /// Check if a CLI tool is installed (simple boolean check)
  static func isInstalled(_ tool: CLITool) -> Bool {
    LoginShellRunner.isInstalled(tool.executableName)
  }

  /// Run an arbitrary debug command via login shell
  static func runDebugCommand(_ command: String) -> CLIResult {
    let result = LoginShellRunner.run(command, timeout: 30)
    return CLIResult(
      stdout: result.stdout,
      stderr: result.stderr,
      exitCode: result.exitCode,
      shellCommand: command,
      environmentOverrides: [:]
    )
  }
}

struct ChatCLIDetectionStepView: View {
  let codexStatus: CLIDetectionState
  let codexReport: CLIDetectionReport?
  let claudeStatus: CLIDetectionState
  let claudeReport: CLIDetectionReport?
  let isChecking: Bool
  let onRetry: () -> Void
  let onInstall: (CLITool) -> Void
  let selectedTool: CLITool?
  let onSelectTool: (CLITool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text(
        "Tealbrick can talk to ChatGPT (via the Codex CLI) or Claude Code. You only need one installed and signed in on this Mac. After installing, run `codex auth` or `claude login` in Terminal to connect it to your account."
      )
      .font(TBDTokens.Typography.body)
      .foregroundColor(TBDColor.ink)

      HStack(alignment: .top, spacing: 18) {
        ChatCLIToolStatusRow(
          tool: .codex,
          status: codexStatus,
          onInstall: { onInstall(.codex) }
        )
        ChatCLIToolStatusRow(
          tool: .claude,
          status: claudeStatus,
          onInstall: { onInstall(.claude) }
        )
      }

      Text(
        "Tip: Once both are installed, you can choose which provider Tealbrick uses from Settings → AI Provider."
      )
      .font(TBDTokens.Typography.body)
      .foregroundColor(TBDColor.ink)

      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 14) {
          Text("Choose which provider Tealbrick should use")
            .font(TBDTokens.Typography.tag)
            .foregroundColor(TBDColor.ink)
          HStack(spacing: 12) {
            ForEach(CLITool.allCases, id: \.self) { tool in
              selectionButton(for: tool)
            }
          }
        }
        .padding(16)
        .frame(maxWidth: 516)
        .background(TBDColor.tile, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))

        Button(action: {
          if !isChecking {
            onRetry()
          }
        }) {
          HStack(spacing: 4) {
            if isChecking {
              ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
            } else {
              Image(systemName: "arrow.clockwise")
                .font(TBDFonts.symbol(13, .bold))
                .frame(width: 16, height: 16)
            }
            Text(isChecking ? String(localized: "Checking…") : String(localized: "Check"))
          }
        }
        .buttonStyle(TBDButtonStyle(.secondary))
        .disabled(isChecking)
        .pointingHandCursor()
      }
    }
  }

  func isToolAvailable(_ tool: CLITool) -> Bool {
    switch tool {
    case .codex:
      if codexStatus.isInstalled { return true }
      return codexReport?.resolvedPath != nil
    case .claude:
      if claudeStatus.isInstalled { return true }
      return claudeReport?.resolvedPath != nil
    }
  }

  @ViewBuilder
  func selectionButton(for tool: CLITool) -> some View {
    let enabled = isToolAvailable(tool)
    Button(action: {
      onSelectTool(tool)
    }) {
      HStack(spacing: 12) {
        Image(systemName: selectedTool == tool ? "largecircle.fill.circle" : "circle")
          .font(TBDFonts.symbol(22, .regular))
          .frame(width: 24, height: 24)
          .foregroundColor(selectedTool == tool ? TBDColor.tealInk : TBDColor.lineStrong)
        VStack(alignment: .leading, spacing: 4) {
          Text(tool.shortName)
            .font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightLabel))
            .foregroundColor(TBDColor.ink)
          Text(enabled ? String(localized: "Ready to use") : String(localized: "Install to enable"))
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
            .foregroundColor(TBDColor.muted)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(selectedTool == tool ? TBDColor.tealWash : TBDColor.tile, in: TBDBrickShape())
      .overlay(
        TBDBrickShape()
          .strokeBorder(selectedTool == tool ? TBDColor.tealWashLine : TBDColor.line, lineWidth: TBDKit.hair)
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

struct ChatCLIToolStatusRow: View {
  let tool: CLITool
  let status: CLIDetectionState
  let onInstall: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Icon and title row
      HStack(spacing: 12) {
        Image(tool.logoAssetName)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 32, height: 32)

        Text(tool.shortName)
          .font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightLabel))
          .foregroundColor(TBDColor.ink)

        Spacer(minLength: 53)

        statusView
      }

      // Install button if needed
      if shouldShowInstallButton {
        Button(action: onInstall) {
          HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle.fill").font(TBDFonts.symbol(11, .bold))
            Text(installLabel)
          }
        }
        .buttonStyle(TBDButtonStyle(.secondary))
        .pointingHandCursor()
      }
    }
    .padding(14)
    .background(TBDColor.tile, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }

  @ViewBuilder
  var statusView: some View {
    switch status {
    case .checking, .unknown:
      HStack(spacing: 5) {
        ProgressView().scaleEffect(0.5)
        TBDTag(status.statusLabel, status: .idle)
      }
    case .installed:
      TBDTag(status.statusLabel, status: .live)
    case .notFound:
      TBDTag(status.statusLabel, status: .needsYou)
    case .failed:
      TBDTag(status.statusLabel, status: .needsYou)
    }
  }

  var shouldShowInstallButton: Bool {
    switch status {
    case .notFound, .failed:
      return tool.installURL != nil
    default:
      return false
    }
  }

  var installLabel: String {
    switch status {
    case .failed:
      return String(localized: "Setup guide")
    default:
      return String(localized: "Install")
    }
  }
}
