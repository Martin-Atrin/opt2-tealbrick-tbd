//
//  AgentThreadCardView.swift
//  Dayflow
//
//  The per-thread review card. Four toggleable renderings of the same
//  `turns` data, matching the Figma sub-directions:
//  - messenger:  human prompts as right-aligned bubbles, agent text plain left
//  - transcript: uniform left column with person/agent glyphs, tinted key rows
//  - brief:      agent outcomes as a prose narrative, turn structure dissolved
//  - milestones: first prompt + quote-list of milestones + bold latest outcome
//
//  Collapsed, every style shows the same two-line summary (first prompt +
//  latest outcome), mirroring the Figma deck cards.
//

import AppKit
import SwiftUI
import TBDDesign

struct AgentThreadCardView: View {
  let thread: AgentThread
  let style: AgentCardStyle
  let isExpanded: Bool
  let isKept: Bool
  let onToggleExpanded: () -> Void
  let onToggleKept: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header

      ScrollView {
        content
          .padding(18)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 420)
      .fixedSize(horizontal: false, vertical: true)

      footer
    }
    .background(TBDTokens.paper)
    .overlay(
      RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
        .strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline)
    )
  }

  // MARK: - Chrome

  private var header: some View {
    HStack(spacing: 7) {
      Image(systemName: thread.source == .claude ? "asterisk" : "circle.hexagongrid")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.black.opacity(0.45))

      Text(headerTitle)
        .font(.custom("Switzer", size: 12))
        .fontWeight(.medium)
        .foregroundColor(.black.opacity(0.6))
        .lineLimit(1)

      Spacer()

      sourceLink
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(TBDTokens.hover)
  }

  private var headerTitle: String {
    thread.projectName.isEmpty ? thread.source.displayName : thread.projectName
  }

  private var sourceLink: some View {
    Button {
      AgentThreadOpener.open(thread)
    } label: {
      HStack(spacing: 3) {
        Text("Source")
          .font(.custom("Switzer", size: 11.5))
        Image(systemName: "arrow.up.right")
          .font(.system(size: 8.5, weight: .semibold))
      }
      .foregroundColor(.black.opacity(0.4))
    }
    .buttonStyle(.plain)
    .disabled(thread.sessionPath.isEmpty)
    .pointingHandCursor()
    .accessibilityLabel(Text("Open this session in its app"))
  }

  private var footer: some View {
    HStack {
      Button(action: onToggleKept) {
        Image(systemName: isKept ? "star.fill" : "star")
          .font(.system(size: 13))
          .foregroundColor(isKept ? TBDTokens.accent : .black.opacity(0.4))
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
      .accessibilityLabel(
        Text(isKept ? String(localized: "Unstar thread") : String(localized: "Star thread to keep"))
      )

      Spacer()

      Button(action: onToggleExpanded) {
        HStack(spacing: 4) {
          Text(isExpanded ? String(localized: "Collapse") : String(localized: "Expand"))
            .font(.custom("Switzer", size: 11.5))
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 9))
        }
        .foregroundColor(.black.opacity(0.4))
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if !isExpanded {
      collapsedContent
    } else {
      switch style {
      case .messenger: MessengerTurnsView(thread: thread)
      case .transcript: TranscriptTurnsView(thread: thread)
      case .brief: BriefTurnsView(thread: thread)
      case .milestones: MilestonesView(thread: thread)
      }
    }
  }

  private var collapsedContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 4) {
        Text(thread.firstPrompt)
          .font(.custom("Switzer", size: 13))
          .foregroundColor(.black.opacity(0.5))
          .lineLimit(2)
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundColor(.black.opacity(0.3))
      }

      Text(thread.latestOutcome.isEmpty ? thread.title : thread.latestOutcome)
        .font(.custom("Switzer", size: 15))
        .fontWeight(.semibold)
        .foregroundColor(.black.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)

      AgentStatusChipView(status: thread.status)
    }
  }
}

