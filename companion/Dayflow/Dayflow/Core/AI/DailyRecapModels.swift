import Foundation
import TBDModels

enum DailyRecapProvider: String, Codable, CaseIterable, Sendable {
  case local
  case gemini
  case chatgpt
  case claude
  case none
  /// TBD's "agent" model route (Settings → Models → TBD agent model).
  case agent
  /// Derived, never stored: the person has not chosen a model and none is set up (C137).
  case unchosen

  private static let storageKey = "dailyRecapProvider_v1"
  /// Set only when the person picks a provider in the Daily picker (`save`).
  private static let chosenKey = "dailyRecapProviderChosen_v1"
  /// The providers the picker lists. `unchosen` is a state, not a provider.
  static let allCases: [DailyRecapProvider] = [
    .agent,
    .claude,
    .chatgpt,
    .gemini,
    .local,
    .none,
  ]

  /// The effective provider. Explicit choices stay; otherwise TBD's agent model when it is set up,
  /// else `.unchosen`. Reading never writes (the derived value is not stored).
  static func load(from defaults: UserDefaults = .standard) -> DailyRecapProvider {
    let stored = defaults.string(forKey: storageKey).flatMap(DailyRecapProvider.init(rawValue:))
    let storedRaw = (stored ?? derivedFromRouting(defaults))?.rawValue
    let result = TBDDailyRecapChoice.resolve(
      storedRaw: storedRaw,
      chosen: defaults.bool(forKey: chosenKey),
      agentRouteReady: agentRouteIsReady())
    switch result {
    case .provider(let raw):
      return DailyRecapProvider(rawValue: raw) ?? .unchosen
    case .needsChoice:
      return .unchosen
    }
  }

  /// Called only from the picker: records the person's choice.
  func save(to defaults: UserDefaults = .standard) {
    guard self != .unchosen else { return }
    defaults.set(rawValue, forKey: Self.storageKey)
    defaults.set(true, forKey: Self.chosenKey)
  }

  /// A recap provider implied by the Companion routing store. Only a real provider counts;
  /// the first-run default (`openAICompatible`) implies nothing.
  private static func derivedFromRouting(_ defaults: UserDefaults) -> DailyRecapProvider? {
    guard let providerID = (try? LLMProviderRoutingStore.load(from: defaults))?.primary else {
      return nil
    }

    switch providerID {
    case .gemini:
      return .gemini
    case .chatGPT:
      return .chatgpt
    case .claude:
      return .claude
    case .local:
      return .local
    case .openAICompatible:
      return nil
    }
  }

  static func agentRouteIsReady() -> Bool {
    (try? TBDAgentModelSetup.resolve(TBDModelRegistry())) != nil
  }

  /// The model ID of TBD's agent route, nil when it is not set up.
  static func agentModelID() -> String? {
    (try? TBDAgentModelSetup.resolve(TBDModelRegistry()))?.model
  }

