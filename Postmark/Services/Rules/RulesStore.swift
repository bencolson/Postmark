import Foundation

/// Loads, validates, mutates and persists `PostmarkRules.json`, and owns the
/// per-message cooldown log (Message-ID → attempted-at timestamp).
@MainActor
final class RulesStore {
    static let shared = RulesStore()
    private init() {}

    private let keychain = KeychainService()
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Postmark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("PostmarkRules.json")
    }()

    private let templateURL: URL? = {
        Bundle.main.url(forResource: "PostmarkRules", withExtension: "json.template")
    }()

    /// Built-in last-resort rules used only when the bundled template is
    /// missing — constructed through the Codable types so it always decodes.
    /// Never trappable: the force-unwrap this replaces crashed the app at
    /// launch when the template was absent from the bundle.
    static var fallbackRulesJSON: String? {
        let rules = PostmarkRules(
            version: 1,
            polling: PollingConfig(
                intervalMinutes: 15,
                daysWindow: 3,
                enabled: false,
                quietHours: nil
            ),
            provider: ProviderSpec(
                type: "litellm",
                model: "openrouter/laguna-s-2.1",
                baseURL: "http://localhost:4000/v1"
            ),
            classifier: ClassifierConfig(
                prompt: "You are a mail triage assistant. Classify the email into exactly one category: lead, receipt, low-priority, other. Reply with only the category word."
            ),
            rules: [
                Rule(id: "lead", label: "Lead", action: Action(markRead: false, move: nil, leave: false, draftReply: true, draftPrompt: nil)),
                Rule(id: "receipt", label: "Receipt", action: Action(markRead: true, move: "Receipts & Bookkeeping", leave: false, draftReply: false, draftPrompt: nil)),
                Rule(id: "low-priority", label: "Low Priority", action: Action(markRead: false, move: "Low Priority", leave: false, draftReply: false, draftPrompt: nil)),
                Rule(id: "other", label: "Other", action: Action(markRead: false, move: nil, leave: true, draftReply: false, draftPrompt: nil)),
            ],
            fallback: FallbackConfig(action: Action(markRead: false, move: nil, leave: true, draftReply: false, draftPrompt: nil)),
            attachment: AttachmentConfig(
                prompt: "Classify each attached file into one of: Call Sheets, Movement Orders, Risk Assessments, Storyboards, Treatments, Specs, Other, skip. Reply as a JSON array with filename and category fields.",
                forward: ForwardConfig(
                    to: "REPLACE_WITH_YOUR_Silo_INBOUND_ADDRESS",
                    devTo: "REPLACE_WITH_YOUR_Silo_DEV_INBOUND_ADDRESS",
                    onlyTypes: ["Call Sheets", "Movement Orders", "Risk Assessments", "Storyboards", "Treatments", "Specs"]
                )
            )
        )
        guard let data = try? JSONEncoder().encode(rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static let placeholderTokens = [
        "REPLACE_WITH_YOUR_Silo_INBOUND_ADDRESS",
        "REPLACE_WITH_YOUR_Silo_DEV_INBOUND_ADDRESS",
    ]

    // MARK: - Load / validate

    var rules: PostmarkRules? {
        load()
    }

    func load() -> PostmarkRules? {
        let url = resolvedURL()
        guard let data = try? Data(contentsOf: url) else {
            ActivityLog.shared.record("Rules file unreadable — run aborted", kind: .error, level: .error)
            return nil
        }
        let decoder = JSONDecoder()
        guard let rules = try? decoder.decode(PostmarkRules.self, from: data) else {
            ActivityLog.shared.record("Rules failed to decode — check Settings → Rules", kind: .error, level: .error)
            return nil
        }
        guard validate(rules: rules) else {
            ActivityLog.shared.record("Rules failed validation — check Settings → Rules", kind: .error, level: .error)
            return nil
        }
        return rules
    }

    /// Seed the user rule file from the bundled template on first launch,
    /// falling back to a built-in rules payload if the template is missing.
    private func resolvedURL() -> URL {
        if FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }
        if let templateURL,
           let data = try? Data(contentsOf: templateURL) {
            try? data.write(to: fileURL, options: .atomic)
            ActivityLog.shared.record("Seeded rules file from bundled template", kind: .app)
        } else if let fallback = Self.fallbackRulesJSON {
            try? fallback.data(using: .utf8)?.write(to: fileURL, options: .atomic)
            ActivityLog.shared.record("Rules template missing — wrote built-in fallback rules", kind: .error, level: .error)
        }
        return fileURL
    }

    private func validate(rules: PostmarkRules) -> Bool {
        guard rules.version == 1 else { return false }
        let ids = rules.rules.map(\.id)
        guard Set(ids).count == ids.count, !ids.isEmpty else { return false }
        let validIDs = Set(ids)
        guard rules.rules.allSatisfy({ validateAction($0.action, ids: validIDs) }) else { return false }
        guard validateAction(rules.fallback.action, ids: validIDs) else { return false }
        guard !rules.classifier.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !rules.attachment.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    private func validateAction(_ action: Action, ids: Set<String>) -> Bool {
        if let move = action.move, move.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if action.draftPrompt != nil, !(action.draftReply ?? false) { return false }
        return true
    }

    // MARK: - Mutation

    func save(rules: PostmarkRules) throws {
        let data = try JSONEncoder().encode(rules)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Cooldown / analysis (SQLite-backed)

    /// True when the message was already processed within the TTL window.
    func isOnCooldown(messageID: String) -> Bool {
        AnalysisStore.shared.isOnCooldown(messageID: messageID)
    }

    /// Record a successful triage outcome — ticks the cooldown and stores the
    /// analysis row. Only called after classification succeeds, so a provider
    /// flake leaves the message un-ticked to retry next run.
    func recordProcessed(result: TriageResult) {
        AnalysisStore.shared.recordProcessed(
            messageID: result.messageID,
            subject: result.subject,
            sender: result.sender,
            category: result.category,
            forwarded: result.forwarded,
            errors: result.errors,
            tookAction: result.tookAction
        )
        ActivityLog.shared.record("Cooldown ticked", kind: .app, level: .debug, messageID: result.messageID)
    }

    /// Dev-only: empty the analysis/cooldown database.
    func clearAnalysis() {
        AnalysisStore.shared.clearAll()
        ActivityLog.shared.record("Cooldown & analysis database cleared", kind: .app)
    }

    // MARK: - Silo address resolution

    /// Prod only: a debug build resolves `devTo`, a release build resolves `to`.
    /// The caller asserts the resolved address is non-empty and not a placeholder
    /// before forwarding (see SiloForwarder).
    var siloAddress: String {
        #if DEBUG
        return keychain.getKey(label: KeychainService.siloInboundDevLabel)
            ?? keychain.getKey(label: KeychainService.siloInboundLabel) ?? ""
        #else
        return keychain.getKey(label: KeychainService.siloInboundLabel)
            ?? keychain.getKey(label: KeychainService.siloInboundDevLabel) ?? ""
        #endif
    }
}
