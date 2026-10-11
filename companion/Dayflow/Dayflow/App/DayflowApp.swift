//
//  DayflowApp.swift
//  Dayflow
//

import Sparkle
import SwiftUI

struct AppRootView: View {
  @AppStorage("didOnboard") private var didOnboard = false
  @EnvironmentObject private var categoryStore: CategoryStore
  @Binding var isShowingGitHubStarPrompt: Bool
  @State private var whatsNewNote: ReleaseNote? = nil
  @State private var activeWhatsNewVersion: String? = nil
  @State private var shouldMarkWhatsNewSeen = false
  @State private var goalFlowPresentation: DayGoalFlowPresentation? = nil

  var body: some View {
    ZStack {
      TBDWorkspaceView {
        Group {
          if didOnboard { MainView(goalFlowPresentation: $goalFlowPresentation) }
          else { TBDCompanionSetup() }
        }
        .environmentObject(AppState.shared)
        .environmentObject(categoryStore)
      }

      goalFlowOverlay
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onReceive(NotificationCenter.default.publisher(for: .showWhatsNew)) { _ in
      NotificationCenter.default.post(name: Notification.Name("tbdOpenSettings"), object: "about")
    }
    .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) { _ in
      // Upstream promotion is not part of TBD.
    }
    .onChange(of: whatsNewNote == nil) { _, isDismissed in
      if isDismissed {
        // Upstream promotion is not part of TBD.
      }
    }
    .sheet(item: $whatsNewNote, onDismiss: handleWhatsNewDismissed) { note in
      ZStack {
        // Backdrop
        Color.black.opacity(0.4)
          .ignoresSafeArea()

        WhatsNewView(releaseNote: note) {
          closeWhatsNew()
        }
      }
      .resolveDayflowTheme()
    }
  }

  @ViewBuilder
  private var goalFlowOverlay: some View {
    if let goalFlowPresentation {
      DayGoalFlowOverlay(
        presentation: goalFlowPresentation,
        onDismiss: {
          withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            self.goalFlowPresentation = nil
          }
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea()
      .transition(.opacity.combined(with: .scale(scale: 0.985)))
      .zIndex(3)
    }
  }

  private func showGitHubStarPromptIfEligible(source: String) {
    return // Vendor promotion disabled in Companion.

    guard !isShowingGitHubStarPrompt,
      whatsNewNote == nil,
      goalFlowPresentation == nil,
      !GitHubStarPromptState.hasShown,
      StorageManager.shared.hasAnyTimelineCards()
    else { return }

    GitHubStarPromptState.markShown()
    AnalyticsService.shared.capture("github_star_prompt_shown", ["source": source])
    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
      isShowingGitHubStarPrompt = true
    }
  }

  private func closeWhatsNew() {
    whatsNewNote = nil
  }

  private func handleWhatsNewDismissed() {
    guard let version = activeWhatsNewVersion else { return }
    if shouldMarkWhatsNewSeen {
      WhatsNewConfiguration.markReleaseAsSeen(version: version)
      AnalyticsService.shared.capture(
        "whats_new_viewed",
        [
          "version": version,
          "source": "auto",
        ])
    }
    AnalyticsService.shared.capture(
      "whats_new_viewed",
      [
        "version": version,
        "source": "manual",
      ])
    activeWhatsNewVersion = nil
    shouldMarkWhatsNewSeen = false
    showGitHubStarPromptIfEligible(source: "launch")
  }

  private var currentAppVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
  }
}

