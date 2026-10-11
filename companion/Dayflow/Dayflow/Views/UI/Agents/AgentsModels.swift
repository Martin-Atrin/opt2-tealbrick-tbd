//
//  AgentsModels.swift
//  Dayflow
//
//  Data model for the Agents tab. A headless Fable run (see AgentsRecapPrompt)
//  sweeps the day's Claude Code and Codex sessions and writes a JSON recap file
//  that decodes into these types. Every card style renders from the same
//  `turns` array — the styles are pure view-layer projections.
//
//  Decoding is deliberately lenient (decodeIfPresent + fallbacks everywhere):
//  the file is authored by a model, so a missing field or an unexpected enum
//  string should degrade gracefully instead of failing the whole recap.
//

import SwiftUI
import MacParakeet

struct AgentsDayRecap: Codable, Sendable {
  var schemaVersion: Int
  var day: String
  var generatedAt: String
  var workstreams: [AgentWorkstream]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
    day = (try? container.decodeIfPresent(String.self, forKey: .day)) ?? ""
    generatedAt = (try? container.decodeIfPresent(String.self, forKey: .generatedAt)) ?? ""
    workstreams =
      (try? container.decodeIfPresent([AgentWorkstream].self, forKey: .workstreams)) ?? []
  }

  var totalCounts: AgentStatusCounts {
    workstreams.reduce(AgentStatusCounts()) { $0.adding($1.counts) }
  }
}

struct AgentWorkstream: Codable, Identifiable, Sendable {
  var id: String
  var name: String
  var summary: String
  var bullets: [String]
  var threads: [AgentThread]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name =
      (try? container.decodeIfPresent(String.self, forKey: .name)) ?? String(localized: "Untitled")
    id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? name
    summary = (try? container.decodeIfPresent(String.self, forKey: .summary)) ?? ""
    bullets = (try? container.decodeIfPresent([String].self, forKey: .bullets)) ?? []
    threads = (try? container.decodeIfPresent([AgentThread].self, forKey: .threads)) ?? []
  }

  var counts: AgentStatusCounts {
    threads.reduce(AgentStatusCounts()) { $0.adding($1.status) }
  }
}

struct AgentThread: Codable, Identifiable, Sendable {
  var id: String
  var title: String
  var source: AgentThreadSource
  var projectName: String
  var sessionPath: String
  var status: AgentThreadStatus
  var startedAt: String
  var endedAt: String
  var latestOutcome: String
  var turns: [AgentTurn]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title =
      (try? container.decodeIfPresent(String.self, forKey: .title))
      ?? String(localized: "Untitled thread")
    id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? title
    let sourceRaw = (try? container.decodeIfPresent(String.self, forKey: .source)) ?? ""
    source = AgentThreadSource(rawValue: sourceRaw) ?? .claude
    projectName = (try? container.decodeIfPresent(String.self, forKey: .projectName)) ?? ""
    sessionPath = (try? container.decodeIfPresent(String.self, forKey: .sessionPath)) ?? ""
    let statusRaw = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? ""
    status = AgentThreadStatus(rawValue: statusRaw) ?? .completed
    startedAt = (try? container.decodeIfPresent(String.self, forKey: .startedAt)) ?? ""
    endedAt = (try? container.decodeIfPresent(String.self, forKey: .endedAt)) ?? ""
    latestOutcome = (try? container.decodeIfPresent(String.self, forKey: .latestOutcome)) ?? ""
    turns = (try? container.decodeIfPresent([AgentTurn].self, forKey: .turns)) ?? []
  }

  var firstPrompt: String {
    turns.first(where: { $0.role == .user })?.text ?? title
  }

  /// Intermediate agent milestones: every agent turn except the one that
  /// already appears as `latestOutcome`.
  var milestoneTexts: [String] {
    let agentTexts = turns.filter { $0.role == .agent }.map(\.text)
    if agentTexts.last == latestOutcome {
      return Array(agentTexts.dropLast())
    }
    return agentTexts
  }
}

struct AgentTurn: Codable, Identifiable, Sendable {
  let id = UUID()
  var role: AgentTurnRole
  var text: String
  var highlight: AgentTurnHighlight
  var bullets: [String]
  var artifactName: String?
  var artifactPath: String?

  private enum CodingKeys: String, CodingKey {
    case role, text, highlight, bullets, artifactName, artifactPath
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let roleRaw = (try? container.decodeIfPresent(String.self, forKey: .role)) ?? ""
    role = AgentTurnRole(rawValue: roleRaw) ?? .agent
    text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
    let highlightRaw = (try? container.decodeIfPresent(String.self, forKey: .highlight)) ?? ""
    highlight = AgentTurnHighlight(rawValue: highlightRaw) ?? .none
    bullets = (try? container.decodeIfPresent([String].self, forKey: .bullets)) ?? []
    artifactName = try? container.decodeIfPresent(String.self, forKey: .artifactName)
    artifactPath = try? container.decodeIfPresent(String.self, forKey: .artifactPath)
  }
}

