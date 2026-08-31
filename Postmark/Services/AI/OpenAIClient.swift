import Foundation

/// OpenAI-compatible chat completions client. Covers LiteLLM (default), OpenAI,
/// OpenRouter, TrustedTokens and Local AI (LM Studio/Ollama) — all speak the
/// standard `/v1/chat/completions` SSE shape.
final class OpenAIClient: AIClient {
    let provider: AIProvider
    private let baseURL: String
    private let apiKey: String
    private let model: String

    init(baseURL: String, apiKey: String = "", model: String, provider: AIProvider = .openai) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.model = model
        self.provider = provider
    }

    func stream(systemPrompt: String, userMessage: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Tolerate base URLs with or without a trailing `/v1`
                    // (e.g. "http://localhost:4000" vs "http://host:4000/v1").
                    let normalizedBase = baseURL.hasSuffix("/v1") ? baseURL : "\(baseURL)/v1"
                    guard let url = URL(string: "\(normalizedBase)/chat/completions") else {
                        throw AIClientError.requestFailed("Invalid base URL: \(self.baseURL)")
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": [
                            ["role": "system", "content": systemPrompt],
                            ["role": "user", "content": userMessage],
                        ],
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIClientError.requestFailed("No HTTP response")
                    }
                    guard http.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line + "\n" }
                        throw AIClientError.requestFailed("HTTP \(http.statusCode): \(errorBody)")
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        switch OpenAICompatibleStream.parse(line: line) {
                        case .delta(let text): continuation.yield(text)
                        case .done: continuation.finish(); return
                        case .none: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