  var analyticsName: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .local:
      return String(localized: "Local")
    case .gemini:
      return String(localized: "Gemini")
    case .chatgpt:
      return String(localized: "ChatGPT")
    case .claude:
      return String(localized: "Claude")
    case .none:
      return String(localized: "No provider")
    case .agent:
      return String(localized: "TBD agent model")
    case .unchosen:
      return String(localized: "No model chosen")
    }
  }

  var selectionLabel: String {
    switch self {
    case .local:
      return String(localized: "Local")
    case .gemini:
      return GeminiModelPreference.default.primary.displayName
    case .chatgpt:
      return String(localized: "GPT-6 Astra")
    case .claude:
      return String(localized: "Claude Opus")
    case .none:
      return String(localized: "No provider selected (Daily off)")
    case .agent:
      return Self.agentModelID() ?? String(localized: "TBD agent model")
    case .unchosen:
      return String(localized: "Choose a model for Daily")
    }
  }

  var pickerSubtitle: String {
    switch self {
    case .local:
      return String(
        localized: "Uses Ollama, LM Studio, or another local-compatible server on this Mac.")
    case .gemini:
      return GeminiModelPreference.default.primary.displayName
    case .chatgpt:
      return String(localized: "GPT-6 Astra")
    case .claude:
      return String(localized: "Claude Opus")
    case .none:
      return String(localized: "Turns off Daily recap generation until you pick another provider.")
    case .agent:
      return String(localized: "Set up in Settings → Models")
    case .unchosen:
      return String(localized: "Choose a model for Daily")
    }
  }

  var runtimeLabel: String {
    switch self {
    case .local:
      return "local_llm"
    case .gemini:
      return "gemini_direct"
    case .chatgpt, .claude:
      return "chat_cli"
    case .none, .unchosen:
      return "disabled"
    case .agent:
      return "tbd_agent_model"
    }
  }

  var modelOrTool: String? {
    switch self {
    case .local:
      return Self.currentLocalModelID()
    case .gemini:
      return GeminiModelPreference.default.primary.rawValue
    case .chatgpt:
      return "gpt-6-astra"
    case .claude:
      return "opus"
    case .none, .unchosen:
      return nil
    case .agent:
      return Self.agentModelID()
    }
  }

  var canGenerate: Bool {
    self != .none && self != .unchosen
  }

  private static func currentLocalModelID(from defaults: UserDefaults = .standard) -> String? {
    let trimmed = defaults.string(forKey: "llmLocalModelId")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty {
      return trimmed
    }

    let rawEngine = defaults.string(forKey: "llmLocalEngine") ?? LocalEngine.ollama.rawValue
    let engine = LocalEngine(rawValue: rawEngine) ?? .ollama
    return LocalModelPreferences.defaultModelId(for: engine)
  }
}

enum DailyStandupPlaceholder {
  static let notGeneratedMessage =
    "Daily data has not been generated yet. If this is unexpected, please report a bug."
  static let todayNotGeneratedMessage = "Today's daily recap will be generated tomorrow morning."
  static let insufficientHistoryMessage =
    "Not enough captured activity in the previous 3 days to generate a standup."
  static let noProviderSelectedMessage =
    "Choose a model for Daily. Click the gear button above, then choose a provider to turn recap generation on."
}

struct DailyStandupGenerationMetadata: Codable, Equatable, Sendable {
  var provider: DailyRecapProvider
  var runtime: String
  var modelOrTool: String?
  var sourceDay: String?
  var generatedAt: Date?

  init(
    provider: DailyRecapProvider,
    runtime: String? = nil,
    modelOrTool: String? = nil,
    sourceDay: String? = nil,
    generatedAt: Date? = Date()
  ) {
    self.provider = provider
    self.runtime = runtime ?? provider.runtimeLabel
    self.modelOrTool = modelOrTool ?? provider.modelOrTool
    self.sourceDay = sourceDay
    self.generatedAt = generatedAt
  }

  var displayLabel: String {
    switch provider {
    case .local:
      return modelOrTool ?? String(localized: "Local")
    case .gemini:
      return modelOrTool.flatMap(GeminiModel.init(rawValue:))?.displayName
        ?? modelOrTool ?? String(localized: "Gemini")
    case .chatgpt:
      return modelOrTool == "gpt-5.6-sol"
        ? String(localized: "GPT-5.6 Sol") : String(localized: "GPT-6 Astra")
    case .claude:
      return String(localized: "Claude Opus")
    case .none, .unchosen:
      return String(localized: "No provider")
    case .agent:
      return modelOrTool ?? String(localized: "TBD agent model")
    }
  }
}

struct DailyBulletItem: Identifiable, Codable, Equatable, Sendable {
  var id: UUID = UUID()
  var text: String
}

struct DailyStandupDraft: Codable, Equatable, Sendable {
  var highlightsTitle: String
  var highlights: [DailyBulletItem]
  var tasksTitle: String
  var tasks: [DailyBulletItem]
  var blockersTitle: String
  var blockersBody: String
  var generation: DailyStandupGenerationMetadata?

