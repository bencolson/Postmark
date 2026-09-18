import Foundation

struct MailAttachment: Identifiable {
    let id = UUID()
    let name: String
    let size: Int
    /// Decoded bytes once resolved from the message's MIME source by MailBridge.resolveAttachments.
    var data: Data?
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
    var attachments: [MailAttachment]
    /// True once attachments have been resolved from the message's MIME source;
    /// the poller's AppleScript attachment list is always empty (Mail errors -1728).
    var attachmentsResolved = false
    var body: String = ""   // filled lazily by MailPoller when needed
}
