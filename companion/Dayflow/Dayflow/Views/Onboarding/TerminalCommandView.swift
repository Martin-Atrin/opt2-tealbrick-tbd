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
        .font(.custom("Switzer", size: 16))
        .fontWeight(.semibold)
        .foregroundColor(.black.opacity(0.9))

      Text(subtitle)
        .font(.custom("Switzer", size: 14))
        .foregroundColor(.black.opacity(0.6))

      // Command block with trailing copy button (overlay for tight right alignment)
      ZStack(alignment: .leading) {
        // Command text area
        Text(command)
          .font(.custom("JetBrainsMono-Regular", size: 13))
          .foregroundColor(.black.opacity(0.85))
          .textSelection(.enabled)
          .padding(.horizontal, 16)
          .padding(.vertical, 14)
          .padding(.trailing, 120)  // reserve space so text doesn't sit under the button
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .overlay(alignment: .trailing) {
        DayflowSurfaceButton(
          action: copyCommand,
          content: {
            HStack(spacing: 6) {
              Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
              Text(isCopied ? String(localized: "Copied") : String(localized: "Copy"))
                .font(.custom("Switzer", size: 13))
                .fontWeight(.medium)
            }
            .foregroundColor(
              isCopied ? Color(red: 0.34, green: 1, blue: 0.45) : .black.opacity(0.75))
          },
          background: Color.white.opacity(0.93),
          foreground: .black,
          borderColor: Color.black.opacity(0.12),
          cornerRadius: TBDTokens.Radius.base,
          horizontalPadding: 14,
          verticalPadding: 10,
          showShadow: false
        )
        .padding(.trailing, 6)
        .padding(.vertical, 6)
      }
      .background(Color(hex: "F8F9FA"))
      .overlay(
        RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
          .stroke(Color.black.opacity(0.08), lineWidth: 1)
      )
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
