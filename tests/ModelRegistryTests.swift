import Foundation
// Boundary doubles: compile production registry/cleanup without any live Keychain or model runtime.
public protocol KeyValueStore: Sendable { func getString(_ key: String) throws -> String?; func setString(_ value: String, forKey key: String) throws; func delete(_ key: String) throws }
public final class KeychainKeyValueStore: KeyValueStore, @unchecked Sendable {
    var values: [String: String] = [:]
    public init(service: String) {}
    public func getString(_ key: String) throws -> String? { values[key] }
    public func setString(_ value: String, forKey key: String) throws { values[key] = value }
    public func delete(_ key: String) throws { values[key] = nil }
}
public enum LLMProviderID { case openaiCompatible }
public struct LLMProviderConfig {
    let id: LLMProviderID; let baseURL: URL; let apiKey: String?; let modelName: String; let isLocal: Bool
}
@main struct Tests {
    static func main() async throws {
        let suite = "tbd-model-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = KeychainKeyValueStore(service: "fixture")
        let registry = TBDModelRegistry(defaults: defaults, credentials: secrets)
        precondition(!TBDCleanupPolicy.enabled(voiceNote: false, defaults: defaults))
        precondition(!TBDCleanupPolicy.enabled(voiceNote: true, defaults: defaults))
        defaults.set(true, forKey: TBDCleanupPolicy.chatKey)
        precondition(TBDCleanupPolicy.enabled(voiceNote: false, defaults: defaults))
        precondition(!TBDCleanupPolicy.enabled(voiceNote: true, defaults: defaults))
        for bad in ["http://public.example/v1", "https://user:secret@example.test/v1", "https://example.test/v1?key=secret", "file:///etc/passwd"] {
            do { _ = try TBDModelRegistry.endpointURL(bad); fatalError("Accepted unsafe endpoint") } catch {}
        }
        let c = TBDModelConnection(id: "one", name: "Fixture", endpoint: "https://example.test/v1")
        try registry.saveConnection(c, apiKey: "TEST_SECRET")
        do { try registry.saveConnection(TBDModelConnection(id: "one", name: "Other", endpoint: "https://other.test/v1"), apiKey: "OTHER_SECRET"); fatalError("Allowed credential retarget") } catch {}
        precondition(secrets.values["one"] == "TEST_SECRET")
        try registry.assign(TBDModelRoute(connectionID: "one", model: "cleanup-model"), to: "cleanup")
        try registry.assign(TBDModelRoute(connectionID: "one", model: "vision-model"), to: "screen")
        let clean = try registry.configuration(for: "cleanup")!
        precondition(clean.apiKey == "TEST_SECRET" && clean.modelName == "cleanup-model" && !clean.isLocal)
        let screen = try registry.configuration(for: "screen"); precondition(screen!.modelName == "vision-model")
        let general = try registry.configuration(for: "general"); precondition(general == nil)
        let metadata = String(data: defaults.data(forKey: "tbd.modelRegistry.v1")!, encoding: .utf8)!
        precondition(!metadata.contains("TEST_SECRET"))
        try registry.assign(nil, to: "cleanup")
        let cleared = try registry.configuration(for: "cleanup"); precondition(cleared == nil)
        let raw = "uh my original wording"
        let off = try await TBDTranscriptCleanup.apply(raw: raw, enabled: false) { _ in fatalError("Disabled cleanup invoked model") }
        precondition(off.text == raw && off.raw == raw)
        let success = try await TBDTranscriptCleanup.apply(raw: raw, enabled: true) { _ in "My original wording." }
        precondition(success.raw == raw && success.text == "My original wording.")
        let failure = try await TBDTranscriptCleanup.apply(raw: raw, enabled: true) { _ in throw NSError(domain: "offline", code: 1) }
        precondition(failure.text == raw && !failure.warning.isEmpty)
        let empty = try await TBDTranscriptCleanup.apply(raw: raw, enabled: true) { _ in " " }
        precondition(empty.text == raw)
        do { _ = try await TBDTranscriptCleanup.apply(raw: raw, enabled: true) { _ in throw CancellationError() }; fatalError("Swallowed cancellation") } catch is CancellationError {}
        defaults.set(Data("broken".utf8), forKey: "tbd.modelRegistry.v1")
        do { _ = try registry.configuration(for: "screen"); fatalError("Corrupt config ignored") } catch {}
        print("PASS: endpoint validation, credential isolation, per-task routing, metadata redaction, independent toggles, raw preservation, failure fallback and cancellation")
    }
}