  static let `default` = DailyStandupDraft(
    highlightsTitle: "Yesterday's highlights",
    highlights: [DailyBulletItem(text: DailyStandupPlaceholder.notGeneratedMessage)],
    tasksTitle: "Today's tasks",
    tasks: [DailyBulletItem(text: DailyStandupPlaceholder.notGeneratedMessage)],
    blockersTitle: "Blockers",
    blockersBody: DailyStandupPlaceholder.notGeneratedMessage,
    generation: nil
  )

  static let todayPlaceholder = DailyStandupDraft(
    highlightsTitle: "Yesterday's highlights",
    highlights: [DailyBulletItem(text: DailyStandupPlaceholder.todayNotGeneratedMessage)],
    tasksTitle: "Today's tasks",
    tasks: [DailyBulletItem(text: DailyStandupPlaceholder.todayNotGeneratedMessage)],
    blockersTitle: "Blockers",
    blockersBody: DailyStandupPlaceholder.todayNotGeneratedMessage,
    generation: nil
  )

  static let insufficientHistory = DailyStandupDraft(
    highlightsTitle: "Recent highlights",
    highlights: [DailyBulletItem(text: DailyStandupPlaceholder.insufficientHistoryMessage)],
    tasksTitle: "Tasks",
    tasks: [DailyBulletItem(text: DailyStandupPlaceholder.insufficientHistoryMessage)],
    blockersTitle: "Blockers",
    blockersBody: DailyStandupPlaceholder.insufficientHistoryMessage,
    generation: nil
  )

  static let noProviderSelected = DailyStandupDraft(
    highlightsTitle: "Yesterday's highlights",
    highlights: [DailyBulletItem(text: DailyStandupPlaceholder.noProviderSelectedMessage)],
    tasksTitle: "Today's tasks",
    tasks: [DailyBulletItem(text: DailyStandupPlaceholder.noProviderSelectedMessage)],
    blockersTitle: "Blockers",
    blockersBody: DailyStandupPlaceholder.noProviderSelectedMessage,
    generation: nil
  )

  func encodedJSONString() -> String? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  var hasGeneratedContent: Bool {
    !highlights.isEmpty || !tasks.isEmpty
      || !blockersBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

struct DailyRecapSourceDayCandidate: Equatable, Sendable {
  let dayString: String
  let startOfDay: Date
  let endOfDay: Date
}

enum DailyRecapSourceDayResolver {
  static func consumedSourceDays(from entries: [DailyStandupEntry]) -> Set<String> {
    entries.reduce(into: Set<String>()) { result, entry in
      guard
        let data = entry.payloadJSON.data(using: .utf8),
        let draft = try? JSONDecoder().decode(DailyStandupDraft.self, from: data),
        let sourceDay = draft.generation?.sourceDay?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !sourceDay.isEmpty
      else {
        return
      }

      result.insert(sourceDay)
    }
  }

  static func sourceDay(
    before targetStart: Date,
    lookbackWindowDays: Int,
    consumedSourceDays: Set<String>,
    hasMinimumActivity: (String) -> Bool
  ) -> DailyRecapSourceDayCandidate? {
    guard lookbackWindowDays > 0 else { return nil }

    let calendar = Calendar.current
    for offset in 1...lookbackWindowDays {
      guard
        let sourceStart = calendar.date(byAdding: .day, value: -offset, to: targetStart)
      else {
        continue
      }

      let dayString = DateFormatter.yyyyMMdd.string(from: sourceStart)
      guard !consumedSourceDays.contains(dayString),
        hasMinimumActivity(dayString),
        let sourceEnd = calendar.date(byAdding: .day, value: 1, to: sourceStart)
      else {
        continue
      }

      return DailyRecapSourceDayCandidate(
        dayString: dayString,
        startOfDay: sourceStart,
        endOfDay: sourceEnd
      )
    }

    return nil
  }
}
