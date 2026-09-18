import Foundation

struct PostmarkRules: Codable {
    var version: Int
    var polling: PollingConfig
    var provider: ProviderSpec
    var classifier: ClassifierConfig
    var rules: [Rule]
    var fallback: FallbackConfig
    var attachment: AttachmentConfig
}

struct PollingConfig: Codable {
    var intervalMinutes: Int
    var daysWindow: Int
    var enabled: Bool
    var quietHours: QuietHours?

    /// When true, triage considers read messages too. New installs default to
    /// `true` (template). Optional so pre-existing rule files without the key
    /// still decode — those keep their old unread-only behaviour.
    var includeRead: Bool? = nil

    var includeReadOrDefault: Bool { includeRead ?? false }
}

struct QuietHours: Codable {
    var start: String   // "HH:mm"
    var end: String
}

struct ClassifierConfig: Codable {
    var prompt: String
}

struct Rule: Codable, Identifiable {
    var id: String      // matches n8n categories: lead / receipt / low-priority / other
    var label: String
    var action: Action
}

struct Action: Codable {
    var markRead: Bool?
    var move: String?
    var leave: Bool?
    var draftReply: Bool?
    var draftPrompt: String?
    /// Optional per-rule recipient — when set (non-empty), the whole message
    /// (body + every attachment) is forwarded to this address as part of the
    /// rule action. Empty/nil means no forward. Optional so pre-existing rule
    /// files without the key still decode.
    var forwardTo: String? = nil
}

struct FallbackConfig: Codable {
    var action: Action
}

struct AttachmentConfig: Codable {
    var prompt: String
    var forward: ForwardConfig
}

struct ForwardConfig: Codable, Equatable {
    var to: String
    var onlyTypes: [String]
}

/// A single message's triage outcome, for the digest and the analysis store.
struct TriageResult {
    let messageID: String
    let subject: String
    let sender: String      // raw "Name <email>"
    let category: String    // matched rule id, or "fallback"
    let forwarded: [String] // doc categories forwarded to Silo
    let errors: [String]
    let tookAction: Bool    // true if any Mail action was attempted (ticks cooldown)
}

struct TriageRun {
    let started: Date
    let processed: Int
    let byCategory: [String: Int]
    let forwarded: Int
    let skipped: Int
    let errors: [String]
    let results: [TriageResult]
}
