import Foundation

/// Anthropic Messages API streaming client.
final class AnthropicClient: AIClient {
    let provider = AIProvider.anthropic
    private let apiKey: String
    private let model: String

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    func stream(systemPrompt: String, userMessage: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = URL(string: "https://api.anthropic.com/v1/messages")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")

                    var messages: [[String: Any]] = [
                        ["role": "user", "content": [["type": "text", "text": userMessage]]]
                    ]
                    var system: Any = []
                    if !systemPrompt.isEmpty {
                        system = [["role": "system", "content": systemPrompt]]
                        messages = [["role": "system", "content": systemPrompt]] + messages
                    }

                    let body: [String: Any] = [
                        "model": model,
                        "max_tokens": 4096,
                        "stream": true,
                        "messages": messages,
                        "system": system,
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line + "\n" }
                        throw AIClientError.requestFailed("HTTP \(status): \(errorBody)")
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let delta = AnthropicSSE.parse(line: line) else { continue }
                        for text in delta { continuation.yield(text) }
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

enum AnthropicSSE {
    static func parse(line: String) -> [String]? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst("data: ".count))
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "content_block_delta",
              let delta = json["delta"] as? [String: Any],
              let text = delta["text"] as? String, !text.isEmpty
        else { return nil }
        return [text]
    }
}
