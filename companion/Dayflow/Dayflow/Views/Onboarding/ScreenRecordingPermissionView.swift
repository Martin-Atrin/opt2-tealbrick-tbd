//
//  ScreenRecordingPermissionView.swift
//  Dayflow
//
//  Screen recording permission request using idiomatic ScreenCaptureKit approach
//

import AppKit
import CoreGraphics
import TBDDesign
import ScreenCaptureKit
import SwiftUI

private struct LeftColumnSizeKey: PreferenceKey {
  static var defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    value = nextValue()
  }
}

struct ScreenRecordingPermissionView: View {
  var onBack: () -> Void
  var onNext: () -> Void

  @State private var permissionState: PermissionState = .notRequested
  @State private var isCheckingPermission = false
  @State private var initiatedFlow = false
  @State private var leftColumnSize: CGSize = .zero

  enum PermissionState {
    case notRequested
    case granted
    case needsAction  // requested or settings opened, awaiting quit & reopen / toggle
  }

  private let brownAccent = Color(hex: "492304")
  private let privacyTextColor = Color(hex: "89380E")

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .bottomTrailing) {
        content(size: geo.size)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onPreferenceChange(LeftColumnSizeKey.self) { leftColumnSize = $0 }
    }
    .onAppear {
      // If already granted, mark as granted; otherwise start in notRequested
      if CGPreflightScreenCaptureAccess() {
        permissionState = .granted
        Task { @MainActor in AppDelegate.allowTermination = false }
      } else {
        permissionState = .notRequested
        Task { @MainActor in AppDelegate.allowTermination = true }
      }
    }
    // Re-check when app becomes active again (e.g., returning from System Settings)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      // Only transition to granted here; avoid flipping notChecked to denied automatically
      if CGPreflightScreenCaptureAccess() {
        permissionState = .granted
        Task { @MainActor in AppDelegate.allowTermination = false }
      }
    }
    .onDisappear {
      Task { @MainActor in AppDelegate.allowTermination = false }
    }
  }

  // Margins and column gap scale with window size (12 : 7 : 11 ratio from the design mock);
  // the image never grows taller than the left column, extra space flows into the gaps
  private func layoutMetrics(size: CGSize) -> (
    leading: CGFloat, gap: CGFloat, trailing: CGFloat, imageWidth: CGFloat, imageHeight: CGFloat
  ) {
    let aspect: CGFloat = {
      if let img = NSImage(named: "ScreenRecordingPermissions"), img.size.height > 0 {
        return img.size.width / img.size.height
      }
      return 4.0 / 3.0
    }()
    let leftW = leftColumnSize.width > 0 ? leftColumnSize.width : min(374, size.width * 0.4)
    var imgW = max(0, size.width * 0.70 - leftW)
    var imgH = imgW / aspect
    // Match the left column's height (fallback ≈ its natural height before measurement lands)
    let columnHeight = leftColumnSize.height > 0 ? leftColumnSize.height : 300
    let heightCap = min(max(0, size.height - 70), columnHeight)
    if imgH > heightCap {
      imgH = heightCap
      imgW = imgH * aspect
    }
    let free = max(0, size.width - leftW - imgW)
    return (free * 12 / 30, free * 7 / 30, free * 11 / 30, imgW, imgH)
  }

  @ViewBuilder
  private func content(size: CGSize) -> some View {
    let metrics = layoutMetrics(size: size)
    HStack(alignment: .center, spacing: metrics.gap) {
      // Left side — text and controls
      VStack(alignment: .leading, spacing: 10) {
        Text("Last step!")
          .font(.custom("Switzer-Bold", size: 16))
          .foregroundColor(Color(hex: "F96E00"))

        Text("Permission")
          .font(.custom("Switzer-Medium", size: 28))
          .foregroundColor(.black)

        Text("Tealbrick can help understand your day.")
          .font(.custom("Switzer-Medium", size: 14))
          .foregroundColor(Color(hex: "5B5B5B"))
          .fixedSize(horizontal: false, vertical: true)

        // Privacy info box
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shield.fill")
              .font(.system(size: 14))
              .foregroundColor(privacyTextColor)
            Text("Tealbrick is built to be private and secure.")
              .font(.custom("Switzer-Bold", size: 14))
              .foregroundColor(privacyTextColor)
              .fixedSize(horizontal: false, vertical: true)
          }

          Text(
            "Tealbrick stores all recordings locally on your Mac, and can process everything privately on your device using local AI models."
          )
          .font(.custom("Switzer-Medium", size: 14))
          .foregroundColor(privacyTextColor)

          Text("You are always in control — you can pause or turn off Tealbrick whenever you like.")
            .font(.custom("Switzer-Medium", size: 14))
            .foregroundColor(privacyTextColor)
        }
        .padding(16)
        .frame(maxWidth: 351, alignment: .leading)
        .background(Color.white.opacity(0.3))
        .overlay(
          RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
            .stroke(Color(red: 0.8, green: 0.278, blue: 0).opacity(0.15), lineWidth: TBDTokens.Stroke.hairline)
        )

        // State-based messaging
        Group {
          switch permissionState {
          case .notRequested:
            EmptyView()
          case .granted:
            Text("✓ Permission granted! Click Next to continue.")
              .font(.custom("Switzer", size: 14))
              .foregroundColor(.green)
          case .needsAction:
            Text("Turn on Screen Recording for Tealbrick, then quit and reopen the app to finish.")
              .font(.custom("Switzer", size: 14))
              .foregroundColor(.orange)
          }
        }

        // Action buttons
        Group {
          switch permissionState {
          case .notRequested:
            Button(action: requestPermission) {
              HStack(spacing: 6) {
                if isCheckingPermission {
                  ProgressView()
                    .scaleEffect(0.7)
                    .progressViewStyle(CircularProgressViewStyle())
                }
                Text(
                  isCheckingPermission
                    ? String(localized: "Checking...") : String(localized: "Open System Settings")
                )
                .font(.custom("Switzer-Semibold", size: 12))
                .tracking(-0.48)
                .foregroundColor(brownAccent)
              }
              .padding(.horizontal, 12)
              .frame(height: 36)
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).fill(Color(hex: "FFC9A8")))
            .disabled(isCheckingPermission)
          case .needsAction:
            HStack {
              HStack(spacing: 12) {
                Button(action: openSystemSettings) {
                  Text("Open System Settings")
                    .font(.custom("Switzer-Semibold", size: 12))
                    .tracking(-0.48)
                    .foregroundColor(brownAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).fill(Color(hex: "FFC9A8")))

                Button(action: quitAndReopen) {
                  Text("Quit and Reopen")
                    .font(.custom("Switzer-Semibold", size: 12))
                    .tracking(-0.48)
                    .foregroundColor(brownAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: TBDTokens.Radius.base).fill(Color.white.opacity(0.69)))
                .overlay(
                  RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
                    .strokeBorder(Color(hex: "D9D9D9"), lineWidth: TBDTokens.Stroke.hairline)
                )
              }
            }
          case .granted:
            EmptyView()
          }
        }
      }
      .frame(maxWidth: 374)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: LeftColumnSizeKey.self, value: proxy.size)
        }
      )

      // Right side - image
      if let image = NSImage(named: "ScreenRecordingPermissions") {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: metrics.imageWidth, height: metrics.imageHeight)
          .background(Color(hex: "FCFCFC"))
          .overlay(
            RoundedRectangle(cornerRadius: TBDTokens.Radius.base)
              .strokeBorder(Color(hex: "F0F0F0"), lineWidth: TBDTokens.Stroke.hairline)
          )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(.leading, metrics.leading)
    .padding(.trailing, metrics.trailing)
    .padding(.top, 30)
    .padding(.bottom, 40)

    // Navigation buttons — bottom right
    HStack(spacing: 15) {
      DayflowSurfaceButton(
        action: onBack,
        content: { Text("Back").font(.custom("Switzer-Medium", size: 14)).tracking(-0.48) },
        background: .white,
        foreground: Color(hex: "B6B6B6"),
        borderColor: Color(hex: "B6B6B6"),
        cornerRadius: TBDTokens.Radius.base,
        horizontalPadding: 32,
        verticalPadding: 0,
        fixedHeight: 44,
        showShadow: false
      )
      DayflowSurfaceButton(
        action: {
          if permissionState == .granted { onNext() }
        },
        content: {
          HStack(spacing: 6) {
            Text("Next").font(.custom("Switzer-Medium", size: 14)).tracking(-0.48)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
          }
          .padding(.leading, 4)
        },
        background: permissionState == .granted
          ? TBDTokens.fill
          : TBDTokens.fill.opacity(0.3),
        foreground: TBDTokens.onPrimary,
        borderColor: TBDTokens.fill,
        cornerRadius: TBDTokens.Radius.base,
        horizontalPadding: 32,
        verticalPadding: 0,
        fixedHeight: 44,
        showOverlayStroke: false
      )
      .disabled(permissionState != .granted)
    }
    .padding(.trailing, 60)
    .padding(.bottom, 40)
  }

  private func requestPermission() {
    guard !isCheckingPermission else { return }
    isCheckingPermission = true
    initiatedFlow = true

    // This will prompt and register the app with TCC; may return false
    _ = CGRequestScreenCaptureAccess()
    if CGPreflightScreenCaptureAccess() {
      permissionState = .granted
      Task { @MainActor in AppDelegate.allowTermination = false }
    } else {
      permissionState = .needsAction
      Task { @MainActor in AppDelegate.allowTermination = true }
    }
    isCheckingPermission = false
  }

  private func openSystemSettings() {
    initiatedFlow = true
    Task { @MainActor in AppDelegate.allowTermination = true }
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    {
      _ = NSWorkspace.shared.open(url)
    }
    // Move to needsAction so we show Quit & Reopen guidance
    if permissionState != .granted { permissionState = .needsAction }
  }

  private func quitAndReopen() {
    Task { @MainActor in
      AppDelegate.allowTermination = true
      NSApp.terminate(nil)
    }
  }
}
