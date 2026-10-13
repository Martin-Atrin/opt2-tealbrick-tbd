//
//  TerminalCommandView.swift
//  Dayflow
//
//  Terminal command display with copy functionality
//

import AppKit
import SwiftUI
import TBDDesign

struct TerminalCommandView: View {
  let title: String
  let subtitle: String
  let command: String

  @State private var isCopied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightLabel))
        .foregroundColor(TBDColor.ink)

      Text(subtitle)
        .font(TBDTokens.Typography.hint)
        .foregroundColor(TBDColor.muted)

      // Command block with trailing copy button (overlay for tight right alignment)
      ZStack(alignment: .leading) {
        // Command text area
        Text(command)
          .font(TBDFonts.mono(13))
          .foregroundColor(TBDColor.ink)
          .textSelection(.enabled)
          .padding(.horizontal, 16)
          .padding(.vertical, 14)
          .padding(.trailing, 120)  // reserve space so text doesn't sit under the button
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .overlay(alignment: .trailing) {
        Button(action: copyCommand) {
          HStack(spacing: 6) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
              .font(TBDFonts.symbol(12, .bold))
            Text(isCopied ? String(localized: "Copied") : String(localized: "Copy"))
          }
          .foregroundColor(isCopied ? TBDColor.tealInk : TBDColor.ink)
        }
        .buttonStyle(TBDButtonStyle(.secondary))
        .padding(.trailing, 6)
        .padding(.vertical, 6)
      }
      .background(TBDColor.plate, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
    }
  }

  private func copyCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)

    // Track copy (without sending command content)

    withAnimation(TBDMotion.quick) {
      isCopied = true
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      withAnimation(TBDMotion.quick) {
        isCopied = false
      }
    }
  }
}
