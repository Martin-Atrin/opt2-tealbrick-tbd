//
//  SettingsView.swift
//  Dayflow
//
//  Settings screen with onboarding-inspired styling and split layout
//

import Foundation
import SwiftUI
import TBDDesign
import TBDListening
import TBDModels

struct SettingsView: View {

  private enum SettingsTab: String, CaseIterable, Identifiable {
    case account, about
    case permissions
    case storage
    case privacy
    case providers
    case aiTools
    case data
    case other
    case capture, engine, audioAI, audioSystem

    var id: String { rawValue }

    var symbol: String {
      switch self {
      case .about: return "info.circle"
      case .account: return "person.crop.circle"
      case .permissions: return "lock.shield"
      case .storage: return "internaldrive"
      case .privacy: return "eye.slash"
      case .providers: return "network"
      case .aiTools: return "wrench.and.screwdriver"
      case .data: return "square.and.arrow.up"
      case .other: return "slider.horizontal.3"
      case .capture: return "mic"
      case .engine: return "cpu"
      case .audioAI: return "waveform"
      case .audioSystem: return "gearshape"
      }
    }

    var title: String {
      switch self {
      case .about: return "About"
      case .account: return "Account"
      case .permissions: return "Access"
      case .storage: return String(localized: "Storage")
      case .privacy: return "Screen capture"
      case .providers: return String(localized: "Providers")
      case .aiTools: return String(localized: "Tools")
      case .data: return String(localized: "Export")
      case .other: return "General"
      case .capture: return "Capture"
      case .engine: return "Agent model"
      case .audioAI: return "Speech"
      case .audioSystem: return "System"
      }
    }
  }

  /// Settings grouped by TBD's three aspects plus the app (TBD-PRODUCT.md §a, C142).
  private static let groups: [(title: String, tabs: [SettingsTab])] = [
    ("Chat", [.engine]),
    ("Companion", [.privacy, .providers, .storage, .aiTools, .data]),
    ("Listen", [.capture, .audioAI, .audioSystem]),
    ("App", [.account, .permissions, .other, .about]),
  ]

  @State private var selectedTab: SettingsTab
  init(initialSection: String = "account") {
    _selectedTab = State(initialValue: SettingsTab(rawValue: initialSection) ?? .account)
  }
  private var listeningSection: String? {
    switch selectedTab {
    case .capture: return TBDListeningSettingsSection.capture.rawValue
    case .engine: return nil
    case .audioAI: return nil
    case .audioSystem: return TBDListeningSettingsSection.system.rawValue
    default: return nil
    }
  }

  @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared

  @StateObject private var storageViewModel = StorageSettingsViewModel()
  @StateObject private var privacyViewModel = RecordingPrivacySettingsViewModel()
  @StateObject private var providersViewModel = ProvidersSettingsViewModel()
  @StateObject private var otherViewModel = OtherSettingsViewModel()
  @StateObject private var agentAccessViewModel = AgentAccessViewModel()

