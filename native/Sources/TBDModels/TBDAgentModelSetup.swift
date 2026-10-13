import Foundation

/// Where TBD's agent (Claude Agent SDK) gets its model. Anthropic first; an Anthropic-compatible endpoint
/// (a proxy or gateway that speaks the Messages API) is the only other kind the agent can use.
public enum TBDAgentProvider: String, CaseIterable, Sendable {
    case anthropic, anthropicCompatible

    public var title: String { self == .anthropic ? "Anthropic" : "Anthropic-compatible endpoint" }
    /// The fixed endpoint for Anthropic; nil when the person enters one.
    public var fixedEndpoint: String? { self == .anthropic ? TBDAgentModelSetup.anthropicEndpoint : nil }
}

/// Why TBD's agent cannot answer yet. The texts are what Chat and Settings show.
public enum TBDAgentModelError: Error, LocalizedError, Equatable {
    case noModel, notAnthropic, noKey
    public var errorDescription: String? {
        switch self {
        case .noModel: return "No model set for TBD's agent. Set up a model in Settings → Models."
        case .notAnthropic: return "TBD's agent needs an Anthropic connection. Set up a model in Settings → Models."
        case .noKey: return "TBD's agent has no API key. Set up a model in Settings → Models."
        }
    }
}

/// The result of "Test connection".
public enum TBDAgentModelTestResult: Equatable, Sendable {
    case ok
    case badKey
    case unknownModel(String)
    case failed(String)

    public var message: String {
        switch self {
        case .ok: return "Connection works. The key and the model are accepted."
        case .badKey: return "The API key was refused. Check the key and try again."
        case .unknownModel(let model): return "The endpoint does not know the model \"\(model)\". Check the model ID."
        case .failed(let reason): return "The test failed: \(reason)"
        }
    }
    public var isOK: Bool { self == .ok }
}

/// One-form setup for the "agent" route (Settings → Models → TBD agent model): provider, key, model,
/// Test connection, Save. Save reuses a saved connection to the same Anthropic endpoint, so the key stays
/// one Keychain item per endpoint, and assigns the "agent" route.
public enum TBDAgentModelSetup {
    public static let anthropicEndpoint = "https://api.anthropic.com"
    /// Prefilled model ID (the current default Claude model).
    public static let defaultModel = "claude-opus-5-5"
    static let connectionName = "Anthropic (TBD agent)"

    /// The agent route as Chat needs it: an Anthropic connection with a key. Throws the reason it is not ready.
    public static func resolve(_ registry: TBDModelRegistry) throws -> TBDModelConfig {
        guard let config = try registry.configuration(for: .agent) else { throw TBDAgentModelError.noModel }
        guard config.kind == .anthropic else { throw TBDAgentModelError.notAnthropic }
        guard let key = config.apiKey, !key.isEmpty else { throw TBDAgentModelError.noKey }
        return config
    }

    /// What the form shows when it opens: the current agent route, else Anthropic with the default model.
    public static func current(_ registry: TBDModelRegistry) -> (provider: TBDAgentProvider, endpoint: String, model: String, hasKey: Bool) {
        guard let state = try? registry.load(), let route = state.routes[TBDModelTask.agent.rawValue],
              let connection = state.connections.first(where: { $0.id == route.connectionID }), connection.kind == .anthropic else {
            return (.anthropic, anthropicEndpoint, defaultModel, false)
        }
        let provider: TBDAgentProvider = normalized(connection.endpoint) == anthropicEndpoint ? .anthropic : .anthropicCompatible
        return (provider, connection.endpoint, route.model, registry.hasKey(for: connection.id))
    }

    /// Saves the form: finds or creates the Anthropic connection for `endpoint`, stores a new key when one is
    /// given, and sets the "agent" route. A key is required unless the reused connection already holds one.
    @discardableResult
    public static func save(provider: TBDAgentProvider, endpoint: String, apiKey: String, model: String,
                            registry: TBDModelRegistry) throws -> TBDModelConnection {
        let url = normalized(provider.fixedEndpoint ?? endpoint)
        _ = try TBDModelRegistry.endpointURL(url)
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw TBDModelRegistryError.invalidRoute }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try registry.load().connections.first { $0.kind == .anthropic && normalized($0.endpoint) == url }
        let connection = existing ?? TBDModelConnection(name: provider == .anthropic ? connectionName : "Anthropic-compatible (TBD agent)",
                                                        endpoint: url, kind: .anthropic)
        guard !key.isEmpty || registry.hasKey(for: connection.id) else { throw TBDAgentModelError.noKey }
        try registry.saveConnection(connection, apiKey: key.isEmpty ? nil : key)
        try registry.assign(TBDModelRoute(connectionID: connection.id, model: modelID), to: TBDModelTask.agent.rawValue)
        return connection
    }

    /// The key to test with: the typed one, else the one stored for that endpoint.
    public static func testKey(provider: TBDAgentProvider, endpoint: String, typed: String, registry: TBDModelRegistry) -> String? {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return key }
        let url = normalized(provider.fixedEndpoint ?? endpoint)
        guard let connection = (try? registry.load())?.connections.first(where: { $0.kind == .anthropic && normalized($0.endpoint) == url }) else { return nil }
        return registry.storedKey(for: connection.id)   // sent only to that same endpoint
    }

    /// "Test connection": GET /v1/models/{model}. Checks the key and the model ID without spending tokens.
    public static func testRequest(endpoint: String, apiKey: String, model: String) throws -> URLRequest {
        let base = try TBDModelRegistry.endpointURL(normalized(endpoint))
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains("/") else { throw TBDModelRegistryError.invalidRoute }
        var request = URLRequest(url: base.appendingPathComponent("v1/models").appendingPathComponent(id))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    /// Reads the test response. Only an HTTP 200 counts as working (L27: the exact good outcome).
    public static func interpret(status: Int, body: Data, model: String) -> TBDAgentModelTestResult {
        switch status {
        case 200: return .ok
        case 401, 403: return .badKey
        case 404: return .unknownModel(model.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            return .failed(message.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)")
        }
    }

    /// Runs the test. `transport` is replaceable for tests.
    public static func test(endpoint: String, apiKey: String, model: String,
                            transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) async -> TBDAgentModelTestResult {
        do {
            let (data, response) = try await transport(try testRequest(endpoint: endpoint, apiKey: apiKey, model: model))
            return interpret(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data, model: model)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func normalized(_ endpoint: String) -> String {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
