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
            Image(systemName: "magnifyingglass").font(TBDFonts.symbol(12, TBDKit.weightNav)).foregroundStyle(TBDColor.muted)
                .accessibilityHidden(true)
            TextField("Find in transcript", text: $query)
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
                .tbdField(focused: isFocused)
            counter
            Rectangle().fill(TBDColor.line).frame(width: TBDKit.hair, height: 16)
            navButton("chevron.up", label: "Previous match", help: "Previous match (⇧⌘G)", action: onPrev)
            navButton("chevron.down", label: "Next match", help: "Next match (⌘G)", action: onNext)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(TBDFonts.symbol(12, TBDKit.weightBody))
            }
            .buttonStyle(TBDButtonStyle(.icon)).help("Close find (Esc)").accessibilityLabel("Close find")
        }
        .padding(.horizontal, TBDTokens.Space.sm)
        .padding(.vertical, TBDTokens.Space.sm)
        .tbdFloating()
        .contentShape(TBDBrickShape())
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
        .font(TBDTokens.Typography.hint.monospacedDigit()).foregroundStyle(TBDColor.muted).fixedSize()
    }

    private func navButton(_ icon: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(TBDFonts.symbol(12, TBDKit.weightNav))
        }
        .buttonStyle(TBDButtonStyle(.icon)).disabled(position == nil).help(help).accessibilityLabel(label)
    }
}

/// Highlighted text for find matches (v1 `TranscriptFindHighlight`): the selection colour on each match; the current
/// match is a teal wash, bold, with a tealInk edge. Ranges are UTF-16 offsets into `text`.
enum TBDTranscriptFindHighlight {
    static func attributed(_ text: String, ranges: [NSRange], current: NSRange?, baseFont: Font) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.font = baseFont
        for nsRange in ranges {
            guard let range = Range(nsRange, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            let isCurrent = nsRange == current
            // Matches sit on the kit selection colour. The current match is a teal wash, bold, with a tealInk edge
            // (a text run can only take an underline, so the edge is the underline).
            attributed[lower..<upper].backgroundColor = isCurrent ? TBDColor.tealWash : TBDColor.selection
            if isCurrent {
                attributed[lower..<upper].font = baseFont.bold()
                attributed[lower..<upper].underlineStyle = Text.LineStyle(pattern: .solid, color: TBDColor.tealInk)
            }
        }
        return attributed
    }
}