  var body: some View {
    contentWithSheets
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("tbdListeningSettingsTabChanged"))) { note in
        guard listeningSection != nil, let section = note.object as? String else { return }
        selectedTab = section == "ai" ? .audioAI : section == "system" ? .audioSystem : SettingsTab(rawValue: section) ?? .capture
      }
  }

  private var contentWithSheets: some View {
    contentWithLifecycle
      .sheet(
        item: Binding(
          get: {
            providersViewModel.setupModalProvider.map {
              ProviderSetupWrapper(providerID: $0)
            }
          },
          set: { wrapper in
            if let wrapper {
              providersViewModel.setupModalProvider = wrapper.providerID
            } else {
              providersViewModel.cancelProviderSetup()
            }
          }
        )
      ) { wrapper in
        LLMProviderSetupView(
          providerType: wrapper.providerID,
          onBack: { providersViewModel.cancelProviderSetup() },
          onComplete: { configuredProviderID in
            let succeeded = providersViewModel.handleProviderSetupCompletion(configuredProviderID)
            if succeeded {
              providersViewModel.cancelProviderSetup()
            }
            return succeeded
          }
        )
        .frame(minWidth: 900, minHeight: 650)
      }
      .sheet(isPresented: $providersViewModel.isShowingLocalModelUpgradeSheet) {
        LocalModelUpgradeSheet(
          preset: .qwen3VL4B,
          initialEngine: providersViewModel.localEngine,
          initialBaseURL: providersViewModel.localBaseURL,
          initialModelId: providersViewModel.localModelId,
          initialAPIKey: providersViewModel.localAPIKey,
          onCancel: { providersViewModel.isShowingLocalModelUpgradeSheet = false },
          onUpgradeSuccess: { engine, baseURL, modelId, apiKey in
            providersViewModel.handleUpgradeSuccess(
              engine: engine, baseURL: baseURL, modelId: modelId, apiKey: apiKey)
            providersViewModel.isShowingLocalModelUpgradeSheet = false
          }
        )
        .frame(minWidth: 720, minHeight: 560)
      }
  }

  private var contentWithLifecycle: some View {
    GeometryReader { proxy in
      mainContent
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .onAppear {
      providersViewModel.handleOnAppear()
      storageViewModel.refreshStorageIfNeeded(isStorageTab: selectedTab == .storage)
      launchAtLoginManager.refreshStatus()
    }
    .onChange(of: selectedTab) { _, newValue in
      if newValue == .storage {
        storageViewModel.refreshStorageIfNeeded(isStorageTab: true)
      } else if newValue == .privacy {
        privacyViewModel.handleOnAppear()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .openProvidersSettings)) { _ in
      guard selectedTab != .providers else { return }
      withAnimation(TBDMotion.quick) {
        selectedTab = .providers
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .openAccountSettings)) { _ in
      guard selectedTab != .account else { return }
      withAnimation(TBDMotion.quick) {
        selectedTab = .account
      }
    }
  }

  private var mainContent: some View {
    HStack(alignment: .top, spacing: 0) {
      sidebar
      settingsContent
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TBDColor.tile, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
        .padding(.trailing, TBDKit.s4)
        .padding(.bottom, TBDKit.s4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(TBDColor.paper)
  }

  @ViewBuilder
  private var settingsContent: some View {
    if selectedTab == .engine || selectedTab == .providers || selectedTab == .audioAI {
      // One Models screen; each entry opens the page it belongs to (agent, screen analysis, speech).
      TBDModelsView(
        screenSettings: { AnyView(SettingsProvidersTabView(viewModel: providersViewModel)) },
        initialPage: selectedTab == .providers ? "Advanced" : selectedTab == .audioAI ? "Transcription" : "Tasks"
      )
        .id(selectedTab)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
    } else if let section = listeningSection {
      TBDListeningRuntime.shared.settingsContent(section: section)
        .frame(maxWidth: 660, maxHeight: .infinity, alignment: .topLeading)
    } else if selectedTab == .privacy {
      VStack(alignment: .leading, spacing: 24) {
        tabContent
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.top, 24)
      .padding(.trailing, 16)
      .padding(.bottom, 24)
      .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
    } else {
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 24) {
          tabContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
        .padding(.trailing, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, minHeight: 0, alignment: .topLeading)
      }
      .frame(maxWidth: 600, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var sidebar: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: TBDKit.s5) {
        ForEach(Self.groups, id: \.title) { group in
          TBDNavSection(group.title) {
            ForEach(group.tabs) { tab in
              TBDNavItem(tab.title, symbol: tab.symbol, current: selectedTab == tab) {
                withAnimation(TBDMotion.quick) { selectedTab = tab }
              }
              .pointingHandCursor()
            }
            if group.title == "App" {
              TBDNavItem("Updates", symbol: "sparkles", current: false) { selectedTab = .about }
                .help("Release notes")
            }
          }
        }
      }
      .padding(.top, TBDKit.s5)
      .padding(.horizontal, TBDKit.s3)
      .padding(.bottom, TBDKit.s4)
    }
    .frame(width: 208)
  }

  @ViewBuilder
  private var tabContent: some View {
    // Content swap is a pure fade. The sidebar rail item's left ink bar
    // carries the "where you went" signal — the content doesn't need to
    // redundantly slide horizontally, which implied a carousel that doesn't
    // actually exist (the sidebar is vertical, not left/right tabs).
    Group {
      switch selectedTab {
      case .about:
        TBDAboutView()
      case .account:
        SettingsAccountSection()
      case .permissions:
        TBDPermissionsView()
      case .storage:
        SettingsStorageTabView(viewModel: storageViewModel)
      case .privacy:
        SettingsRecordingPrivacyTabView(viewModel: privacyViewModel)
      case .providers:
        SettingsProvidersTabView(viewModel: providersViewModel)
      case .aiTools:
        SettingsAgentAccessTabView(viewModel: agentAccessViewModel)
      case .data:
        SettingsDataTabView(viewModel: otherViewModel)
      case .capture, .engine, .audioAI, .audioSystem:
        EmptyView()
      case .other:
        SettingsOtherTabView(viewModel: otherViewModel, launchAtLoginManager: launchAtLoginManager)
      }
    }
    .id(selectedTab)
    .transition(.opacity)
  }
}

private struct ProviderSetupWrapper: Identifiable {
  let providerID: LLMProviderID

  var id: String { providerID.rawValue }
}

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView()
      .frame(width: 1400, height: 860)
  }
}