@main
struct DayflowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @AppStorage("didOnboard") private var didOnboard = false
  @StateObject private var systemAppearance = SystemAppearanceObserver()
  @AppStorage(DayflowAppearance.storageKey) private var appearance: DayflowAppearance = .system
  @AppStorage("useBlankUI") private var useBlankUI = false
  /// Mirrors FlowNudgeVariant.current so the menu title re-renders on toggle.
  @AppStorage(FlowNudgeVariant.defaultsKey) private var flowNudgeVariant = FlowNudgeVariant.side
    .rawValue
  @State private var showVideoLaunch = false
  // Keep content visible behind the brand overlay; completion must never gate rendering.
  @State private var contentOpacity = 1.0
  @State private var contentScale = 1.0
  @State private var isShowingGitHubStarPrompt = false
  // Must be the shared instance: the agent bridge (AgentWriteHandlers) writes to
  // CategoryStore.shared, and a second in-memory copy here would overwrite those
  // edits on the next UI-triggered save (GitHub issue #375).
  @StateObject private var categoryStore = CategoryStore.shared

  init() {
    // Writing to stdout after its reader has gone away (app launched from a
    // terminal or wrapper that exited) raises SIGPIPE and kills the process.
    // Ignore it so the write simply fails with EPIPE instead.
    signal(SIGPIPE, SIG_IGN)

    // Comment out for production - only use for testing onboarding
    // UserDefaults.standard.set(false, forKey: "didOnboard")
  }

  // Sparkle updater manager
  private let updaterManager = UpdaterManager.shared

  var body: some Scene {
    Window("TBD", id: "main") {
      ZStack {
        AppRootView(isShowingGitHubStarPrompt: $isShowingGitHubStarPrompt)
          .environmentObject(categoryStore)
          .environmentObject(updaterManager)

        if didOnboard && !showVideoLaunch && isShowingGitHubStarPrompt {
          GitHubStarPromptCard(
            onStar: starDayflow,
            onDismiss: dismissGitHubStarPrompt
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          .padding(.trailing, 24)
          .padding(.bottom, 24)
          .transition(.move(edge: .trailing).combined(with: .opacity))
          .zIndex(10)
        }

      }
      // Inline background behind the main app UI only
      .background {
        MainWindowRegistrationView()

        if didOnboard {
          DayflowWindowBackground()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      // Use an explicit scheme even for System; clearing an override can lag until focus changes.
      .preferredColorScheme(
        didOnboard ? appearance.colorScheme(system: systemAppearance.colorScheme) : .light
      )
      .resolveDayflowTheme()
      .resolveStylePreview()
      .onAppear {
        if !showVideoLaunch {
          dispatchPendingNotificationNavigation(after: 0.1)
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        if !showVideoLaunch {
          dispatchPendingNotificationNavigation(after: 0.1)
        }
      }
      .frame(minWidth: 900, maxWidth: .infinity, minHeight: 508, maxHeight: .infinity)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .defaultSize(width: 1195, height: 675)

    .commands {
      // Remove the "New Window" command if you want a single window app
      CommandGroup(replacing: .newItem) {}

      // Add custom menu items after the app info section
      CommandGroup(after: .appInfo) {
        Divider()
        Button("Quit completely") {
          AppDelegate.allowTermination = true
          NSApp.terminate(nil)
        }
        Button("Analyze captured activity now") {
          AnalysisManager.shared.analyzePendingActivity()
        }
        Button("Reset Onboarding") {
          // Reset the onboarding flag
          UserDefaults.standard.set(false, forKey: "didOnboard")
          // Reset the saved onboarding step to start from beginning
          UserDefaults.standard.set(0, forKey: "onboardingStep")
          UserDefaults.standard.removeObject(forKey: "onboardingHasPaidAI")
          UserDefaults.standard.removeObject(forKey: CategoryStore.StoreKeys.onboardingSelectedRole)
          UserDefaults.standard.removeObject(
            forKey: CategoryStore.StoreKeys.onboardingAppliedCategoryPreset)
          UserDefaults.standard.removeObject(
            forKey: CategoryStore.StoreKeys.onboardingCategoriesCustomized)
          UserDefaults.standard.removeObject(forKey: "onboardingSelectedProviderID")
          // Force quit and restart the app to show onboarding
          Task { @MainActor in
            AppDelegate.allowTermination = true
            NSApp.terminate(nil)
          }
        }
        .keyboardShortcut("R", modifiers: [.command, .shift])
      }

      // Add Sparkle's update menu item
      CommandGroup(after: .appInfo) {
        Button("About / Support") {
          // Activate the app and bring to foreground
          NSApp.activate(ignoringOtherApps: true)

          // Post notification to show What's New modal
          NotificationCenter.default.post(name: .showWhatsNew, object: nil)
        }
        .keyboardShortcut("N", modifiers: [.command, .shift])
      }

      CommandGroup(after: .appInfo) {
        Divider()
        Button("Flow: Simulate Distraction") {
          FlowSessionMirror.shared.simulateDistraction()
        }
        .keyboardShortcut("D", modifiers: [.command, .shift])
        Button("Flow: Nudge Style — \(FlowNudgeVariant.current.title)") {
          FlowNudgeVariant.current = FlowNudgeVariant.current.next
          flowNudgeVariant = FlowNudgeVariant.current.rawValue
        }
      }
    }
    .defaultSize(width: 1200, height: 800)

  }

  private func starDayflow() async {
    AnalyticsService.shared.capture("github_star_prompt_clicked")
    let starred = await GitHubStarService.starDayflow()
    if starred {
      AnalyticsService.shared.capture("github_star_completed", ["method": "gh"])
    } else {
      AnalyticsService.shared.capture("github_star_browser_fallback")
      NSWorkspace.shared.open(GitHubStarPromptState.repositoryURL)
    }
    hideGitHubStarPrompt()
  }

  private func dismissGitHubStarPrompt() {
    AnalyticsService.shared.capture("github_star_prompt_dismissed")
    hideGitHubStarPrompt()
  }

  private func hideGitHubStarPrompt() {
    withAnimation(.easeOut(duration: 0.2)) {
      isShowingGitHubStarPrompt = false
    }
  }

  private var hasPendingNotificationNavigation: Bool {
    AppDelegate.pendingNotificationNavigationDestination != nil
  }

  private func dispatchPendingNotificationNavigation(after delay: TimeInterval) {
    guard hasPendingNotificationNavigation else { return }

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      guard let destination = AppDelegate.pendingNotificationNavigationDestination else { return }
      AppDelegate.pendingNotificationNavigationDestination = nil

      switch destination {
      case .daily(let day) where day?.isEmpty == false:
        NotificationCenter.default.post(
          name: .navigateToDaily,
          object: nil,
          userInfo: ["day": day]
        )
      case .daily:
        NotificationCenter.default.post(name: .navigateToDaily, object: nil)
      case .support:
        NotificationCenter.default.post(name: .navigateToSupport, object: nil)
      case .weekly:
        NotificationCenter.default.post(name: .navigateToWeekly, object: nil)
      }
    }
  }
}

// MARK: - Notification Names

extension Notification.Name {
  static let analyticsPreferenceChanged = Notification.Name("analyticsPreferenceChanged")
  static let showWhatsNew = Notification.Name("showWhatsNew")
  static let navigateToDaily = Notification.Name("navigateToDaily")
  static let navigateToSupport = Notification.Name("navigateToSupport")
  static let navigateToWeekly = Notification.Name("navigateToWeekly")
  static let timelineDataUpdated = Notification.Name("timelineDataUpdated")
  static let showTimelineFailureToast = Notification.Name("showTimelineFailureToast")
  static let showScreenRecordingPermissionNotice = Notification.Name(
    "showScreenRecordingPermissionNotice")
  static let openProvidersSettings = Notification.Name("openProvidersSettings")
  static let openAccountSettings = Notification.Name("openAccountSettings")
  static let navigateToFlow = Notification.Name("navigateToFlow")
}

@MainActor
final class MainWindowController {
  static let shared = MainWindowController()

  private var openWindowAction: OpenWindowAction?
  private var hasPendingOpenRequest = false

  func register(_ openWindowAction: OpenWindowAction) {
    self.openWindowAction = openWindowAction

    if hasPendingOpenRequest {
      hasPendingOpenRequest = false
      openWindowAction(id: "main")
    }
  }

  func showMainWindow() {
    guard let openWindowAction else {
      hasPendingOpenRequest = true
      return
    }

    openWindowAction(id: "main")
  }
}

/// Brand surface behind the main app; follows the same light/dark palette.
private struct DayflowWindowBackground: View {
  @Environment(\.dayflowTheme) private var theme
  @AppStorage("tealbrickPalette") private var palette = "teal"
  var body: some View {
    LinearGradient(
      colors: theme.isDark
        ? [Color(hex: "142321"), Color(hex: palette == "burgundy" ? "332423" : "153D3A")]
        : [Color(hex: "F3F1E9"), Color(hex: palette == "burgundy" ? "EBDAD4" : "D4E7DF")],
      startPoint: .topLeading, endPoint: .bottomTrailing
    ).ignoresSafeArea()
  }
}

private struct MainWindowRegistrationView: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        MainWindowController.shared.register(openWindow)
      }
  }
}
