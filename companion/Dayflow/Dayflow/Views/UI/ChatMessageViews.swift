import AppKit
import Charts
import SwiftUI
import MacParakeet

// MARK: - Message Bubble

struct MessageBubble: View {
  @Environment(\.dayflowTheme) private var theme

  let message: ChatMessage

  var body: some View {
    switch message.role {
    case .user:
      userBubble
    case .assistant:
      assistantBubble
    case .toolCall:
      ToolCallBubble(message: message)
    }
  }

  var userBubble: some View {
    HStack {
      Spacer(minLength: 60)
      // Brick chat bubble: user gets `fill` background, radius 3, 1pt ink border.
      Text(message.content)
        .font(.custom("Switzer", size: 13).weight(.medium))
        .foregroundColor(TBDTokens.onPrimary)
        .textSelection(.enabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(TBDTokens.fill)
        .clipShape(RoundedRectangle(cornerRadius: TBDTokens.Radius.sm, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: TBDTokens.Radius.sm, style: .continuous)
            .strokeBorder(TBDTokens.ink, lineWidth: TBDTokens.Stroke.hairline)
        )
    }
  }

  var assistantBubble: some View {
    let blocks = ChatContentParser.blocks(from: message.content)
    // Brick chat bubble: agent messages get no bubble — plain text, no fill/border.
    return HStack {
      VStack(alignment: .leading, spacing: 10) {
        // Positional identity: while a reply streams in, block N stays block N,
        // so SwiftUI updates content in place instead of rebuilding every block
        // (the parser mints fresh UUIDs on each parse).
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
          switch block {
          case .text(_, let content):
            ChatMarkdownContentView(content: content)
          case .chart(let spec):
            ChatChartBlockView(spec: spec)
          }
        }
      }
      .contextMenu {
        Button("Copy") {
          copyAssistantMessageToPasteboard()
        }
      }
      .environment(
        \.openURL,
        OpenURLAction { url in
          handleAssistantLinkTap(url)
        })
      Spacer(minLength: 60)
    }
  }

  func handleAssistantLinkTap(_ url: URL) -> OpenURLAction.Result {
    guard let externalURL = normalizedExternalURL(from: url) else {
      print("[ChatView] Blocked unsupported URL: \(url.absoluteString)")
      return .discarded
    }

    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open(externalURL, configuration: configuration) { _, error in
      if let error {
        print(
          "[ChatView] Failed opening URL \(externalURL.absoluteString): \(error.localizedDescription)"
        )
      }
    }
    return .handled
  }

  func normalizedExternalURL(from rawURL: URL) -> URL? {
    if let scheme = rawURL.scheme?.lowercased() {
      switch scheme {
      case "http", "https", "mailto":
        return rawURL
      default:
        return nil
      }
    }

    let trimmed = rawURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let prefixed =
      trimmed.hasPrefix("//")
      ? "https:\(trimmed)"
      : "https://\(trimmed)"

    guard let normalized = URL(string: prefixed),
      let scheme = normalized.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = normalized.host,
      !host.isEmpty
    else {
      return nil
    }

    return normalized
  }

  func copyAssistantMessageToPasteboard() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(message.content, forType: .string)
  }
}

struct ChatFeedbackTarget: Identifiable {
  let messageID: UUID
  let content: String
  let direction: TimelineRatingDirection

  var id: UUID { messageID }

  var message: ChatMessage {
    ChatMessage(id: messageID, role: .assistant, content: content)
  }
}

struct ChatMessageRow: View {
  let message: ChatMessage
  let showsAssistantFooter: Bool
  let selectedDirection: TimelineRatingDirection?
  let showsThanks: Bool
  let onCopy: () -> Void
  let onRate: (TimelineRatingDirection) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      MessageBubble(message: message)

      if showsAssistantFooter {
        HStack(spacing: 0) {
          AssistantMessageFeedbackRow(
            selectedDirection: selectedDirection,
            showsThanks: showsThanks,
            onCopy: onCopy,
            onRate: onRate
          )
          .padding(.leading, 10)

          Spacer(minLength: 60)
        }
      }
    }
  }
}

struct AssistantMessageFeedbackRow: View {
  @Environment(\.dayflowTheme) private var theme

  let selectedDirection: TimelineRatingDirection?
  let showsThanks: Bool
  let onCopy: () -> Void
  let onRate: (TimelineRatingDirection) -> Void

  @Environment(\.accessibilityReduceMotion) var reduceMotion

  var thanksTransition: AnyTransition {
    if reduceMotion {
      return .opacity
    }
    return .opacity.combined(with: .move(edge: .leading))
  }

  var body: some View {
    HStack(spacing: 8) {
      AssistantMessageIconButton(
        systemName: "doc.on.doc",
        accessibilityLabel: String(localized: "Copy answer"),
        action: onCopy
      )

      ThumbRatingButtons(selectedDirection: selectedDirection) { direction in
        onRate(direction)
      }

      if showsThanks {
        Text("Thanks")
          .font(.custom("Switzer", size: 11).weight(.semibold))
          .foregroundColor(theme.textSecondary)
          .transition(thanksTransition)
      }
    }
    .padding(.vertical, 2)
  }
}

struct AssistantMessageIconButton: View {
  @Environment(\.dayflowTheme) private var theme

  let systemName: String
  let accessibilityLabel: String
  let action: () -> Void

  @State var isHovered = false
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  var hoverAnimation: Animation {
    if reduceMotion {
      return .easeOut(duration: 0.01)
    }
    return .easeOut(duration: 0.14)
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(theme.textMuted)
        .frame(width: 22, height: 22)
        .background(
          RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
            .fill(isHovered ? theme.summaryCardFill : Color.clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
            .strokeBorder(theme.summaryCardBorder, lineWidth: isHovered ? TBDTokens.Stroke.hairline : 0)
        )
    }
    .buttonStyle(.plain)
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .accessibilityLabel(Text(accessibilityLabel))
    .onHover { hovering in
      withAnimation(hoverAnimation) {
        isHovered = hovering
      }
    }
  }
}
