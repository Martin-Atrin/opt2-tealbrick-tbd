import TBDDesign
import TBDListening
import TBDModels
import SwiftUI

struct TBDModelsView: View {
  let screenSettings: () -> AnyView
  @State private var state = TBDModelRegistryState()
  @State private var page = "Tasks"
  @State private var name = ""
  @State private var endpoint = ""
  @State private var secret = ""
  @State private var kind: TBDModelKind = .openAICompatible
  @State private var error = ""
  @AppStorage(TBDCleanupPolicy.chatKey) private var chatCleanup = false
  @AppStorage(TBDCleanupPolicy.voiceNoteKey) private var noteCleanup = false
  private let registry = TBDModelRegistry()

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Picker("Models", selection: $page) {
        ForEach(["Tasks", "Connections", "Transcription", "Advanced"], id: \.self) { Text($0) }
      }.pickerStyle(.segmented)
      switch page {
      case "Transcription":
        Text("Speech recognition runs locally. Select engines and downloads below.").foregroundStyle(.secondary)
        TBDListeningRuntime.shared.settingsContent(section: "engine")
      case "Advanced":
        Text("Existing provider-specific settings remain available. Shared task routes take precedence when assigned.").foregroundStyle(.secondary)
        DisclosureGroup("Screen analysis providers") { screenSettings() }
        TBDListeningRuntime.shared.settingsContent(section: "ai")
      default:
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 22) {
            if page == "Connections" { connections }
            else {
              Text("Models by task").font(.title2)
              Text("Choose a connection once and reuse it. Selecting a model does not enable automatic cleanup. No automatic cross-provider fallback.").foregroundStyle(.secondary)
              TBDAgentModelForm { reload() }
              route("Cleanup", task: "cleanup", detail: "Optional transcript correction; shared model, independent switches.")
              Toggle("Clean up Chat voice input", isOn: $chatCleanup)
              Toggle("Clean up voice notes", isOn: $noteCleanup)
              Text("Both are off by default. Raw text is retained; a cleanup failure returns raw text. Voice notes are saved to history. Chat follows your dictation-history preference. Cleanup may send text to the selected network provider.").font(.callout).foregroundStyle(.secondary)
              route("Summaries", task: "analysis", detail: "Meeting and transcript analysis.")
              route("Transforms", task: "general", detail: "Text transformations and the default Listening AI route.")
              route("Screen analysis", task: "screen", detail: "Companion activity analysis. Choose a vision-capable model; screenshots may leave this Mac.")
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
          }.padding(.bottom, 24)
        }
      }
    }.padding(.top, 24)
    .onAppear { reload() }
  }
  private var connections: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Connections").font(.title2)
      Text("OpenAI-compatible or Anthropic endpoints. Keys are held in Keychain and reused only by routes assigned to that connection. Existing provider configurations remain unchanged until you assign a shared route.").foregroundStyle(.secondary)
      ForEach(state.connections) { connection in
        VStack(alignment: .leading) {
          Text(connection.name).fontWeight(.medium)
          Text("\(connection.kind == .anthropic ? "Anthropic" : "OpenAI-compatible") · \(connection.endpoint)").font(.callout).textSelection(.enabled)
        }
        Divider()
      }
      Picker("API", selection: $kind) {
        Text("OpenAI-compatible").tag(TBDModelKind.openAICompatible)
        Text("Anthropic").tag(TBDModelKind.anthropic)
      }.pickerStyle(.segmented)
      .onChange(of: kind) { _, k in if k == .anthropic && endpoint.isEmpty { endpoint = "https://api.anthropic.com" } }
      TextField("Connection name", text: $name).tbdField()
      TextField("https://host.example/v1", text: $endpoint).tbdField()
      SecureField("API key (optional for local servers)", text: $secret).tbdField()
      Button("Save connection") {
        do {
          try registry.saveConnection(TBDModelConnection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind), apiKey: secret.isEmpty ? nil : secret)
          secret = ""; name = ""; endpoint = ""; reload()
        } catch { self.error = error.localizedDescription }
      }
      .buttonStyle(TBDButtonStyle(.primary))
      .disabled(name.isEmpty || endpoint.isEmpty)
    }
  }
  private func route(_ title: String, task: String, detail: String) -> some View {
    TBDModelRouteCard(title: title, detail: detail, connections: state.connections, route: state.routes[task]) { route in
      do { try registry.assign(route, to: task); reload() }
      catch { self.error = error.localizedDescription }
    }
  }
  private func reload() {
    do { state = try registry.load(); error = "" }
    catch { self.error = error.localizedDescription }
  }
}

