import Foundation

/// Google Gemini streaming client (native /v1beta streamGenerateContent).
final class GeminiClient: AIClient {
    let provider = AIProvider.gemini
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
                    let url = URL(string:
                        "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?key=\(apiKey)&alt=sse"
                    )!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    let body: [String: Any] = [
                        "systemInstruction": ["parts": [["text": systemPrompt]]],
                        "contents": [["role": "user", "parts": [["text": userMessage]]]],
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line + "\n" }
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw AIClientError.requestFailed("HTTP \(code): \(errorBody)")
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let text = GeminiSSE.parse(line: line) else { continue }
                        if !text.isEmpty { continuation.yield(text) }
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

enum GeminiSSE {
    static func parse(line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst("data: ".count))
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String
        else { return nil }
        return text
    }
}
