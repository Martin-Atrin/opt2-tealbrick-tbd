import Foundation

public struct TBDChatMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant }
    public let role: Role
    public let content: String
    public init(_ role: Role, _ content: String) { self.role = role; self.content = content }
}

public enum TBDChatClientError: Error, LocalizedError, Equatable {
    case notConfigured(String)
    case http(Int, String)
    case emptyResponse
    public var errorDescription: String? {
        switch self {
        case .notConfigured(let task): return "No model is assigned to \"\(task)\". Assign one in Settings → Models."
        case .http(let code, let body): return "Model request failed (HTTP \(code)). \(body.prefix(200))"
        case .emptyResponse: return "The model returned no text."
        }
    }
}

/// One-shot, non-streaming chat completion over an OpenAI-compatible or Anthropic endpoint.
public struct TBDChatClient: Sendable {
    public let config: TBDModelConfig
    private let session: URLSession
    public init(config: TBDModelConfig, session: URLSession = .shared) { self.config = config; self.session = session }

    /// Resolve the route for a task and build a client, or throw `notConfigured`.
    public static func forTask(_ task: TBDModelTask, registry: TBDModelRegistry = TBDModelRegistry()) throws -> TBDChatClient {
        guard let config = try registry.configuration(for: task) else { throw TBDChatClientError.notConfigured(task.rawValue) }
        return TBDChatClient(config: config)
    }

    public func complete(_ messages: [TBDChatMessage], maxTokens: Int = 4096, temperature: Double? = nil) async throws -> String {
        let request = try makeRequest(messages, maxTokens: maxTokens, temperature: temperature)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw TBDChatClientError.http(code, String(decoding: data, as: UTF8.self)) }
        let text = try Self.parse(data, kind: config.kind)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TBDChatClientError.emptyResponse }
        return text
    }

    func makeRequest(_ messages: [TBDChatMessage], maxTokens: Int, temperature: Double?) throws -> URLRequest {
        var body: [String: Any] = ["model": config.model, "max_tokens": maxTokens]
        if let temperature { body["temperature"] = temperature }
        var request: URLRequest
        switch config.kind {
        case .openAICompatible:
            request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
            body["messages"] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
            if let key = config.apiKey, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            request = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
            let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            if !system.isEmpty { body["system"] = system }
            body["messages"] = messages.filter { $0.role != .system }.map { ["role": $0.role.rawValue, "content": $0.content] }
            if let key = config.apiKey { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parse(_ data: Data, kind: TBDModelKind) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        switch kind {
        case .openAICompatible:
            let choices = json["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any]
            return message?["content"] as? String ?? ""
        case .anthropic:
            let content = json["content"] as? [[String: Any]] ?? []
            return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        }
    }
}
