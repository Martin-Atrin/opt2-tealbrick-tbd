import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// Find bar for the transcript (v1 `TranscriptFindBar`): type to highlight matches, Return or the chevron for the next
/// one, Shift-Return for the previous, Esc clears the text and then closes the bar.
struct TBDTranscriptFindBar: View {
    @Binding var query: String
    @FocusState.Binding var isFocused: Bool
    let position: (current: Int, total: Int)?
    let hasQueryButNoMatches: Bool
    let onNext: () -> Void
    let onPrev: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: TBDTokens.Space.sm) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(TBDTokens.muted)
                .accessibilityHidden(true)
            TextField("Find in transcript", text: $query)
                .textFieldStyle(.plain).font(TBDTokens.Typography.body)
                .focused($isFocused)
                .frame(minWidth: 130, maxWidth: 200)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    onPrev()
                    return .handled
                }
                .onSubmit(onNext)
                .onKeyPress(.escape) {
                    if !query.isEmpty { query = "" } else { onClose() }
                    return .handled
                }
            counter
            Divider().frame(height: 16)
            navButton("chevron.up", label: "Previous match", help: "Previous match (⇧⌘G)", action: onPrev)
            navButton("chevron.down", label: "Next match", help: "Next match (⌘G)", action: onNext)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(TBDTokens.muted)
            }
            .buttonStyle(.plain).help("Close find (Esc)").accessibilityLabel("Close find")
        }
        .padding(.horizontal, TBDTokens.Space.md)
        .padding(.vertical, 8)
        .tbdFloating()
        .overlay(
            RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
                .strokeBorder(isFocused ? TBDTokens.accent : TBDTokens.border, lineWidth: isFocused ? TBDTokens.Stroke.bar : TBDTokens.Stroke.hairline)
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    private var counter: some View {
        ZStack(alignment: .trailing) {
            Text("00000 of 00000").hidden()
            if let position {
                Text("\(position.current) of \(position.total)")
            } else if hasQueryButNoMatches {
                Text("No results")
            }
        }
        .font(.system(size: 12).monospacedDigit()).foregroundStyle(TBDTokens.muted).fixedSize()
    }

    private func navButton(_ icon: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(position != nil ? TBDTokens.ink : TBDTokens.muted.opacity(0.5))
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(position == nil).help(help).accessibilityLabel(label)
    }
}

/// Highlighted text for find matches (v1 `TranscriptFindHighlight`): a quiet wash on each match, a stronger one and
/// bold on the current match. Ranges are UTF-16 offsets into `text`.
enum TBDTranscriptFindHighlight {
    static func attributed(_ text: String, ranges: [NSRange], current: NSRange?, baseFont: Font) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.font = baseFont
        for nsRange in ranges {
            guard let range = Range(nsRange, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            let isCurrent = nsRange == current
            attributed[lower..<upper].backgroundColor = TBDTokens.accent.opacity(isCurrent ? 0.55 : 0.22)
            if isCurrent { attributed[lower..<upper].font = baseFont.bold() }
        }
        return attributed
    }
}