private struct TBDModelRouteCard: View {
  let title: String
  let detail: String
  let connections: [TBDModelConnection]
  let route: TBDModelRoute?
  let save: (TBDModelRoute?) -> Void
  @State private var connectionID = ""
  @State private var model = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      Text(detail).font(.callout).foregroundStyle(.secondary)
      Picker("Connection", selection: $connectionID) {
        Text("Existing configuration").tag("")
        ForEach(connections) { Text($0.name).tag($0.id) }
      }
      if !connectionID.isEmpty {
        TextField("Model ID", text: $model).tbdField()
        if let c = connections.first(where: { $0.id == connectionID }) {
          Text(c.endpoint).font(.caption).foregroundStyle(.secondary)
        }
      }
      Button("Apply") { save(connectionID.isEmpty ? nil : TBDModelRoute(connectionID: connectionID, model: model.trimmingCharacters(in: .whitespacesAndNewlines))) }
        .buttonStyle(TBDButtonStyle(.secondary))
        .disabled(!connectionID.isEmpty && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Divider()
    }
    .onAppear { connectionID = route?.connectionID ?? ""; model = route?.model ?? "" }
  }
}

/// One form for the model of TBD's agent in Chat: provider, key, model, Test connection, Save (sets the "agent" route).
private struct TBDAgentModelForm: View {
  let saved: () -> Void
  @State private var provider: TBDAgentProvider = .ollama
  @State private var endpoint = ""
  @State private var key = ""
  @State private var model = TBDAgentModelSetup.defaultLocalModel
  @State private var local: TBDAgentModelSetup.LocalStatus?
  @State private var hasKey = false
  @State private var testing = false
  @State private var result: TBDAgentModelTestResult?
  @State private var status = ""
  @State private var failure = ""
  private let registry = TBDModelRegistry()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("TBD agent model").font(.headline)
      Text("The model your TBD agent uses in Chat (Claude Agent SDK). Chat cannot answer until this is set.")
        .font(.callout).foregroundStyle(.secondary)
      Picker("Provider", selection: $provider) {
        ForEach(TBDAgentProvider.allCases, id: \.self) { Text($0.title).tag($0) }
      }.pickerStyle(.segmented)
      .onChange(of: provider) { old, new in
        result = nil
        // Switching provider swaps a default model ID for the other default; a typed ID stays.
        if model == old.defaultModel { model = new.defaultModel }
        checkLocal()
      }
      if provider == .ollama, let local {
        Text(local.message).font(.callout).foregroundStyle(local == .ready ? Color.secondary : Color.orange).textSelection(.enabled)
      }
      if provider == .anthropicCompatible {
        TextField("https://gateway.example/anthropic", text: $endpoint).tbdField()
      }
      if provider.needsKey {
        SecureField(hasKey ? "API key (stored in Keychain; leave empty to keep it)" : "API key", text: $key).tbdField()
          .onChange(of: key) { _, _ in result = nil }
      }
      TextField("Model ID", text: $model).tbdField()
        .onChange(of: model) { _, _ in result = nil }
      HStack(spacing: 10) {
        Button(testing ? "Testing…" : "Test connection") { test() }
          .buttonStyle(TBDButtonStyle(.secondary)).disabled(testing || !canSubmit)
        Button("Save") { save() }
          .buttonStyle(TBDButtonStyle(.primary)).disabled(!canSubmit)
      }
      if let result {
        Text(result.message).font(.callout).foregroundStyle(result.isOK ? Color.green : Color.red).textSelection(.enabled)
      }
      if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }
      if !failure.isEmpty { Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
      Divider()
    }
    .onAppear { load() }
  }

  private var endpointValue: String { provider.fixedEndpoint ?? endpoint }
  private var canSubmit: Bool {
    !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !endpointValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (!provider.needsKey || hasKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private func load() {
    let current = TBDAgentModelSetup.current(registry)
    provider = current.provider
    endpoint = current.provider == .anthropic ? "" : current.endpoint
    model = current.model
    hasKey = current.hasKey
    checkLocal()
  }

  private func checkLocal() {
    guard provider == .ollama else { local = nil; return }
    let model = model
    Task {
      let status = await TBDAgentModelSetup.localStatus(model: model)
      await MainActor.run { local = status }
    }
  }

  private func test() {
    guard let apiKey = TBDAgentModelSetup.testKey(provider: provider, endpoint: endpointValue, typed: key, registry: registry) else {
      result = .failed("enter the API key first."); return
    }
    testing = true; result = nil
    let endpoint = endpointValue, model = model, provider = provider
    Task {
      let outcome = provider == .ollama
        ? TBDAgentModelSetup.testResult(await TBDAgentModelSetup.localStatus(model: model))
        : await TBDAgentModelSetup.test(endpoint: endpoint, apiKey: apiKey, model: model)
      await MainActor.run { result = outcome; testing = false }
    }
  }

  private func save() {
    do {
      try TBDAgentModelSetup.save(provider: provider, endpoint: endpointValue, apiKey: key, model: model, registry: registry)
      key = ""; failure = ""; status = "Saved. TBD's agent uses \(model.trimmingCharacters(in: .whitespacesAndNewlines)). Go back to Chat and send a message."
      load(); saved()
    } catch {
      status = ""; failure = error.localizedDescription
    }
  }
}