enum AgentTurnRole: String, Codable, Sendable {
  case user
  case agent
}

enum AgentTurnHighlight: String, Codable, Sendable {
  case none
  case keyDecision
  case keyInfo
  case readyForReview
}

enum AgentThreadSource: String, Codable, Sendable {
  case claude
  case codex

  var displayName: String {
    switch self {
    case .claude: return String(localized: "Claude Code")
    case .codex: return String(localized: "Codex")
    }
  }
}

enum AgentThreadStatus: String, Codable, CaseIterable, Sendable {
  case blocked
  case reviewReady
  case inProgress
  case completed

  var displayName: String {
    switch self {
    case .blocked: return String(localized: "Blocked")
    case .reviewReady: return String(localized: "Review ready")
    case .inProgress: return String(localized: "In progress")
    case .completed: return String(localized: "Completed")
    }
  }
}

struct AgentStatusCounts: Sendable {
  var blocked = 0
  var reviewReady = 0
  var inProgress = 0
  var completed = 0

  func adding(_ status: AgentThreadStatus) -> AgentStatusCounts {
    var copy = self
    switch status {
    case .blocked: copy.blocked += 1
    case .reviewReady: copy.reviewReady += 1
    case .inProgress: copy.inProgress += 1
    case .completed: copy.completed += 1
    }
    return copy
  }

  func adding(_ other: AgentStatusCounts) -> AgentStatusCounts {
    var copy = self
    copy.blocked += other.blocked
    copy.reviewReady += other.reviewReady
    copy.inProgress += other.inProgress
    copy.completed += other.completed
    return copy
  }

  func count(for status: AgentThreadStatus) -> Int {
    switch status {
    case .blocked: return blocked
    case .reviewReady: return reviewReady
    case .inProgress: return inProgress
    case .completed: return completed
    }
  }
}

// MARK: - Card rendering styles

/// The four rendering sub-directions from the Figma exploration, toggleable at
/// runtime so each can be evaluated with real data.
enum AgentCardStyle: String, CaseIterable, Identifiable {
  case messenger
  case transcript
  case brief
  case milestones

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .messenger: return String(localized: "Messenger")
    case .transcript: return String(localized: "Transcript")
    case .brief:
      return String(
        localized: "Briefing",
        comment:
          "An agent milestone containing instructions or a summary; a noun, not the adjective short."
      )
    case .milestones: return String(localized: "Milestones")
    }
  }
}

// MARK: - Shared palette

enum AgentsPalette {
  // Muted brick data set, assigned to workstreams by index. Category/data
  // colors, never chrome — see design-language.md "Data/category colours".
  static let blobColors: [Color] = TBDTokens.data

  static func blobColor(at index: Int) -> Color {
    blobColors[index % blobColors.count]
  }

  // Status chip colors resolve through TBDTokens: `alert` for the
  // blocked/error state, the single `accent` for the actionable
  // review-ready state, and neutral ink/muted tones for everything else.
  // No donor red/green/gray chip fills.
  static func chipBackground(for status: AgentThreadStatus) -> Color {
    switch status {
    case .blocked: return TBDTokens.alert.opacity(0.14)
    case .reviewReady: return TBDTokens.accent.opacity(0.14)
    case .inProgress: return TBDTokens.paper
    case .completed: return TBDTokens.hover
    }
  }

  static func chipForeground(for status: AgentThreadStatus) -> Color {
    switch status {
    case .blocked: return TBDTokens.alert
    case .reviewReady: return TBDTokens.accent
    case .inProgress: return TBDTokens.muted
    case .completed: return TBDTokens.muted
    }
  }

  static func legendDot(for status: AgentThreadStatus) -> Color {
    switch status {
    case .blocked: return TBDTokens.alert
    case .reviewReady: return TBDTokens.accent
    case .inProgress: return TBDTokens.ink.opacity(0.3)
    case .completed: return TBDTokens.muted
    }
  }

  // Highlight pill colors, constant across all card styles. Brick has one
  // accent, so the three highlight kinds are differentiated by weight
  // (filled ink / neutral bordered / accent) instead of donor purple/blue/
  // orange hues.
  static let keyDecisionBackground = TBDTokens.ink.opacity(0.08)
  static let keyDecisionForeground = TBDTokens.ink
  static let keyInfoBackground = TBDTokens.hover
  static let keyInfoForeground = TBDTokens.muted
  static let reviewBackground = TBDTokens.accent.opacity(0.12)
  static let reviewForeground = TBDTokens.accent
}
