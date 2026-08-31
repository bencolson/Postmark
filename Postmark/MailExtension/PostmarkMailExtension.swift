import Foundation
import MailKit

/// MailKit message-action extension. It performs NO Mail actions by design —
/// the daemon owns triage. It only signals the arrival of new mail via an App
/// Group message-ID ring plus a best-effort DistributedNotificationCenter poke,
/// so the daemon can run an earlier, rate-limited poll. The 15-minute poll is
/// the source of truth; a dropped signal is always caught by it.
@MainActor
final class PostmarkMailExtension: NSObject, MEExtension {
    func handlerForMessageActions() -> any MEMessageActionHandler {
        MessageActionHandler()
    }
}

/// Reads `message-id` (plus the headers the handler asked for), appends it to
/// the App Group ring the daemon drains, nudges the daemon, and no-ops.
final class MessageActionHandler: NSObject, MEMessageActionHandler {
    private static let suiteName = "group.ltd.colson.postmark"
    private static let newMailIDsKey = "PostmarkNewMailIDs"
    private static let dncName = Notification.Name("PostmarkMailKitNewMail")

    var requiredHeaders: [String] {
        // Mail lowercases headers when fetching them for the handler.
        ["message-id", "from", "subject"]
    }

    func decideAction(
        for message: MEMessage,
        completionHandler: @escaping (MEMessageActionDecision?) -> Void
    ) {
        // `message.headers` may be nil when the full body has not been
        // downloaded; a missing message-id still produces a generic nudge.
        let mid = lookupMessageID(in: message.headers)
        enqueue(mid)
        DistributedNotificationCenter.default().post(
            name: Self.dncName,
            object: nil
        )
        // No-op: never invokeAgainWithBody, never perform a real action.
        completionHandler(nil)
    }

    /// Message-ID lookup is case-insensitive; Mail lowercases the header names
    /// it fetches, so the keys here may not match `message-id` exactly.
    private func lookupMessageID(in headers: [String: [String]]?) -> String? {
        guard let headers else { return nil }
        for (name, values) in headers where name.lowercased() == "message-id" {
            return values.first
        }
        return nil
    }

    /// Bounded ring of seen message IDs shared with the main app via the App
    /// Group suite; oldest are dropped beyond 50.
    private func enqueue(_ messageID: String?) {
        guard let defaults = UserDefaults(suiteName: Self.suiteName) else { return }
        var ids = defaults.stringArray(forKey: Self.newMailIDsKey) ?? []
        if let messageID, !messageID.isEmpty {
            ids.append(messageID)
        }
        if ids.count > 50 {
            ids.removeFirst(ids.count - 50)
        }
        defaults.set(ids, forKey: Self.newMailIDsKey)
    }
}