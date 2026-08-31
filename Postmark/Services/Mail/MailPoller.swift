import Foundation

/// Polls Apple Mail's Inbox for unread messages (optionally limited to the last
/// `daysWindow` days) and parses them into `MailMessage` values. All AppleScript
/// runs on MailBridge's background queue.
final class MailPoller {
    private let fsString = String(Character(UnicodeScalar(UInt8(31))))
    private let rsString = String(Character(UnicodeScalar(UInt8(30))))

    func poll(daysWindow: Int) async throws -> [MailMessage] {
        guard await MailBridge.isMailRunning() else {
            throw MailBridgeError.mailNotRunning
        }
        let raw = try await MailBridge.executeAppleScript(MailScripts.listUnreadInbox(daysWindow: daysWindow))
        return parse(raw)
    }

    func body(for messageID: String) async throws -> String {
        try await MailBridge.executeAppleScript(MailScripts.messageBody(messageID: messageID))
    }

    // MARK: - Parsing

    private func parse(_ raw: String) -> [MailMessage] {
        guard !raw.isEmpty else { return [] }
        let records = raw.split(separator: rsString, omittingEmptySubsequences: true)
        var messages: [MailMessage] = []
        for record in records {
            let fields = record.split(separator: fsString, maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count >= 5 else { continue }
            let id = String(fields[0])
            let sender = String(fields[1])
            let subject = String(fields[2])
            let epoch = Double(String(fields[3])).flatMap { Date(timeIntervalSince1970: $0) } ?? Date()
            let mailbox = String(fields[4])
            let attachments = parseAttachments(String(fields[5]))
            let (name, email) = parseSender(sender)
            let msg = MailMessage(
                id: id,
                sender: sender,
                fromName: name,
                fromEmail: email,
                subject: subject,
                date: epoch,
                isUnread: true,
                mailbox: mailbox,
                attachments: attachments
            )
            messages.append(msg)
        }
        return messages
    }

    private func parseAttachments(_ raw: String) -> [MailAttachment] {
        guard !raw.isEmpty else { return [] }
        return raw.split(separator: ";", omittingEmptySubsequences: false).compactMap { part in
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            let name = String(pieces[0])
            guard !name.isEmpty, let size = Int(String(pieces[1])) else { return nil }
            return MailAttachment(name: name, size: size)
        }
    }

    /// Apple Mail's `sender` returns "Name <addr>" or "addr (Name)" or "addr".
    private func parseSender(_ raw: String) -> (name: String, email: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lt = s.firstIndex(of: "<"), let gt = s.firstIndex(of: ">"), lt < gt {
            let email = String(s[s.index(after: lt)..<gt])
            let name = s[..<lt].trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? email : name, email)
        }
        if let lp = s.firstIndex(of: "("), let rp = s.firstIndex(of: ")"), lp < rp {
            let name = String(s[s.index(after: lp)..<rp])
            let email = s[..<lp].trimmingCharacters(in: .whitespaces)
            return (name, email)
        }
        return (s, s)
    }
}
