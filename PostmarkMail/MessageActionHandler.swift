//
//  MessageActionHandler.swift
//  PostmarkMail
//
//  Created by Ben Colson on 31/08/2026.
//

import Foundation
import MailKit

/// Reads `message-id`, then signals the Postmark daemon two ways:
/// 1. A DistributedNotificationCenter poke with the message ID in `userInfo`
///    (instant; the daemon observes it directly).
/// 2. An App Group message-ID ring for durability/catch-up; the daemon drains
///    the group container's preferences plist at a deterministic path.
/// Always no-ops the MailKit decision — this extension never performs a real
/// Mail action.
class MessageActionHandler: NSObject, MEMessageActionHandler {

    static let suiteName = "group.ltd.colson.postmark"
    static let newMailIDsKey = "PostmarkNewMailIDs"
    static let dncName = "PostmarkMailKitNewMail"

    var requiredHeaders: [String] {
        // Mail lowercases the header names it fetches for the handler.
        ["message-id", "from", "subject"]
    }

    func decideAction(
        for message: MEMessage,
        completionHandler: @escaping (MEMessageActionDecision?) -> Void
    ) {
        // `message.headers` may be nil or a subset when the body is not fully
        // downloaded; a missing message-id still produces a generic nudge so
        // the daemon's "poll soon" path fires.
        let mid = lookupMessageID(in: message.headers) ?? ""
        enqueue(mid)

        DistributedNotificationCenter.default().post(
            name: Notification.Name(Self.dncName),
            object: nil,
            userInfo: mid.isEmpty ? nil : ["messageID": mid]
        )

        // No-op: never invokeAgainWithBody, never a real action.
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
    private func enqueue(_ messageID: String) {
        guard let defaults = UserDefaults(suiteName: Self.suiteName) else { return }
        var ids = defaults.stringArray(forKey: Self.newMailIDsKey) ?? []
        if !messageID.isEmpty {
            ids.append(messageID)
        }
        if ids.count > 50 {
            ids.removeFirst(ids.count - 50)
        }
        defaults.set(ids, forKey: Self.newMailIDsKey)
    }
}