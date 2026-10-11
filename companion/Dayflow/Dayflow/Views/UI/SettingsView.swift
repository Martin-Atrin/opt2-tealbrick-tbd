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
  @Environment(\.dayflowTheme) private var theme

  private enum SettingsTab: String, CaseIterable, Identifiable {
    case account, about
    case permissions
    case storage
    case privacy
    case providers
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
      case .privacy: return String(localized: "Privacy")
      case .providers: return String(localized: "Providers")
      case .data: return String(localized: "Export")
      case .other: return "General"
      case .capture: return "Capture"
      case .engine: return "Models"
      case .audioAI: return "Speech"
      case .audioSystem: return "System"
      }
    }
  }

  @State private var selectedTab: SettingsTab
  init(initialSection: String = "account") {
    _selectedTab = State(initialValue: SettingsTab(rawValue: initialSection) ?? .account)
  }
  private var listeningSection: String? {
    switch selectedTab {
    case .capture: return "capture"
    case .engine: return nil
    case .audioAI: return nil
    case .audioSystem: return "system"
    default: return nil
    }
  }

  @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared

  @StateObject private var storageViewModel = StorageSettingsViewModel()
  @StateObject private var privacyViewModel = RecordingPrivacySettingsViewModel()
  @StateObject private var providersViewModel = ProvidersSettingsViewModel()
  @StateObject private var otherViewModel = OtherSettingsViewModel()

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
        .background(theme.panelSolid)
        .clipShape(RoundedRectangle(cornerRadius: TBDTokens.Radius.base))
        .padding(.trailing, 15)
        .padding(.bottom, 15)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var settingsContent: some View {
    if selectedTab == .engine || selectedTab == .providers || selectedTab == .audioAI {
      TBDModelsView(screenSettings: { AnyView(SettingsProvidersTabView(viewModel: providersViewModel)) })
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
      VStack(spacing: TBDRailMetrics.gap) {
        ForEach(SettingsTab.allCases.filter { $0 != .providers && $0 != .audioAI }) { tab in
          sidebarButton(for: tab)
        }
        Button {
          selectedTab = .about
        } label: {
          railLabel("Updates", symbol: "sparkles", selected: false)
        }
        .buttonStyle(SettingsSidebarButtonStyle())
        .help("Release notes")
      }
      .padding(.top, TBDRailMetrics.topInset)
      .padding(.bottom, 15)
      .frame(width: TBDRailMetrics.width)
    }
    .frame(width: TBDRailMetrics.width)
  }

  private func railLabel(_ title: String, symbol: String, selected: Bool) -> some View {
    VStack(spacing: 3) {
      Image(systemName: symbol)
        .resizable().scaledToFit()
        .frame(width: TBDRailMetrics.icon, height: TBDRailMetrics.icon)
        .frame(width: TBDRailMetrics.iconBox, height: TBDRailMetrics.iconBox)
        .background {
          // Soft rail selection (docs/design-language.md — see SidebarView.iconBox).
          if selected { TBDRailSelection() }
        }
      Text(title)
        .font(.custom("Switzer", size: TBDRailMetrics.label))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
    .foregroundStyle(selected ? theme.sidebarLabelActive : theme.sidebarLabel)
    .frame(width: TBDRailMetrics.row, height: TBDRailMetrics.row)
    .contentShape(Rectangle())
  }

  private func sidebarButton(for tab: SettingsTab) -> some View {
    Button {
      withAnimation(TBDMotion.quick) { selectedTab = tab }
    } label: {
      railLabel(tab.title, symbol: tab.symbol, selected: selectedTab == tab)
    }
    .buttonStyle(SettingsSidebarButtonStyle())
    .accessibilityLabel(tab.title)
    .help(tab.title)
    .pointingHandCursor()
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

// Brick rail item: square hit target, no rounded background or
// scale/spring bounce — selection reads through `railLabel`'s left bar,
// not through this style (docs/design-language.md, Rail item).
private struct SettingsSidebarButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.85 : 1)
  }
}
