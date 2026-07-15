import Foundation

public enum LLMError: Error, Sendable, Equatable {
    case http(status: Int, body: String)
    case transport(String)
    case emptyResponse
}

/// An OpenAI-compatible chat-completions client. The same shape covers Ollama
/// Cloud, OpenRouter, and a local Ollama server — only the base URL, key, and
/// model differ (provider abstraction per the design).
public struct LLMClient: Sendable {
    public struct Provider: Sendable, Equatable {
        public let id: String
        public let name: String
        public let baseURL: String
        public let defaultModel: String
        public let needsKey: Bool
        public let privacyNote: String

        public init(id: String, name: String, baseURL: String, defaultModel: String, needsKey: Bool, privacyNote: String) {
            self.id = id; self.name = name; self.baseURL = baseURL
            self.defaultModel = defaultModel; self.needsKey = needsKey; self.privacyNote = privacyNote
        }
    }

    /// Built-in presets. Default = Ollama Cloud (free tier, zero-data-retention).
    public static let presets: [Provider] = [
        Provider(id: "ollama-cloud", name: "Ollama Cloud (무료·비공개)",
                 baseURL: "https://ollama.com/v1", defaultModel: "gpt-oss:20b",
                 needsKey: true, privacyNote: "무료 · 학습에 사용 안 함(ZDR)"),
        Provider(id: "openrouter", name: "OpenRouter (무료)",
                 baseURL: "https://openrouter.ai/api/v1", defaultModel: "google/gemma-2-9b-it:free",
                 needsKey: true, privacyNote: "무료 · 프롬프트가 학습에 쓰일 수 있음"),
        Provider(id: "local-ollama", name: "로컬 Ollama (오프라인)",
                 baseURL: "http://localhost:11434/v1", defaultModel: "qwen3",
                 needsKey: false, privacyNote: "완전 오프라인 · 비용 0"),
    ]

    public static func preset(id: String) -> Provider? { presets.first { $0.id == id } }

    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(baseURL: String, apiKey: String, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func complete(system: String, user: String, temperature: Double = 0.3) async throws -> String {
        var req = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 120
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw LLMError.transport("no HTTP response") }
        guard (200...299).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            throw LLMError.emptyResponse
        }
        return content
    }
}
