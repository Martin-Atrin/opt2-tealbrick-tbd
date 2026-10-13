import XCTest
@testable import TBDModels

/// "TBD agent model" setup in Settings → Models and the readiness Chat shows ("No model set").
final class TBDAgentModelSetupTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }
    private func registry() -> (TBDModelRegistry, TBDMemorySecretStore) {
        let name = "tbd.tests.agentmodel.\(UUID().uuidString)"
        suites.append(name)
        let store = TBDMemorySecretStore()
        return (TBDModelRegistry(defaults: UserDefaults(suiteName: name)!, credentials: store), store)
    }

    func testNoRouteIsNoModelSetWithTheSetupStep() throws {
        let (r, _) = registry()
        XCTAssertThrowsError(try TBDAgentModelSetup.resolve(r)) { XCTAssertEqual($0 as? TBDAgentModelError, .noModel) }
        XCTAssertEqual(TBDAgentModelError.noModel.localizedDescription, "No model set for TBD's agent. Set up a model in Settings → Models.")
        let current = TBDAgentModelSetup.current(r)
        XCTAssertEqual(current.provider, .anthropic)
        XCTAssertEqual(current.endpoint, "https://api.anthropic.com")
        XCTAssertEqual(current.model, "claude-opus-5-5")
        XCTAssertFalse(current.hasKey)
    }

    func testSaveCreatesTheAnthropicConnectionAndTheAgentRoute() throws {
        let (r, store) = registry()
        let connection = try TBDAgentModelSetup.save(provider: .anthropic, endpoint: "", apiKey: " key-1 ", model: " claude-opus-5-5 ", registry: r)
        XCTAssertEqual(connection.endpoint, "https://api.anthropic.com")
        XCTAssertEqual(connection.kind, .anthropic)
        XCTAssertEqual(try store.get(connection.id), "key-1")
        let config = try TBDAgentModelSetup.resolve(r)
        XCTAssertEqual(config.model, "claude-opus-5-5")
        XCTAssertEqual(config.apiKey, "key-1")
        XCTAssertEqual(config.baseURL.absoluteString, "https://api.anthropic.com")
        // Other routes are untouched.
        XCTAssertNil(try r.configuration(for: .analysis))
    }

    func testSaveAgainReusesTheConnectionAndKeepsTheKey() throws {
        let (r, store) = registry()
        let first = try TBDAgentModelSetup.save(provider: .anthropic, endpoint: "", apiKey: "key-1", model: "claude-opus-5-5", registry: r)
        let second = try TBDAgentModelSetup.save(provider: .anthropic, endpoint: "", apiKey: "", model: "claude-sonnet-5-5", registry: r)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(try r.load().connections.count, 1)
        XCTAssertEqual(try store.get(first.id), "key-1")
        XCTAssertEqual(try TBDAgentModelSetup.resolve(r).model, "claude-sonnet-5-5")
        XCTAssertTrue(TBDAgentModelSetup.current(r).hasKey)
    }

    func testSaveWithoutAnyKeyIsRefusedAndSetsNothing() throws {
        let (r, _) = registry()
        XCTAssertThrowsError(try TBDAgentModelSetup.save(provider: .anthropic, endpoint: "", apiKey: "", model: "claude-opus-5-5", registry: r)) {
            XCTAssertEqual($0 as? TBDAgentModelError, .noKey)
        }
        XCTAssertNil(try r.configuration(for: .agent))
        XCTAssertThrowsError(try TBDAgentModelSetup.save(provider: .anthropic, endpoint: "", apiKey: "k", model: "  ", registry: r))
        XCTAssertNil(try r.configuration(for: .agent))
    }

    func testCompatibleEndpointAndAnOpenAIRouteAreNotReady() throws {
        let (r, _) = registry()
        try TBDAgentModelSetup.save(provider: .anthropicCompatible, endpoint: "https://gateway.example/anthropic/", apiKey: "k", model: "m", registry: r)
        XCTAssertEqual(try TBDAgentModelSetup.resolve(r).baseURL.absoluteString, "https://gateway.example/anthropic")
        XCTAssertEqual(TBDAgentModelSetup.current(r).provider, .anthropicCompatible)
        let openAI = TBDModelConnection(name: "Local", endpoint: "http://localhost:11434/v1", kind: .openAICompatible)
        try r.saveConnection(openAI, apiKey: nil)
        try r.assign(TBDModelRoute(connectionID: openAI.id, model: "llama"), to: "agent")
        XCTAssertThrowsError(try TBDAgentModelSetup.resolve(r)) { XCTAssertEqual($0 as? TBDAgentModelError, .notAnthropic) }
    }

    func testTestRequestShape() throws {
        let request = try TBDAgentModelSetup.testRequest(endpoint: "https://api.anthropic.com/", apiKey: "k", model: "claude-opus-5-5")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models/claude-opus-5-5")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertThrowsError(try TBDAgentModelSetup.testRequest(endpoint: "http://api.example.com", apiKey: "k", model: "m"))
        XCTAssertThrowsError(try TBDAgentModelSetup.testRequest(endpoint: "https://api.anthropic.com", apiKey: "k", model: "a/b"))
    }

    func testInterpretOnlyAcceptsHTTP200() {
        XCTAssertEqual(TBDAgentModelSetup.interpret(status: 200, body: Data(), model: "m"), .ok)
        XCTAssertEqual(TBDAgentModelSetup.interpret(status: 401, body: Data(), model: "m"), .badKey)
        XCTAssertEqual(TBDAgentModelSetup.interpret(status: 404, body: Data(), model: " m "), .unknownModel("m"))
        let body = Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)
        XCTAssertEqual(TBDAgentModelSetup.interpret(status: 529, body: body, model: "m"), .failed("HTTP 529: Overloaded"))
        XCTAssertEqual(TBDAgentModelSetup.interpret(status: 0, body: Data(), model: "m"), .failed("HTTP 0"))
    }

    func testTestRunsThroughTheTransport() async {
        let ok = await TBDAgentModelSetup.test(endpoint: "https://api.anthropic.com", apiKey: "k", model: "m") { request in
            XCTAssertEqual(request.url?.path, "/v1/models/m")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(ok, .ok)
        let offline = await TBDAgentModelSetup.test(endpoint: "https://api.anthropic.com", apiKey: "k", model: "m") { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(offline.isOK, false)
    }

    func testTestKeyPrefersTypedThenStoredForTheSameEndpointOnly() throws {
        let (r, _) = registry()
        XCTAssertNil(TBDAgentModelSetup.testKey(provider: .anthropic, endpoint: "", typed: "", registry: r))
        try TBDAgentModelSetup.save(provider: .anthropic, endpoint: "", apiKey: "stored", model: "m", registry: r)
        XCTAssertEqual(TBDAgentModelSetup.testKey(provider: .anthropic, endpoint: "", typed: "", registry: r), "stored")
        XCTAssertEqual(TBDAgentModelSetup.testKey(provider: .anthropic, endpoint: "", typed: " typed ", registry: r), "typed")
        XCTAssertNil(TBDAgentModelSetup.testKey(provider: .anthropicCompatible, endpoint: "https://other.example", typed: "", registry: r))
    }
}
