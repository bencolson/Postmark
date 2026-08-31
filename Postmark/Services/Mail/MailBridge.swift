import Foundation
import AppKit

enum MailBridgeError: LocalizedError {
    case scriptFailed(String)
    case mailNotRunning
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg):
            return "AppleScript error: \(msg)"
        case .mailNotRunning:
            return "Mail is not running."
        case .parseError(let msg):
            return "Failed to parse Mail context: \(msg)"
        }
    }
}

final class MailBridge {
    static let shared = MailBridge()
    private init() {}

    /// Execute an AppleScript source string on a background queue. Returns the
    /// raw result string (which may be empty for statements with no return).
    ///
    /// A timeout guards against automation permission prompts: when the app has
    /// not been granted Automation (Apple Events) access to Mail or System
    /// Events, the first AppleScript call blocks indefinitely waiting on TCC.
    /// Failing fast with an actionable error keeps the daemon responsive and
    /// surfaces the fix in the Activity window. Exactly one resume path wins —
    /// if the deadline fires, the still-running script's result is discarded.
    static func executeAppleScript(_ source: String, timeout: TimeInterval = 40) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let lock = NSLock()
            let finish: (Result<String, Error>) -> Void = { result in
                lock.lock()
                if finished { lock.unlock(); return }
                finished = true
                lock.unlock()
                continuation.resume(with: result)
            }

            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    finish(.failure(MailBridgeError.scriptFailed("Failed to create script")))
                    return
                }
                let result = script.executeAndReturnError(&error)
                if let error = error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    finish(.failure(MailBridgeError.scriptFailed(message)))
                } else {
                    finish(.success(result.stringValue ?? ""))
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                finish(.failure(MailBridgeError.scriptFailed(
                    "Mail automation did not respond within \(Int(timeout))s — grant Postmark Automation access to Mail under System Settings → Privacy & Security → Automation"
                )))
            }
        }
    }

    /// Lightweight Mail liveness probe; fails fast so a denied Automation
    /// permission surfaces as a poll warning instead of a silent hang.
    static func isMailRunning() async -> Bool {
        do {
            let result = try await executeAppleScript(MailScripts.checkMailRunning, timeout: 10)
            return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
        } catch {
            return false
        }
    }

    @MainActor
    static func activateMail() {
        if let mailApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first {
            mailApp.activate()
        }
    }
}