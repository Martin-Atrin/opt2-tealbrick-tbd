import SwiftUI
import AppKit
import TBDDesign
import TBDListening

/// Navigation owns visibility only. Capture services remain owned by the app lifecycle.
struct TBDWorkspaceView<Companion: View>: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage(DayflowAppearance.storageKey) private var appearance: DayflowAppearance = .system
  @AppStorage(TealbrickPalette.key) private var palette: TealbrickPalette = .teal
  @AppStorage("tbd.portalInvitationDismissed") private var invitationDismissed = false
  @ObservedObject private var account = TBDAccountCoordinator.shared
  @State private var settingsSection: String?
  @State private var selection: Section = .companion
  @StateObject private var chat = TBDChatRuntime.shared
  @StateObject private var listening = TBDListeningRuntime.shared
  private let companion: Companion

  init(@ViewBuilder companion: () -> Companion) {
    self.companion = companion()
  }

  /// Glass brick: slightly rounded rectangle, never a pill.
  static var brick: RoundedRectangle { RoundedRectangle(cornerRadius: TBDTokens.Radius.sm, style: .continuous) }

  private enum Section: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case companion = "Companion"
    case listening = "Listening"
    var id: String { rawValue }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Global navigation is liquid glass shaped as bricks (operator decisions 2026-09-27):
      // separate, breathable glass rounded-rectangles; content below uses the brick language.
      TBDGlassGroup(spacing: 12) {
        ForEach(Section.allCases.filter { $0 != .chat || account.signedIn }) { section in
          let selected = selection == section
          Button { settingsSection = nil; selection = section } label: {
            Text(section.rawValue)
              .font(.custom("Switzer", size: 13).weight(selected ? .semibold : .medium))
              .foregroundStyle(selected ? TBDTokens.ink : TBDTokens.muted)
              .padding(.horizontal, 22)
              .frame(minWidth: 112, minHeight: 34)
              .tbdGlass(TBDWorkspaceView.brick, selected: selected)
              .contentShape(TBDWorkspaceView.brick)
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected ? .isSelected : [])
          .accessibilityIdentifier("tbd.workspace." + section.rawValue.lowercased())
        }
      }
      .frame(maxWidth: .infinity)
      .onAppear { TBDTitleBarAction.install() }
      .overlay(alignment: .trailing) {
        TBDGlassGroup(spacing: 10) {
          Button {
            settingsSection = settingsSection == nil ? "account" : nil
          } label: {
            Image(systemName: "gearshape").font(.system(size: 14))
              .foregroundStyle(TBDTokens.ink).frame(width: 34, height: 34)
              .tbdGlass(TBDWorkspaceView.brick, selected: settingsSection != nil)
          }.buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
          Button {
            appearance = colorScheme == .dark ? .light : .dark
          } label: {
            Image(systemName: colorScheme == .dark ? "sun.max" : "moon")
              .font(.system(size: 14, weight: .medium))
              .foregroundStyle(TBDTokens.ink)
              .frame(width: 34, height: 34)
              .tbdGlass(TBDWorkspaceView.brick, selected: false)
          }
          .buttonStyle(.plain)
          .help(colorScheme == .dark ? "Switch to light mode" : "Switch to dark mode")
          .accessibilityLabel(colorScheme == .dark ? "Switch to light mode" : "Switch to dark mode")
          .accessibilityIdentifier("tbd.appearance.toggle")
        }
        .padding(.trailing, 18)
      }
      .padding(.top, 10)
      .padding(.bottom, 12)
      .background {
        // Soft brand light behind the glass so it has something to refract.
        LinearGradient(colors: [TBDTokens.accent.opacity(0.10), TBDTokens.fill.opacity(0.04), .clear],
                       startPoint: .top, endPoint: .bottom)
          .overlay(RadialGradient(colors: [TBDTokens.accent.opacity(0.12), .clear], center: .top, startRadius: 0, endRadius: 360))
          .allowsHitTesting(false)
      }
      if account.hasCheckedSession && !account.signedIn && !invitationDismissed && settingsSection == nil {
        HStack(spacing: 12) {
          Text("Connect to Portal to use Chat and remote agents. Companion and Listening work without an account.")
            .font(.custom("Switzer", size: 12)).foregroundStyle(theme.textSecondary)
          Spacer()
          Button("Sign in") { settingsSection = "account" }
          Button("Not now") { invitationDismissed = true }
        }.padding(.horizontal, 20).padding(.vertical, 8)
      }
      ZStack {
        // Retain the existing view tree and its navigation state across tab switches.
        companion
          .opacity(selection == .companion && settingsSection == nil ? 1 : 0)
          .allowsHitTesting(selection == .companion && settingsSection == nil)
          .disabled(selection != .companion || settingsSection != nil)
          .accessibilityHidden(selection != .companion || settingsSection != nil)

        if account.signedIn {
        ZStack {
          TBDChatView(palette: palette.rawValue)
          if !chat.status.isEmpty { pending("Chat", detail: chat.status) }
          if !chat.notice.isEmpty {
            Text(chat.notice)
              .font(.callout).foregroundStyle(theme.textPrimary)
              .padding(.horizontal, 14).padding(.vertical, 8)
              .background(.regularMaterial, in: Capsule())
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
              .padding(.top, 10)
              .allowsHitTesting(false)
          }
        }
        .opacity(selection == .chat && settingsSection == nil ? 1 : 0)
        .allowsHitTesting(selection == .chat && settingsSection == nil)
        .disabled(selection != .chat || settingsSection != nil)
        .accessibilityHidden(selection != .chat || settingsSection != nil)
        }
        listening.content()
          .opacity(selection == .listening && settingsSection == nil ? 1 : 0)
          .allowsHitTesting(selection == .listening && settingsSection == nil)
          .disabled(selection != .listening || settingsSection != nil)
          .accessibilityHidden(selection != .listening || settingsSection != nil)

        if let section = settingsSection {
          SettingsView(initialSection: section)
            .id(section)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TBDDesign.canvas)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .ignoresSafeArea(.container, edges: .top)
    .font(.custom("Switzer", size: 14))
    .tint(Color(hex: palette.hex))
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("tbdOpenSettings"))) { note in
      settingsSection = note.object as? String ?? "account"
    }
    .onChange(of: account.signedIn) { _, signedIn in
      if !signedIn && selection == .chat { selection = .companion }
    }
    .task {
      listening.activate = { selection = .listening }
      // "Save to Knowledge": through the Chat helper as TBD's own agent; needs a signed-in person.
      listening.saveToKnowledge = { request, status in
        guard TBDAccountCoordinator.shared.signedIn else { throw TBDKnowledgeError.signIn }
        return try await TBDChatRuntime.shared.knowledgeSave(request, onStatus: status)
      }
      listening.start()
      await account.refresh()
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        await account.refresh()
      }
    }
  }

  private func pending(_ title: String, detail: String) -> some View {
    VStack(spacing: 12) {
      Text(title).font(.title2).foregroundStyle(theme.textPrimary)
      Text(detail).foregroundStyle(theme.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private extension View {
  /// Liquid Glass on macOS 26+, material glass fallback on earlier systems.
  /// A specular top edge and soft lift keep the glass legible on the flat canvas.
  @ViewBuilder
  func tbdGlass<S: Shape>(_ shape: S, selected: Bool) -> some View {
    let edge = shape.stroke(
      LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.15), .white.opacity(0.35)],
                     startPoint: .top, endPoint: .bottom),
      lineWidth: 0.8)
    if #available(macOS 26.0, *) {
      self.glassEffect(selected ? .clear.tint(TBDTokens.accent.opacity(0.28)).interactive() : .clear.interactive(), in: shape)
        .overlay(edge)
        .shadow(color: TBDTokens.ink.opacity(0.10), radius: 8, y: 3)
    } else {
      self.background(.ultraThinMaterial, in: shape)
        .overlay(shape.fill(selected ? TBDTokens.accent.opacity(0.14) : .white.opacity(0.08)))
        .overlay(edge)
        .shadow(color: TBDTokens.ink.opacity(0.10), radius: 8, y: 3)
    }
  }
}

