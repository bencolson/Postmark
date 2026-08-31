import Foundation
import UniformTypeIdentifiers

/// Mirrors n8n's `Build Classification Prompt` + parse: classifies every
/// attachment of a message in a single LLM call using the verbatim
/// `attachment.prompt` template, and parses the JSON array reply.
final class AttachmentClassifier {
    private let client: AIClient
    private let prompt: String

    init(client: AIClient, prompt: String) {
        self.client = client
        self.prompt = prompt
    }

    /// One call per message. Returns per-attachment (filename, category, date?).
    func classify(message: MailMessage) async throws -> [(filename: String, category: String, date: String?)] {
        let receivedDate = ISO8601DateFormatter().string(from: message.date)
        let bodyExcerpt = String(message.body.prefix(1000))

        let list = message.attachments.enumerated().map { idx, att in
            let type = Self.mimeType(for: att.name)
            return "\(idx + 1). filename: \"\(att.name)\", type: \(type)"
        }.joined(separator: "\n")

        let userMessage = prompt
            .replacingOccurrences(of: "{{receivedDate}}", with: receivedDate)
            .replacingOccurrences(of: "{{subject}}", with: message.subject)
            .replacingOccurrences(of: "{{fromName}}", with: message.fromName)
            .replacingOccurrences(of: "{{fromEmail}}", with: message.fromEmail)
            .replacingOccurrences(of: "{{bodyExcerpt}}", with: bodyExcerpt)
            .replacingOccurrences(of: "{{attachments}}", with: list.isEmpty ? "(none)" : list)

        let raw = try await client.complete(systemPrompt: "", userMessage: userMessage)

        let results = parseResponse(raw, attachments: message.attachments)
        // Any attachment not returned by the LLM defaults to "skip".
        return message.attachments.map { att in
            results.first { $0.filename == att.name }
                ?? (att.name, "skip", nil)
        }
    }

    private func parseResponse(_ raw: String, attachments: [MailAttachment]) -> [(filename: String, category: String, date: String?)] {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        let allowed = ["Call Sheets", "Movement Orders", "Risk Assessments", "Storyboards", "Treatments", "Specs", "Other", "skip"]

        return json.compactMap { entry in
            guard let filename = entry["filename"] as? String,
                  let category = entry["category"] as? String,
                  allowed.contains(category)
            else { return nil }
            let date = (entry["date"] as? String).flatMap { isValidDate($0) ? $0 : nil }
            return (filename, category, date)
        }
    }

    private func isValidDate(_ s: String) -> Bool {
        guard s.count == 10 else { return false }
        let parts = s.split(separator: "-", maxSplits: 2)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { Int($0) != nil }
    }

    private static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(tag: ext, tagClass: .filenameExtension, conformingTo: nil),
              let mime = type.preferredMIMEType, !mime.isEmpty
        else { return "application/octet-stream" }
        return mime
    }
}
