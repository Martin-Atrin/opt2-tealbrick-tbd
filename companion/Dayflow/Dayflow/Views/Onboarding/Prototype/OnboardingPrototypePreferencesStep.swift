//
//  OnboardingPrototypePreferencesStep.swift
//  Dayflow
//

import SwiftUI
import MacParakeet

// MARK: - Preferences Step

struct OnboardingPrototypePreferencesStep: View {
  let onContinue: (Bool) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Spacer()

      VStack(spacing: 24) {
        Text("Do you have a paid ChatGPT or Claude account?")
          .font(.custom("Switzer", size: 20))
          .foregroundColor(Color(hex: "89380E"))
          .multilineTextAlignment(.center)

        HStack(spacing: 8) {
          ForEach(["Yes", "No"], id: \.self) { option in
            Button {
              onContinue(option == "Yes")
            } label: {
              Text(option == "Yes" ? String(localized: "Yes") : String(localized: "No"))
                .font(.custom("Switzer", size: 16))
                .foregroundColor(Color(hex: "492304"))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.4))
                .overlay(
                  RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
                    .strokeBorder(Color(hex: "E4D3C2"), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
          }
        }
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
