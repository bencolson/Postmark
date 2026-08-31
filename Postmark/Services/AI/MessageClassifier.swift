import Foundation

/// Mirrors n8n's message categorizer: runs the `classifier.prompt` (the verbatim
/// n8n `email-categorisation` prompt) against the message and returns the
/// matched rule id, or nil to fall through to the fallback rule.
final class MessageClassifier {
    /// n8n's Parse Category iterates categories in this exact order, using
    /// substring matching (`includes`). Replicate it so shadow-mode parity
    /// holds: a response containing "low-priority" is decided before "lead", etc.
    private static let matchOrder = ["low-priority", "lead", "receipt", "other"]

    private let client: AIClient
    private let prompt: String
    private let poller: MailPoller

    init(client: AIClient, prompt: String, poller: MailPoller) {
        self.client = client
        self.prompt = prompt
        self.poller = poller
    }

    func classify(message: inout MailMessage) async throws -> String {
        if message.body.isEmpty {
            message.body = try await poller.body(for: message.id)
        }
        let bodyExcerpt = String(message.body.prefix(500))
        let userMessage = prompt
            .replacingOccurrences(of: "{{subject}}", with: message.subject)
            .replacingOccurrences(of: "{{fromName}}", with: message.fromName)
            .replacingOccurrences(of: "{{fromEmail}}", with: message.fromEmail)
            .replacingOccurrences(of: "{{body}}", with: bodyExcerpt)

        let raw = try await client.complete(systemPrompt: "", userMessage: userMessage).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        for cat in Self.matchOrder where raw.contains(cat) {
            return cat
        }
        return "other"
    }
}