@MainActor
enum TBDTitleBarAction {
  /// Height of the navbar strip that acts as the title bar (top padding + glass + bottom padding).
  static let stripHeight: CGFloat = 56
  private static var monitor: Any?

  /// AppKit's hidden title bar swallows clicks in the top strip before SwiftUI sees them,
  /// and SwiftUI turns the native zoom into a no-op. Catch title-bar double-clicks at the
  /// window level, outside the traffic lights, the section tabs and the trailing buttons.
  static func install() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
      guard event.clickCount == 2, let window = event.window, window.identifier?.rawValue.contains("main") == true || window.title == "TBD",
            let content = window.contentView else { return event }
      let p = event.locationInWindow, width = content.bounds.width
      let inStrip = p.y >= content.bounds.height - stripHeight
      let onTrafficLights = p.x < 80
      let onTabs = abs(p.x - width / 2) < 200
      let onTrailingButtons = p.x > width - 110
      guard inStrip, !onTrafficLights, !onTabs, !onTrailingButtons else { return event }
      perform(window)
      return nil
    }
  }

  static func perform(_ target: NSWindow? = nil) {
    guard let window = target ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize": window.miniaturize(nil)
    case "None": break
    default: toggleFill(window)  // "Maximize"/"Fill"/unset: fill the screen, not full-screen mode.
    }
  }

  /// SwiftUI windows zoom to their content's ideal size (a no-op here), so fill the
  /// screen's visible frame directly and restore the previous frame on the next double-click.
  private static var restoreFrames: [ObjectIdentifier: NSRect] = [:]
  private static func toggleFill(_ window: NSWindow) {
    guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
    let key = ObjectIdentifier(window)
    let filled = abs(window.frame.width - visible.width) < 2 && abs(window.frame.height - visible.height) < 2
    if filled, let previous = restoreFrames[key] {
      window.setFrame(previous, display: true, animate: true)
      restoreFrames[key] = nil
    } else {
      restoreFrames[key] = window.frame
      window.setFrame(visible, display: true, animate: true)
    }
  }
}

/// Groups glass shapes so they blend and morph together on macOS 26+.
private struct TBDGlassGroup<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: () -> Content
  var body: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) { HStack(spacing: spacing) { content() } }
    } else {
      HStack(spacing: spacing) { content() }
    }
  }
}
