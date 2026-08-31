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

    private let templateURL: URL = {
        Bundle.main.url(forResource: "PostmarkRules", withExtension: "json.template")!
    }()

    private let cooldownURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Postmark", isDirectory: true)
        return dir.appendingPathComponent("cooldown.json")
    }()

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

    /// Seed the user rule file from the bundled template on first launch.
    private func resolvedURL() -> URL {
        if FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }
        if let data = try? Data(contentsOf: templateURL) {
            try? data.write(to: fileURL, options: .atomic)
            ActivityLog.shared.record("Seeded rules file from bundled template", kind: .app)
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

    // MARK: - Cooldown (Message-ID → attempted-at)

    private var cooldown: [String: Date] = [:]
    private var cooldownLoaded = false

    private func loadCooldown() {
        guard !cooldownLoaded else { return }
        cooldownLoaded = true
        guard let data = try? Data(contentsOf: cooldownURL),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return }
        cooldown = decoded
    }

    private func persistCooldown() {
        loadCooldown()
        guard let data = try? JSONEncoder().encode(cooldown) else { return }
        try? data.write(to: cooldownURL, options: .atomic)
    }

    let cooldownTTL: TimeInterval = 24 * 60 * 60

    /// True when the message was already attempted within the TTL window.
    func isOnCooldown(messageID: String) -> Bool {
        loadCooldown()
        guard let last = cooldown[messageID] else { return false }
        return Date().timeIntervalSince(last) < cooldownTTL
    }

    /// Tick the cooldown for a message, recording that an action was attempted
    /// (success or not). If no action was attempted, the message is retried next run.
    func recordAttempt(messageID: String) {
        loadCooldown()
        cooldown[messageID] = Date()
        persistCooldown()
        ActivityLog.shared.record("Cooldown ticked", kind: .app, level: .debug, messageID: messageID)
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
