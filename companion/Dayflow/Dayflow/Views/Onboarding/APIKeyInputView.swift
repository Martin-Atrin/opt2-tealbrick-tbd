//
//  APIKeyInputView.swift
//  Dayflow
//
//  API key input component for Gemini setup
//

import TBDDesign
import SwiftUI

struct APIKeyInputView: View {
  @Binding var apiKey: String
  let title: String
  let subtitle: String
  let placeholder: String
  let onValidate: (String) -> Bool

  @State private var showPassword = false
  @State private var validationState: ValidationState = .none
  @FocusState private var isFocused: Bool

  enum ValidationState {
    case none
    case valid
    case invalid
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title)
        .font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightLabel))
        .foregroundColor(TBDColor.ink)

      Text(subtitle)
        .font(TBDTokens.Typography.hint)
        .foregroundColor(TBDColor.muted)

      // Input field container
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
          Group {
            if showPassword {
              TextField(placeholder, text: $apiKey)
                .textFieldStyle(.plain)
            } else {
              SecureField(placeholder, text: $apiKey)
                .textFieldStyle(.plain)
            }
          }
          .font(TBDFonts.mono(13))
          .foregroundColor(TBDColor.fieldOn)
          .focused($isFocused)
          .onChange(of: apiKey) { _, newValue in
            let cleaned = cleanedAPIKey(newValue)
            guard cleaned == newValue else {
              apiKey = cleaned
              return
            }
            validateKey(cleaned)
          }

          Button(action: { showPassword.toggle() }) {
            Image(systemName: showPassword ? "eye.slash" : "eye")
              .font(TBDFonts.symbol(14, .bold))
              .frame(minWidth: 36, minHeight: 36)
              .contentShape(Rectangle())
          }
          .buttonStyle(TBDButtonStyle(.icon))
          .pointingHandCursor()

          // Validation indicator
          if validationState != .none {
            Image(
              systemName: validationState == .valid ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .font(TBDTokens.Typography.body)
            .foregroundColor(validationState == .valid ? TBDColor.tealInk : TBDColor.brickInk)
            .transition(.scale.combined(with: .opacity))
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(TBDColor.fieldFill, in: TBDBrickShape())
        .overlay(
          TBDBrickShape()
            .strokeBorder(borderColor, lineWidth: validationState == .invalid ? 2 : TBDKit.hair)
        )
        .tbdFocusRing(isFocused, offset: TBDKit.focusOffsetTight)

        // Validation message
        if validationState == .invalid {
          Text("API key should be more than 10 characters")
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
            .foregroundColor(TBDColor.brickInk)
            .transition(.opacity)
        }
      }
      .animation(TBDMotion.quick, value: validationState)

      // Help text
      HStack(spacing: 4) {
        Image(systemName: "lock.shield.fill")
          .font(TBDFonts.symbol(12, .regular))
          .foregroundColor(TBDColor.tealInk)

        Text(
          "Your API key is encrypted and stored in your macOS Keychain - never uploaded anywhere"
        )
        .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
        .foregroundColor(TBDColor.muted)
      }
    }
  }

  private var borderColor: Color {
    validationState == .invalid ? TBDColor.fieldInvalidEdge : TBDColor.fieldEdge
  }

  private func validateKey(_ key: String) {
    guard !key.isEmpty else {
      validationState = .none
      return
    }

    withAnimation(TBDMotion.quick) {
      validationState = onValidate(key) ? .valid : .invalid
    }
  }

  private func cleanedAPIKey(_ key: String) -> String {
    key.components(separatedBy: .whitespacesAndNewlines).joined()
  }
}
