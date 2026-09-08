import Foundation

/// Applies a matched rule's action (move mailbox, mark read, optionally draft a
/// reply) via Mail AppleScript. Returns a list of error strings (empty if all
/// sub-actions succeeded) and whether any action was attempted.
final class CategoryExecutor {
    private let client: AIClient?
    private let draftPrompt: String?
    private let forwarder: SiloForwarder

    init(client: AIClient?, draftPrompt: String?, forwarder: SiloForwarder = SiloForwarder()) {
        self.client = client
        self.draftPrompt = draftPrompt
        self.forwarder = forwarder
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
                if r == "NOTFOUND" {
                    await ActivityLog.shared.record("Message not found — move skipped", kind: .action, level: .warn, messageID: message.id)
                } else if r != "OK" {
                    errors.append("move failed: \(r)")
                    await ActivityLog.shared.record("Move to \"\(move)\" failed: \(r)", kind: .action, level: .error, messageID: message.id)
                } else {
                    await ActivityLog.shared.record("Moved to \"\(move)\"", kind: .action, messageID: message.id)
                }
            } catch {
                errors.append("move: \(error.localizedDescription)")
                await ActivityLog.shared.record("Move error: \(error.localizedDescription)", kind: .action, level: .error, messageID: message.id)
            }
        }

        if action.markRead == true {
            attempted = true
            do {
                let r = try await MailBridge.executeAppleScript(MailScripts.markRead(messageID: message.id))
                if r == "NOTFOUND" {
                    await ActivityLog.shared.record("Message not found — mark-read skipped", kind: .action, level: .warn, messageID: message.id)
                } else if r != "OK" {
                    errors.append("markRead: \(r)")
                    await ActivityLog.shared.record("Mark-read failed: \(r)", kind: .action, level: .error, messageID: message.id)
                } else {
                    await ActivityLog.shared.record("Marked read", kind: .action, messageID: message.id)
                }
            } catch {
                errors.append("markRead: \(error.localizedDescription)")
                await ActivityLog.shared.record("Mark-read error: \(error.localizedDescription)", kind: .action, level: .error, messageID: message.id)
            }
        }

        if action.leave == true {
            // No Mail mutation; still counts as "handled" (no action attempted,
            // so cooldown is NOT ticked by this branch alone — the caller ticks
            // based on classification success).
            await ActivityLog.shared.record("Left in inbox (leave rule)", kind: .action, messageID: message.id)
        }

        if action.draftReply == true, let prompt = draftPrompt, let client {
            attempted = true
            await draftReply(message: message, using: client, prompt: prompt, errors: &errors)
        }

        if let forwardTo = action.forwardTo?.trimmingCharacters(in: .whitespacesAndNewlines), !forwardTo.isEmpty {
            attempted = true
            await ActivityLog.shared.record("Forwarding message + attachments to <\(forwardTo)>", kind: .silo, messageID: message.id)
            let outcome = await forwarder.forwardWholeMessage(message: message, to: forwardTo)
            outcome.errors.forEach { errors.append($0) }
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
            _ = try await MailBridge.executeAppleScript(
                MailScripts.createDraft(to: message.fromEmail, subject: subject, body: reply)
            )
            await ActivityLog.shared.record("Draft created to <\(message.fromEmail)>", kind: .action, messageID: message.id)
        } catch {
            errors.append("draftReply: \(error.localizedDescription)")
            await ActivityLog.shared.record("Draft failed: \(error.localizedDescription)", kind: .action, level: .error, messageID: message.id)
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
