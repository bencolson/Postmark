import Foundation

/// Applies a matched rule's action (move mailbox, mark read, optionally draft a
/// reply) via Mail AppleScript. Returns a list of error strings (empty if all
/// sub-actions succeeded) and whether any action was attempted.
final class CategoryExecutor {
    private let client: AIClient?
    private let draftPrompt: String?

    init(client: AIClient?, draftPrompt: String?) {
        self.client = client
        self.draftPrompt = draftPrompt
    }

    struct Result {
        let attempted: Bool
        let errors: [String]
    }

    func execute(rule: Rule, message: MailMessage) async -> Result {
        var errors: [String] = []
        var attempted = false

        let action = rule.action

        if let move = action.move {
            attempted = true
            do {
                let r = try await MailBridge.executeAppleScript(MailScripts.moveMessage(messageID: message.id, to: move))
                if r != "OK" { errors.append("move failed: \(r)") }
            } catch { errors.append("move: \(error.localizedDescription)") }
        }

        if action.markRead == true {
            attempted = true
            do {
                let r = try await MailBridge.executeAppleScript(MailScripts.markRead(messageID: message.id))
                if r != "OK" { errors.append("markRead: \(r)") }
            } catch { errors.append("markRead: \(error.localizedDescription)") }
        }

        if action.leave == true {
            // No Mail mutation; still counts as "handled" (no action attempted,
            // so cooldown is NOT ticked by this branch alone — the caller ticks
            // based on classification success).
        }

        if action.draftReply == true, let prompt = draftPrompt, let client {
            attempted = true
            await draftReply(message: message, using: client, prompt: prompt, errors: &errors)
        }

        return Result(attempted: attempted, errors: errors)
    }

    private func draftReply(message: MailMessage, using client: AIClient, prompt: String, errors: inout [String]) async {
        let bodyExcerpt = String(message.body.prefix(500))
        // n8n's AI Agent sends the *entire* prompt+tended message as one block.
        // `draftPrompt` is that prompt with a {{body}} slot; substitute and send
        // as a single user message (empty system prompt, matching n8n).
        let userMessage = prompt.replacingOccurrences(of: "{{body}}", with: bodyExcerpt)
        do {
            let raw = try await client.complete(systemPrompt: "", userMessage: userMessage)
            let reply = extractSuggestedReply(raw) ?? raw
            let subject = message.subject.hasPrefix("Re: ") || message.subject.uppercased().hasPrefix("RE:")
                ? message.subject
                : "Re: \(message.subject)"
            try await MailBridge.executeAppleScript(
                MailScripts.createDraft(to: message.fromEmail, subject: subject, body: reply)
            )
        } catch {
            errors.append("draftReply: \(error.localizedDescription)")
        }
    }

    /// Parse `{"suggested_reply": "..."}` out of the LLM response; return nil if
    /// the shape doesn't match so the raw text is drafted instead.
    private func extractSuggestedReply(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reply = json["suggested_reply"] as? String
        else { return nil }
        return reply
    }
}
