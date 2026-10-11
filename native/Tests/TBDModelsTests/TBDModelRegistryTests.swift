import XCTest
@testable import TBDModels

final class TBDModelRegistryTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }
    private func registry() -> (TBDModelRegistry, TBDMemorySecretStore) {
        let name = "tbd.tests.\(UUID().uuidString)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        let store = TBDMemorySecretStore()
        return (TBDModelRegistry(defaults: defaults, credentials: store), store)
    }

    func testEndpointRules() throws {
        XCTAssertNoThrow(try TBDModelRegistry.endpointURL("https://api.example.com/v1"))
        XCTAssertNoThrow(try TBDModelRegistry.endpointURL("http://localhost:11434/v1"))
        XCTAssertNoThrow(try TBDModelRegistry.endpointURL("http://192.168.1.5:8080/v1"))
        XCTAssertThrowsError(try TBDModelRegistry.endpointURL("http://api.example.com/v1"))
        XCTAssertThrowsError(try TBDModelRegistry.endpointURL("https://user:pw@api.example.com/v1"))
        XCTAssertThrowsError(try TBDModelRegistry.endpointURL("https://api.example.com/v1?key=x"))
    }

    func testRouteResolvesWithKey() throws {
        let (r, store) = registry()
        let c = TBDModelConnection(name: "Anthropic", endpoint: "https://api.anthropic.com", kind: .anthropic)
        try r.saveConnection(c, apiKey: "test-key")
        try r.assign(TBDModelRoute(connectionID: c.id, model: "claude-test"), to: "agent")
        let config = try XCTUnwrap(try r.configuration(for: .agent))
        XCTAssertEqual(config.kind, .anthropic)
        XCTAssertEqual(config.apiKey, "test-key")
        XCTAssertEqual(try store.get(c.id), "test-key")
        XCTAssertNil(try r.configuration(for: .cleanup))
    }

    func testEndpointIsImmutable() throws {
        let (r, _) = registry()
        let c = TBDModelConnection(name: "A", endpoint: "https://a.example.com")
        try r.saveConnection(c, apiKey: nil)
        let moved = TBDModelConnection(id: c.id, name: "A", endpoint: "https://b.example.com")
        XCTAssertThrowsError(try r.saveConnection(moved, apiKey: nil))
    }

    func testUnknownTaskRejected() throws {
        let (r, _) = registry()
        XCTAssertThrowsError(try r.assign(nil, to: "other"))
    }

    func testRemoveConnectionDropsRoutesAndKey() throws {
        let (r, store) = registry()
        let c = TBDModelConnection(name: "A", endpoint: "https://a.example.com")
        try r.saveConnection(c, apiKey: "k")
        try r.assign(TBDModelRoute(connectionID: c.id, model: "m"), to: "general")
        try r.removeConnection(id: c.id)
        XCTAssertNil(try r.configuration(for: .general))
        XCTAssertNil(try store.get(c.id))
    }

    func testAnthropicRequestShape() throws {
        let config = TBDModelConfig(kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "k", model: "m", isLocal: false)
        let req = try TBDChatClient(config: config).makeRequest([.init(.system, "s"), .init(.user, "u")], maxTokens: 10, temperature: nil)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "k")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(body["system"] as? String, "s")
        XCTAssertEqual((body["messages"] as? [[String: String]])?.count, 1)
    }

    func testParseResponses() throws {
        let oa = #"{"choices":[{"message":{"content":"hi"}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try TBDChatClient.parse(oa, kind: .openAICompatible), "hi")
        let an = #"{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}"#.data(using: .utf8)!
        XCTAssertEqual(try TBDChatClient.parse(an, kind: .anthropic), "ab")
    }
}
