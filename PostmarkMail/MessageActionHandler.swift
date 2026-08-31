//
//  MessageActionHandler.swift
//  PostmarkMail
//
//  Created by Ben Colson on 31/08/2026.
//

import Foundation
import MailKit

/// Reads `message-id`, then signals the Postmark daemon with a
/// DistributedNotificationCenter poke carrying the ID in `userInfo` (the
/// daemon's `TriageTrigger` observes it and runs a rate-limited poll). Always
/// no-ops the MailKit decision — this extension never performs a real Mail
/// action. If the poke is dropped, the daemon's own poll (a scheduled shadow
/// or live poll) is the backstop.
class MessageActionHandler: NSObject, MEMessageActionHandler {

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
}