import Foundation

protocol AIClient {
    var provider: AIProvider { get }

    /// Streams the assistant's reply as incremental text deltas. Each yielded
    /// chunk is new text to append to whatever has already been received.
    func stream(systemPrompt: String, userMessage: String) -> AsyncThrowingStream<String, Error>
}

extension AIClient {
    /// Fallback for callers that want the full reply as one string.
    func complete(systemPrompt: String, userMessage: String) async throws -> String {
        var result = ""
        for try await chunk in stream(systemPrompt: systemPrompt, userMessage: userMessage) {
            result += chunk
        }
        return result
    }
}

enum AIClientError: LocalizedError, Equatable {
    case missingAPIKey(String)
    case requestFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let label):
            return "No API key configured for '\(label)'. Add one in Settings → Providers."
        case .requestFailed(let msg):
            return "API request failed: \(msg)"
        case .invalidResponse(let msg):
            return "Invalid API response: \(msg)"
        }
    }
}

/// Shared parser for OpenAI-compatible SSE chunks ("data: {...}" lines, with the
/// `[DONE]` sentinel). Emits deltas extracted from `choices[0].delta.content`.
enum OpenAICompatibleStream {
    static func parse(line: String) -> SSEvent? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst("data: ".count))
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty
        else { return nil }
        return .delta(content)
    }
}

enum SSEvent {
    case delta(String)
    case done
}
