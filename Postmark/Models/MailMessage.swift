import Foundation

struct MailAttachment: Identifiable {
    let id = UUID()
    let name: String
    let size: Int
    /// Absolute path on disk once the attachment has been saved by the forwarder.
    var savedPath: String?
}

struct MailMessage: Identifiable {
    let id: String          // Message-ID
    let sender: String      // raw "Name <email>"
    let fromName: String
    let fromEmail: String
    let subject: String
    let date: Date
    let isUnread: Bool
    let mailbox: String     // source mailbox, used by CategoryExecutor to move
    let attachments: [MailAttachment]
    var body: String = ""   // filled lazily by MailPoller when needed
}
