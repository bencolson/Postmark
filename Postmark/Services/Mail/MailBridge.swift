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
    static func executeAppleScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: MailBridgeError.scriptFailed("Failed to create script"))
                    return
                }
                let result = script.executeAndReturnError(&error)
                if let error = error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    continuation.resume(throwing: MailBridgeError.scriptFailed(message))
                } else {
                    continuation.resume(returning: result.stringValue ?? "")
                }
            }
        }
    }

    static func isMailRunning() async -> Bool {
        do {
            let result = try await executeAppleScript(MailScripts.checkMailRunning)
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