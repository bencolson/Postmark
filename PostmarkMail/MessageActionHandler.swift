//
//  MessageActionHandler.swift
//  PostmarkMail
//
//  Created by Ben Colson on 31/08/2026.
//

import Foundation
import MailKit

/// Reads `message-id`, then signals the Postmark daemon by stamping a small
/// signal file inside Mail's container (`~/Library/Containers/com.apple.mail/
/// Data/Library/Postmark/signals.txt`), which the daemon's `TriageTrigger`
/// watches and converts into a rate-limited "poll soon" run. The daemon's
/// scheduled poll remains the source of truth; the signal is fire-and-forget.
///
/// Note: a distributed notification cannot carry the poke here — the appex is
/// sandboxed (ENABLE_APP_SANDBOX) while the daemon is not, and distributed
/// notifications are not delivered across that boundary. A container file
/// crosses it because both processes resolve the SAME physical path: the
/// sandbox maps the appex's home directory onto Mail's container Data root.
/// Always no-ops the MailKit decision — this extension never performs a real
/// Mail action.
class MessageActionHandler: NSObject, MEMessageActionHandler {

    /// Relative to the sandbox home. From inside Mail's container, home IS
    /// `~/Library/Containers/com.apple.mail/Data`, so this resolves to
    /// `.../Data/Library/Postmark/signals.txt` — the path the daemon watches.
    static let signalFilePath = "Library/Postmark/signals.txt"

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
        writeSignal(messageID: mid)

        // No-op: never invokeAgainWithBody, never a real action.
        completionHandler(nil)
    }

    /// Stamp `signals.txt` with `<unixEpoch>\n<messageID>\n`. Best-effort: a
    /// failed write only delays the daemon's next scheduled poll.
    private func writeSignal(messageID: String) {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let url = library.deletingLastPathComponent().appendingPathComponent(Self.signalFilePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let safeID = messageID
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard let data = "\(stamp)\n\(safeID)\n".data(using: .utf8) else { return }
        try? FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.write(data)
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