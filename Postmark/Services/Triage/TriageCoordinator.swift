import Foundation

/// Orchestrates one triage sweep: poll → cooldown filter → classify → apply rules
/// → attachment pass → forward → digest. Runs on the main actor; all AppleScript
/// and LLM work is `await`-ed and lands on MailBridge's background queue.
@MainActor
final class TriageCoordinator {
    private let poller = MailPoller()
    private let forwarder = SiloForwarder()
    private let stores = RulesStore.shared

    /// Fired after each run so the menu-bar icon / digest can react.
    var onRun: ((TriageRun) -> Void)?
    /// Fired for run-fatal errors (missing rules, provider key, Mail down).
    var onFatalError: ((String) -> Void)?

    private var isRunning = false

    /// `scheduled` distinguishes the 15-min timer (gated by polling.enabled) from
    /// a manual "Triage Now" (always runs; if triage is disabled it runs in
    /// shadow mode — classify + log only, no Mail actions).
    func run(scheduled: Bool) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let started = Date()

        guard let rules = stores.load() else {
            ActivityLog.shared.record("Rules missing or invalid — run aborted", kind: .error, level: .error)
            onFatalError?("Rule file is missing or invalid — check Settings → Rules.")
            return
        }
        Notifier.shared.setQuietHours(rules.polling.quietHours)

        // Scheduled runs always execute: live when triage is enabled, shadow
        // (classify + log, no Mail actions) when it is not. This keeps the
        // shadow-mode parity loop observable on a schedule.
        let actingEnabled = rules.polling.enabled
        ActivityLog.shared.record(
            "Run started — \(scheduled ? "scheduled" : "manual"), \(actingEnabled ? "live" : "shadow") mode, provider \(rules.provider.type)/\(rules.provider.model)",
            kind: .app
        )

        // Provider failure is run-fatal: nothing to classify with.
        let client: AIClient
        do {
            client = try AIClientFactory.client(for: rules.provider, keychain: KeychainService())
        } catch {
            let msg = error.localizedDescription
            ActivityLog.shared.record("Provider failure: \(msg)", kind: .error, level: .error)
            onFatalError?(msg)
            return
        }

        let messageClassifier = MessageClassifier(client: client, prompt: rules.classifier.prompt, poller: poller)
        let attachmentClassifier = AttachmentClassifier(client: client, prompt: rules.attachment.prompt)

        let messages: [MailMessage]
        do {
            messages = try await poller.poll(daysWindow: rules.polling.daysWindow, unreadOnly: !rules.polling.includeReadOrDefault)
        } catch {
            ActivityLog.shared.record("Poll failed: \(error.localizedDescription)", kind: .poll, level: .error)
            onFatalError?(error.localizedDescription)
            return
        }

        var results: [TriageResult] = []
        var byCategory: [String: Int] = [:]
        var forwardedCount = 0
        var skipped = 0
        var errors: [String] = []

        for var message in messages {
            if stores.isOnCooldown(messageID: message.id) {
                skipped += 1
                ActivityLog.shared.record("Skipped — on cooldown", kind: .app, level: .debug, messageID: message.id)
                continue
            }

            ActivityLog.shared.record(
                "Seen: \"\(message.subject)\" from \(message.fromName) <\(message.fromEmail)>",
                kind: .poll,
                messageID: message.id
            )

            // 1. Message classification (LLM). Throwing keeps the message out of
            //    cooldown so the next run retries.
            let category: String
            do {
                category = try await messageClassifier.classify(message: &message)
            } catch {
                errors.append("\(message.subject): \(error.localizedDescription)")
                ActivityLog.shared.record(
                    "Classification failed: \(error.localizedDescription)",
                    kind: .classify,
                    level: .error,
                    messageID: message.id
                )
                continue
            }

            let rule = rules.rules.first { $0.id == category }
            let actionRule = rule ?? Rule(id: "fallback", label: "Fallback", action: rules.fallback.action)

            byCategory[actionRule.label, default: 0] += 1
            ActivityLog.shared.record(
                "Classified: \(actionRule.label) (\(actionRule.id))",
                kind: .classify,
                messageID: message.id
            )
            var resultErrors: [String] = []
            var forwarded: [String] = []

            // 2. Attachment pass — runs for every message with attachments,
            //    independent of the message category (mirrors n8n's branch).
            if !message.attachments.isEmpty {
                do {
                    let classified = try await attachmentClassifier.classify(message: message)
                    if actingEnabled {
                        let toForward = classified.compactMap { entry -> (MailAttachment, String)? in
                            guard let att = message.attachments.first(where: { $0.name == entry.filename }) else { return nil }
                            return (att, entry.category)
                        }
                        let outcome = await forwarder.forward(
                            message: message,
                            toForward: toForward,
                            address: stores.siloAddress,
                            onlyTypes: rules.attachment.forward.onlyTypes
                        )
                        forwarded = outcome.forwarded
                        forwardedCount += outcome.forwarded.count
                        outcome.errors.forEach { resultErrors.append($0) }
                    } else {
                        // Shadow mode: log which attachments *would* have gone.
                        forwarded = classified
                            .filter { rules.attachment.forward.onlyTypes.contains($0.category) }
                            .map(\.category)
                        ActivityLog.shared.record(
                            "Shadow: would forward \(forwarded.isEmpty ? "nothing" : forwarded.joined(separator: ", ")) to Silo",
                            kind: .silo,
                            messageID: message.id
                        )
                    }
                } catch {
                    resultErrors.append("attachments: \(error.localizedDescription)")
                    ActivityLog.shared.record(
                        "Attachment pass failed: \(error.localizedDescription)",
                        kind: .silo,
                        level: .error,
                        messageID: message.id
                    )
                }
            }

            // 3. Category route — only in live mode.
            if actingEnabled {
                let executor = CategoryExecutor(client: client, draftPrompt: actionRule.action.draftPrompt)
                let outcome = await executor.execute(rule: actionRule, message: message)
                outcome.errors.forEach { resultErrors.append($0) }
                ActivityLog.shared.record(
                    "Route: \(actionRule.id) (\(actionRule.label))",
                    kind: .action,
                    messageID: message.id
                )
            }

            if !resultErrors.isEmpty { errors.append(contentsOf: resultErrors) }

            let result = TriageResult(
                messageID: message.id,
                subject: message.subject,
                sender: message.sender,
                category: actionRule.id,
                forwarded: forwarded,
                errors: resultErrors,
                tookAction: true
            )
            results.append(result)

            // Cooldown ticks after a successful classification — a provider flake
            // during classification leaves the message un-cooldowned to retry.
            stores.recordProcessed(result: result)
        }

        if skipped > 0 {
            ActivityLog.shared.record("Run finished — \(results.count) processed, \(skipped) skipped (cooldown)", kind: .app)
        } else {
            ActivityLog.shared.record("Run finished — \(results.count) processed", kind: .app)
        }
        if !errors.isEmpty {
            let preview = errors.prefix(3).joined(separator: "; ")
            ActivityLog.shared.record("Run had \(errors.count) error(s): \(preview)", kind: .error, level: .error)
        }

        let run = TriageRun(
            started: started,
            processed: results.count,
            byCategory: byCategory,
            forwarded: forwardedCount,
            skipped: skipped,
            errors: errors,
            results: results
        )
        // Only notify for live runs and manual Triage Now. A scheduled shadow
        // poll (e.g. every minute during parity validation) must stay quiet —
        // the activity window is its record, not notifications.
        if actingEnabled || !scheduled {
            Notifier.shared.postDigest(run)
        }
        onRun?(run)
    }
}