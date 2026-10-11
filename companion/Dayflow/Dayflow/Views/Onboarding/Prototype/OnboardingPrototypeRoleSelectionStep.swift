//
//  OnboardingPrototypeRoleSelectionStep.swift
//  Dayflow
//

import MacParakeet
import SwiftUI

struct OnboardingPrototypeRoleSelectionStep: View {
  let onContinue: (String) -> Void

  private let roles = [
    "Software Engineer", "Founder / Executive", "Designer", "Student", "Product Manager",
    "Data Scientist", "Other",
  ]
  @State private var selectedRole: String?
  @State private var otherText = ""

  private var resolvedRole: String? {
    guard let selectedRole else { return nil }
    if selectedRole == "Other" {
      return otherText.trimmingCharacters(in: .whitespaces).isEmpty
        ? nil : otherText.trimmingCharacters(in: .whitespaces)
    }
    return selectedRole
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: 39)

      Text("Help Tealbrick understand your work patterns better.")
        .font(.custom("Switzer-Medium", size: 40))
        .tracking(-1.2)
        .multilineTextAlignment(.center)
        .foregroundColor(Color(hex: "424242"))
        .lineSpacing(40 * 0.2)
        .frame(maxWidth: 708)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()
        .frame(height: 60)

      VStack(spacing: 24) {
        VStack(spacing: 4) {
          Text("What do you do for work?")
            .font(.custom("Switzer", size: 20))
            .foregroundColor(Color(hex: "634D42"))

          Text("This will help Tealbrick generate categories that are most helpful to you.")
            .font(.custom("Switzer", size: 20))
            .foregroundColor(Color(hex: "634D42"))
        }
        .multilineTextAlignment(.center)

        VStack(spacing: 8) {
          HStack(spacing: 8) {
            ForEach(roles.prefix(4), id: \.self) { role in
              roleChip(role)
            }
          }
          HStack(spacing: 8) {
            ForEach(roles.dropFirst(4), id: \.self) { role in
              roleChip(role)
            }
          }
        }
      }

      if selectedRole == "Other" {
        VStack(spacing: 16) {
          Text("Please specify")
            .font(.custom("Switzer", size: 20))
            .foregroundColor(Color(hex: "634D42"))

          TextField("", text: $otherText)
            .font(.custom("Switzer", size: 16))
            .foregroundColor(Color(hex: "634D42"))
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .frame(width: 353, height: 34)
            .background(Color.white.opacity(0.4))
            .overlay(
              RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
                .strokeBorder(Color(hex: "E4D3C2"), lineWidth: 1)
            )
        }
        .padding(.top, 32)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

      Spacer()

      DayflowSurfaceButton(
        action: {
          if let role = resolvedRole {
            onContinue(role)
          }
        },
        content: {
          Text("Continue")
            .font(.custom("Switzer", size: 16))
            .fontWeight(.medium)
        },
        background: TBDTokens.fill,
        foreground: TBDTokens.onPrimary,
        borderColor: TBDTokens.fill,
        cornerRadius: TBDTokens.Radius.base,
        horizontalPadding: 59,
        verticalPadding: 18,
        minWidth: 234,
        showOverlayStroke: false
      )
      .opacity(resolvedRole == nil ? 0.4 : 1.0)
      .allowsHitTesting(resolvedRole != nil)
      .animation(.easeInOut(duration: 0.2), value: resolvedRole)

      Spacer()
        .frame(height: 60)
    }
    .animation(.easeInOut(duration: 0.25), value: selectedRole == "Other")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func roleTitle(_ role: String) -> String {
    switch role {
    case "Software Engineer": return String(localized: "Software Engineer")
    case "Founder / Executive": return String(localized: "Founder / Executive")
    case "Designer": return String(localized: "Designer")
    case "Student": return String(localized: "Student")
    case "Product Manager": return String(localized: "Product Manager")
    case "Data Scientist": return String(localized: "Data Scientist")
    case "Other": return String(localized: "Other")
    default: return role
    }
  }

  private func roleChip(_ role: String) -> some View {
    let isSelected = selectedRole == role
    return Button {
      selectedRole = role
    } label: {
      Text(roleTitle(role))
        .font(.custom("Switzer", size: 16))
        .foregroundColor(Color(hex: "634D42"))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(
          isSelected
            ? Color(red: 1, green: 0.898, blue: 0.812).opacity(0.4)
            : Color.white.opacity(0.4)
        )
        .overlay(
          RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
            .strokeBorder(
              isSelected ? Color(hex: "FFCCA7") : Color(hex: "E4D3C2"),
              lineWidth: 1
            )
        )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}
