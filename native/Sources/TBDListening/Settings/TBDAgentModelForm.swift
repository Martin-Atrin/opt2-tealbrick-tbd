import SwiftUI
import TBDDesign
import TBDModels

/// Settings → Models → "TBD agent model": ONE form for the model of TBD's agent in Chat (provider, key, model,
/// Test connection, Save → the "agent" route). Built only from TBDDesign components (design proof screen).
public struct TBDAgentModelForm: View {
    let saved: () -> Void
    private let registry: TBDModelRegistry
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
    @State private var step = 0

    /// `registry` is injectable so previews and screenshot checks never touch the person's settings or Keychain.
    public init(registry: TBDModelRegistry = TBDModelRegistry(), saved: @escaping () -> Void) {
        self.registry = registry; self.saved = saved
        let current = TBDAgentModelSetup.current(registry)
        _provider = State(initialValue: current.provider)
        _endpoint = State(initialValue: current.provider == .anthropic ? "" : current.endpoint)
        _model = State(initialValue: current.model)
        _hasKey = State(initialValue: current.hasKey)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TBDKit.s5) {
            VStack(alignment: .leading, spacing: TBDKit.s2) {
                TBDKicker("TBD agent model")
                Text("The model your TBD agent uses in Chat")
                    .font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
                Text("TBD's agent runs on the Claude Agent SDK. Chat cannot answer until this is set.")
                    .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            // The card keeps one fixed size for every step (C126). The key step is left out entirely when the provider needs no key.
            TBDStepFlow(steps: steps, current: $step, size: CGSize(width: 560, height: 420)) { save() }
                .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
                .clipShape(TBDBrickShape())
        }
        .frame(maxWidth: 560, alignment: .leading)
        .onAppear { load() }
    }

    private var steps: [TBDStep] {
        var all = [TBDStep("Provider", canAdvance: !endpointValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { providerStep }]
        if provider.needsKey {
            all.append(TBDStep("Key", canAdvance: hasKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { keyStep })
        }
        all.append(TBDStep("Model", nextLabel: "Save", canAdvance: canSubmit) { modelStep })
        return all
    }

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: TBDKit.s4) {
            TBDSegmented(selection: $provider, options: TBDAgentProvider.allCases.map { ($0, $0.title) })
                .onChange(of: provider) { old, new in
                    result = nil
                    // Switching provider swaps a default model ID for the other default; a typed ID stays.
                    if model == old.defaultModel { model = new.defaultModel }
                    checkLocal()
                }
            if provider == .ollama, let local {
                if local == .ready { Text(local.message).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).textSelection(.enabled) }
                else { TBDNotice(local.message, tone: .needsYou) }
            }
            if provider == .anthropicCompatible {
                TBDField("Endpoint", text: $endpoint, prompt: "https://gateway.example/anthropic")
            }
        }
    }

    private var keyStep: some View {
        TBDField("API key", text: $key, prompt: hasKey ? "Stored in Keychain" : "sk-ant-…", secure: true,
                 hint: hasKey ? "Leave it empty to keep the stored key." : "Kept in your Keychain, one item per endpoint.")
            .onChange(of: key) { _, _ in result = nil }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: TBDKit.s4) {
            TBDField("Model ID", text: $model, hint: "Prefilled with the default model for this provider.")
                .onChange(of: model) { _, _ in result = nil }
            Button(testing ? "Testing…" : "Test connection") { test() }
                .buttonStyle(TBDButtonStyle(.secondary)).disabled(testing || !canSubmit)
            if let result { TBDNotice(result.message, tone: result.isOK ? .live : .needsYou) }
            if !status.isEmpty { TBDNotice(status, tone: .live) }
            if !failure.isEmpty { TBDNotice(failure, tone: .needsYou) }
        }
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
            if !key.isEmpty { result = nil }  // the key field used to clear the test result when it emptied
            key = ""; failure = ""; status = "Saved. TBD's agent uses \(model.trimmingCharacters(in: .whitespacesAndNewlines)). Go back to Chat and send a message."
            load(); saved()
        } catch {
            status = ""; failure = error.localizedDescription
        }
    }
}
