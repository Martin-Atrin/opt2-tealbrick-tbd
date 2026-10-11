import MacParakeet
import MacParakeetCore
import SwiftUI

struct TBDModelsView: View {
  let screenSettings: () -> AnyView
  @State private var state = TBDModelRegistryState()
  @State private var page = "Tasks"
  @State private var name = ""
  @State private var endpoint = ""
  @State private var secret = ""
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
      Text("OpenAI-compatible endpoints. Keys are held in Keychain and reused only by routes assigned to that connection. Existing provider configurations remain unchanged until you assign a shared route.").foregroundStyle(.secondary)
      ForEach(state.connections) { connection in
        VStack(alignment: .leading) {
          Text(connection.name).fontWeight(.medium)
          Text(connection.endpoint).font(.callout).textSelection(.enabled)
        }
        Divider()
      }
      TextField("Connection name", text: $name).tbdField()
      TextField("https://host.example/v1", text: $endpoint).tbdField()
      SecureField("API key (optional for local servers)", text: $secret).tbdField()
      Button("Save connection") {
        do {
          try registry.saveConnection(TBDModelConnection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), apiKey: secret.isEmpty ? nil : secret)
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
