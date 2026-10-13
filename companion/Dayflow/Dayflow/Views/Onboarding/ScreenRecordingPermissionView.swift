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
        TBDKicker(String(localized: "Last step!"))

        Text("Permission")
          .font(TBDTokens.Typography.display)
          .tracking(TBDTokens.Typography.displayTracking)
          .foregroundColor(TBDColor.ink)

        Text("Tealbrick can help understand your day.")
          .font(TBDTokens.Typography.tag)
          .foregroundColor(TBDColor.muted)
          .fixedSize(horizontal: false, vertical: true)

        // Privacy info box
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shield.fill")
              .font(TBDFonts.symbol(14, .regular))
              .foregroundColor(TBDColor.tealInk)
            Text("Tealbrick is built to be private and secure.")
              .font(TBDTokens.Typography.control)
              .foregroundColor(TBDColor.ink)
              .fixedSize(horizontal: false, vertical: true)
          }

          Text(
            "Tealbrick stores all recordings locally on your Mac, and can process everything privately on your device using local AI models."
          )
          .font(TBDTokens.Typography.tag)
          .foregroundColor(TBDColor.inkSoft)

          Text("You are always in control — you can pause or turn off Tealbrick whenever you like.")
            .font(TBDTokens.Typography.tag)
            .foregroundColor(TBDColor.inkSoft)
        }
        .frame(maxWidth: 351 - 32, alignment: .leading)
        .tbdPanelTint(padding: 16)

        // State-based messaging
        Group {
          switch permissionState {
          case .notRequested:
            EmptyView()
          case .granted:
            TBDNotice(String(localized: "✓ Permission granted! Click Next to continue."), tone: .live)
          case .needsAction:
            TBDNotice(
              String(localized: "Turn on Screen Recording for Tealbrick, then quit and reopen the app to finish."),
              tone: .needsYou)
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
              }
            }
            .buttonStyle(TBDButtonStyle(.secondary))
            .disabled(isCheckingPermission)
          case .needsAction:
            HStack {
              HStack(spacing: 12) {
                Button(action: openSystemSettings) {
                  Text("Open System Settings")
                }
                .buttonStyle(TBDButtonStyle(.secondary))

                Button(action: quitAndReopen) {
                  Text("Quit and Reopen")
                }
                .buttonStyle(TBDButtonStyle(.quiet))
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
          .background(TBDColor.tile)
          .clipShape(TBDBrickShape())
          .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(.leading, metrics.leading)
    .padding(.trailing, metrics.trailing)
    .padding(.top, 30)
    .padding(.bottom, 40)

    // Navigation buttons — bottom right
    HStack(spacing: 15) {
      Button(action: onBack) {
        Text("Back")
      }
      .buttonStyle(TBDButtonStyle(.secondary, size: .large))
      .pointingHandCursor()

      Button(action: {
        if permissionState == .granted { onNext() }
      }) {
        HStack(spacing: 6) {
          Text("Next")
          Image(systemName: "chevron.right").font(TBDFonts.symbol(12, .bold))
        }
      }
      .buttonStyle(TBDButtonStyle(.primary, size: .large))
      .disabled(permissionState != .granted)
      .pointingHandCursor(enabled: permissionState == .granted)
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