// MARK: - Style 1: Messenger

private struct MessengerTurnsView: View {
  let thread: AgentThread

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(thread.turns) { turn in
        if turn.role == .user {
          userBubble(turn)
        } else {
          agentText(turn)
        }
      }
    }
  }

  private func userBubble(_ turn: AgentTurn) -> some View {
    VStack(alignment: .trailing, spacing: 5) {
      if turn.highlight == .keyDecision {
        AgentHighlightPill(highlight: .keyDecision)
      }
      Text(turn.text)
        .font(.custom("Switzer", size: 13))
        .foregroundColor(TBDTokens.onPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(TBDTokens.fill)
        .overlay(
          RoundedRectangle(cornerRadius: TBDTokens.Radius.sm)
            .strokeBorder(TBDTokens.ink, lineWidth: TBDTokens.Stroke.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: TBDTokens.Radius.sm))
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.leading, 44)
  }

  private func agentText(_ turn: AgentTurn) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if turn.highlight == .keyInfo {
        AgentHighlightPill(highlight: .keyInfo)
      }
      if turn.highlight == .readyForReview {
        AgentHighlightPill(highlight: .readyForReview)
      }

      Text(turn.text)
        .font(.custom("Switzer", size: 13))
        .foregroundColor(.black.opacity(0.62))
        .fixedSize(horizontal: false, vertical: true)

      AgentTurnBulletsView(bullets: turn.bullets)
      AgentArtifactChipView(turn: turn)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.trailing, 44)
  }
}

// MARK: - Style 2: Transcript

private struct TranscriptTurnsView: View {
  let thread: AgentThread

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      Text(thread.title)
        .font(.custom("Switzer", size: 14))
        .fontWeight(.semibold)
        .foregroundColor(.black.opacity(0.85))
        .padding(.bottom, 3)

      ForEach(thread.turns) { turn in
        row(turn)
      }
    }
  }

  @ViewBuilder
  private func row(_ turn: AgentTurn) -> some View {
    let base = HStack(alignment: .top, spacing: 10) {
      Image(systemName: turn.role == .user ? "person.fill" : "sparkle")
        .font(.system(size: 10))
        .foregroundColor(.black.opacity(0.4))
        .frame(width: 14)
        .padding(.top, 2.5)

      VStack(alignment: .leading, spacing: 5) {
        Text(turn.text)
          .font(.custom("Switzer", size: 13))
          .foregroundColor(.black.opacity(0.68))
          .fixedSize(horizontal: false, vertical: true)
        AgentTurnBulletsView(bullets: turn.bullets)
        AgentArtifactChipView(turn: turn)
      }
    }

    switch turn.highlight {
    case .keyDecision:
      base
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AgentsPalette.keyDecisionBackground)
    case .readyForReview:
      base
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AgentsPalette.reviewBackground)
    case .keyInfo:
      base
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AgentsPalette.keyInfoBackground)
    case .none:
      base
    }
  }
}

// MARK: - Style 3: Brief

private struct BriefTurnsView: View {
  let thread: AgentThread

  private var agentTurns: [AgentTurn] {
    thread.turns.filter { $0.role == .agent }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      ForEach(agentTurns) { turn in
        VStack(alignment: .leading, spacing: 5) {
          Text(turn.text)
            .font(.custom("Switzer", size: 13))
            .fontWeight(.medium)
            .foregroundColor(.black.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
          AgentTurnBulletsView(bullets: turn.bullets)
          AgentArtifactChipView(turn: turn)
        }
      }
    }
  }
}

// MARK: - Style 4: Milestones

private struct MilestonesView: View {
  let thread: AgentThread

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(thread.firstPrompt)
        .font(.custom("Switzer", size: 13))
        .foregroundColor(.black.opacity(0.5))

