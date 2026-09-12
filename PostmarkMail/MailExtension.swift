//
//  MailExtension.swift
//  PostmarkMail
//
//  Created by Ben Colson on 31/08/2026.
//

import MailKit

/// MailKit message-action extension. It performs NO Mail actions by design —
/// the daemon owns triage. It only signals the arrival of new mail to the
/// Postmark daemon via a signal file Mail's container (see
/// `MessageActionHandler`), so the daemon can run an earlier, rate-limited
/// poll. The 15-minute poll is the source of truth; a dropped signal is always
/// caught by it.
class MailExtension: NSObject, MEExtension {

    func handlerForMessageActions() -> MEMessageActionHandler {
        // A fresh handler per factory call; the handler is stateless.
        return MessageActionHandler()
    }
}