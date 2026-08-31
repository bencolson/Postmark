import Foundation

/// Forwards saved attachments to the Silo inbound address (per-user `<token>@mail.silo.day`),
/// resolved via Keychain and gated by build flag (dev vs prod). Refuses to ever
/// address a placeholder.
final class SiloForwarder {
    struct Outcome {
        var forwarded: [String] = []   // document-type categories actually sent
        var errors: [String] = []
    }

    static let placeholderTokens = [
        "REPLACE_WITH_YOUR_Silo_INBOUND_ADDRESS",
        "REPLACE_WITH_YOUR_Silo_DEV_INBOUND_ADDRESS",
    ]

    /// `toForward` maps attachment name → the doc category it was classified into.
    func forward(
        message: MailMessage,
        toForward: [(attachment: MailAttachment, category: String)],
        address: String,
        onlyTypes: [String]
    ) async -> Outcome {
        var outcome = Outcome()
        let eligible = toForward.filter { onlyTypes.contains($0.category) }
        guard !eligible.isEmpty else { return outcome }

        // Runtime guard: never send to a placeholder or an empty address.
        let target = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !Self.placeholderTokens.contains(target) else {
            outcome.errors.append("Silo inbound address not configured — check Settings → Silo. No forward sent.")
            await ActivityLog.shared.record(
                "Silo forward refused — inbound address placeholder/empty",
                kind: .silo,
                level: .warn,
                messageID: message.id
            )
            return outcome
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Postmark-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Save every attachment of the message once; pick the eligible ones.
        var savedPaths: [String: String] = [:]
        do {
            let raw = try await MailBridge.executeAppleScript(MailScripts.saveAttachments(messageID: message.id, to: folder.path))
            for line in raw.components(separatedBy: "\n") {
                let parts = line.split(separator: ":", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let name = String(parts[0])
                let path = String(parts[2])
                if FileManager.default.fileExists(atPath: path) {
                    savedPaths[name] = path
                }
            }
            await ActivityLog.shared.record("Saved \(savedPaths.count) attachment\(savedPaths.count == 1 ? "" : "s") for forward", kind: .silo, messageID: message.id)
        } catch {
            outcome.errors.append("saveAttachments: \(error.localizedDescription)")
            await ActivityLog.shared.record("Attachment save failed: \(error.localizedDescription)", kind: .silo, level: .error, messageID: message.id)
            return outcome
        }

        var attachFiles: [(String, String)] = []
        for entry in eligible {
            if let path = savedPaths[entry.attachment.name] {
                attachFiles.append((path, entry.attachment.name))
                outcome.forwarded.append(entry.category)
            } else {
                outcome.errors.append("attachment not saved on disk: \(entry.attachment.name)")
            }
        }

        guard !attachFiles.isEmpty else { return outcome }

        let subject = "Production docs — \(message.subject)"
        let body = "Auto-forwarded by Postmark. Original sender: \(message.sender)."
        do {
            let r = try await MailBridge.executeAppleScript(
                MailScripts.forwardAttachments(to: target, subject: subject, body: body, attachments: attachFiles)
            )
            if r != "SENDOK" {
                outcome.errors.append("forward: \(r)")
                await ActivityLog.shared.record("Forward failed: \(r)", kind: .silo, level: .error, messageID: message.id)
            } else {
                // Mask the committed address: never log the raw inbound token.
                await ActivityLog.shared.record(
                    "Forwarded to Silo: \(outcome.forwarded.joined(separator: ", ")) — inbound configured",
                    kind: .silo,
                    messageID: message.id
                )
            }
        } catch {
            outcome.errors.append("forward: \(error.localizedDescription)")
            await ActivityLog.shared.record("Forward error: \(error.localizedDescription)", kind: .silo, level: .error, messageID: message.id)
        }

        try? FileManager.default.removeItem(at: folder)
        return outcome
    }
}