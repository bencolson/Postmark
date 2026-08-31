import Foundation

/// Build-safe AppleScript for Mail operations. Every function returns a fully
/// formed script string with arguments escaped via `escapeAppleScript(_:)`.
enum MailScripts {
    private static let fsString: String = String(Character(UnicodeScalar(UInt8(31))))
    private static let rsString: String = String(Character(UnicodeScalar(UInt8(30))))

    /// List unread inbox messages received within the last `daysWindow` days.
    /// Returns records delimited by char(30); fields by char(31), in this order:
    /// messageID, sender, subject, unixEpoch, mailbox, attachments("name=size;...")
    /// No body is fetched here — `messageBody(id:)` does that lazily.
    static func listUnreadInbox(daysWindow: Int) -> String {
        """
        set fs to character id 31
        set rs to character id 30
        set cutoff to (current date) - (\(daysWindow) * 86400)
        set out to ""
        tell application "Mail"
            set msgs to {}
            try
                set msgs to (every message of inbox whose read status = false and date received >= cutoff)
            end try
            repeat with i from 1 to length of msgs
                set m to item i of msgs
                set mid to ""
                try
                    set mid to message id of m
                end try
                set sm to ""
                try
                    set sm to sender of m
                end try
                set subj to ""
                try
                    set subj to subject of m
                end try
                set mb to ""
                try
                    set mb to name of mailbox of m
                end try
                set ep to 0
                try
                    set ep to (date received of m) - (date "1 January 1970")
                end try
                set atts to ""
                try
                    set attList to {}
                    tell m
                        repeat with a in (every attachment of m)
                            set an to ""
                            set asz to 0
                            try
                                set an to name of a
                                set asz to size of a
                            end try
                            set end of attList to (an & "=" & asz)
                        end repeat
                    end tell
                    set oldTID to AppleScript's text item delimiters
                    set AppleScript's text item delimiters to ";"
                    set atts to (attList as string)
                    set AppleScript's text item delimiters to oldTID
                on error
                    set atts to ""
                end try
                set out to out & sanitize(mid) & fs & sanitize(sm) & fs & sanitize(subj) & fs & ep & fs & sanitize(mb) & fs & atts & rs
            end repeat
        end tell
        return out

        on sanitize(s)
            set s to s as string
            set s to my replaceText(s, character id 30, " ")
            set s to my replaceText(s, character id 31, " ")
            set s to my replaceText(s, character id 10, " ")
            set s to my replaceText(s, character id 13, " ")
            return s
        end sanitize

        on replaceText(theText, oldItem, newItem)
            set {tempText, theOutput} to {"", ""}
            set {oldItem, newItem, theOutput} to {oldItem, newItem, theOutput}
            set curDelim to AppleScript's text item delimiters
            set AppleScript's text item delimiters to oldItem
            set theItems to every text item of theText
            set AppleScript's text item delimiters to newItem
            set theOutput to theItems as string
            set AppleScript's text item delimiters to curDelim
            return theOutput
        end replaceText
        """
    }

    /// Fetch the rendered body (`content`) of a message by Message-ID.
    static func messageBody(messageID: String) -> String {
        """
        set mid to "\(_escape(messageID))"
        tell application "Mail"
            try
                set m to first message of inbox whose message id = mid
                return (content of m) as string
            on error
                return ""
            end try
        end tell
        """
    }

    /// Mark a message read by Message-ID.
    static func markRead(messageID: String) -> String {
        """
        tell application "Mail"
            try
                set m to first message of inbox whose message id = "\(_escape(messageID))"
                set read status of m to true
                return "OK"
            on error
                return "NOTFOUND"
            end try
        end tell
        """
    }

    /// Move a message to a mailbox (created if missing).
    static func moveMessage(messageID: String, to mailboxName: String) -> String {
        """
        set mbName to "\(_escape(mailboxName))"
        tell application "Mail"
            try
                set m to first message of inbox whose message id = "\(_escape(messageID))"
            on error
                return "NOTFOUND"
            end try
            try
                move m to mailbox mbName
                return "OK"
            on error
                try
                    make new mailbox with properties {name: mbName}
                    move m to mailbox mbName
                    return "OK"
                on error
                    return "NOMB"
                end try
            end try
        end tell
        """
    }

    /// Save every attachment of a message into a temp folder; returns a newline-
    /// separated list of `filename:size:destPath` triples.
    static func saveAttachments(messageID: String, to folder: String) -> String {
        """
        set dest to "\(_escape(folder))"
        set sep to ":"
        set out to ""
        tell application "Mail"
            try
                set m to first message of inbox whose message id = "\(_escape(messageID))"
            on error
                return ""
            end try
            try
                set attList to every attachment of m
                repeat with a in attList
                    set an to name of a
                    set asz to size of a
                    set ap to dest & "/" & an
                    try
                        save a in (POSIX file dest) as alias
                    on error
                        save a in (POSIX file dest)
                    end try
                    set out to out & an & sep & asz & sep & ap & return
                end repeat
            end try
        end tell
        return out
        """
    }

    private static func _escape(_ s: String) -> String { escapeAppleScript(s) }

    /// Build an outgoing message, attach files, and send it. `attachments` is an
    /// array of (posixPath, filename) pairs.
    static func forwardAttachments(
        to recipient: String, subject: String, body: String, attachments: [(String, String)]
    ) -> String {
        let escapedSubject = escapeAppleScript(subject)
        let escapedBody = escapeAppleScript(body)
        let escapedTo = escapeAppleScript(recipient)
        var attachCmds: [String] = []
        for (path, _) in attachments {
            attachCmds.append(
                "make new attachment with properties {file name:POSIX file \"\(escapeAppleScript(path))\"} at after the last paragraph of content"
            )
        }
        let attachBlock = attachCmds.joined(separator: "\n                ")
        return """
        tell application "Mail"
            set outMsg to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedBody)", visible:false}
            tell outMsg
                make new to recipient with properties {address:"\(escapedTo)"}
                \(attachBlock)
                send outMsg
                return "SENDOK"
            end tell
        end tell
        """
    }

    /// Open a compose window pre-filled and addressed (NOT sent) for a draft reply.
    static func createDraft(to recipient: String, subject: String, body: String) -> String {
        """
        tell application "Mail"
            set outMsg to make new outgoing message with properties {subject:"\(escapeAppleScript(subject))", content:"\(escapeAppleScript(body))", visible:true}
            tell outMsg
                make new to recipient with properties {address:"\(escapeAppleScript(recipient))"}
                activate
            end tell
        end tell
        return "DRAFT_OPENED"
        """
    }

    /// NOTE: char(id 10/13) handling keeps AppleScript strings single-line for the
    /// `NSAppleScript(source:)` construction. FS/RS are stripped so the list
    /// delimiter scheme in `listUnreadInbox` stays intact.
    static let checkMailRunning = """
    tell application "System Events"
        return (name of processes) contains "Mail"
    end tell
    """

    static func escapeAppleScript(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: fsString, with: " ")
        out = out.replacingOccurrences(of: rsString, with: " ")
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\r", with: " ")
        out = out.replacingOccurrences(of: "\n", with: " ")
        return out
    }
}