      if !thread.milestoneTexts.isEmpty {
        VStack(alignment: .leading, spacing: 7) {
          ForEach(Array(thread.milestoneTexts.enumerated()), id: \.offset) { _, milestone in
            Text(milestone)
              .font(.custom("Switzer", size: 12))
              .foregroundColor(.black.opacity(0.45))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
          RoundedRectangle(cornerRadius: 1)
            .fill(Color.black.opacity(0.12))
            .frame(width: 2)
        }
      }

      Text(thread.latestOutcome.isEmpty ? thread.title : thread.latestOutcome)
        .font(.custom("Switzer", size: 15))
        .fontWeight(.semibold)
        .foregroundColor(.black.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - Shared pieces

struct AgentHighlightPill: View {
  let highlight: AgentTurnHighlight

  var body: some View {
    switch highlight {
    case .keyDecision:
      pill(
        text: String(localized: "Key decision"), showArrow: false,
        background: AgentsPalette.keyDecisionBackground,
        foreground: AgentsPalette.keyDecisionForeground)
    case .keyInfo:
      pill(
        text: String(localized: "Key info"), showArrow: false,
        background: AgentsPalette.keyInfoBackground,
        foreground: AgentsPalette.keyInfoForeground)
    case .readyForReview:
      pill(
        text: String(localized: "Ready for review"), showArrow: true,
        background: AgentsPalette.reviewBackground,
        foreground: AgentsPalette.reviewForeground)
    case .none:
      EmptyView()
    }
  }

  private func pill(text: String, showArrow: Bool, background: Color, foreground: Color)
    -> some View
  {
    HStack(spacing: 3) {
      Text(text)
        .font(.custom("Switzer", size: 10.5))
        .fontWeight(.medium)
      if showArrow {
        Image(systemName: "arrow.up.right")
          .font(.system(size: 8, weight: .semibold))
      }
    }
    .foregroundColor(foreground)
    .padding(.horizontal, 8)
    .padding(.vertical, 3.5)
    .background(background)
    .overlay(
      RoundedRectangle(cornerRadius: TBDTokens.Radius.xs)
        .strokeBorder(foreground.opacity(0.25), lineWidth: TBDTokens.Stroke.hairline)
    )
    .clipShape(RoundedRectangle(cornerRadius: TBDTokens.Radius.xs))
  }
}

struct AgentStatusChipView: View {
  let status: AgentThreadStatus

  var body: some View {
    Text(status.displayName)
      .font(.custom("Switzer", size: 10.5))
      .fontWeight(.medium)
      .foregroundColor(AgentsPalette.chipForeground(for: status))
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(AgentsPalette.chipBackground(for: status))
      .overlay(
        RoundedRectangle(cornerRadius: TBDTokens.Radius.xs)
          .strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline)
      )
      .clipShape(RoundedRectangle(cornerRadius: TBDTokens.Radius.xs))
  }
}

struct AgentTurnBulletsView: View {
  let bullets: [String]

  var body: some View {
    if !bullets.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
          HStack(alignment: .top, spacing: 6) {
            Text("•")
              .font(.custom("Switzer", size: 12))
              .foregroundColor(.black.opacity(0.35))
            Text(bullet)
              .font(.custom("Switzer", size: 12))
              .foregroundColor(.black.opacity(0.55))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.leading, 2)
    }
  }
}

struct AgentArtifactChipView: View {
  let turn: AgentTurn

  var body: some View {
    if let name = turn.artifactName, !name.isEmpty {
      Button {
        openArtifact()
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "doc.fill")
            .font(.system(size: 11))
            .foregroundColor(.black.opacity(0.75))
          Text(name)
            .font(.custom("Switzer", size: 12))
            .fontWeight(.medium)
            .foregroundColor(.black.opacity(0.75))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(TBDTokens.paper)
        .overlay(
          RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
            .strokeBorder(TBDTokens.border, lineWidth: TBDTokens.Stroke.hairline)
        )
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
  }

  private func openArtifact() {
    guard let path = turn.artifactPath, !path.isEmpty,
      FileManager.default.fileExists(atPath: path)
    else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }
}
