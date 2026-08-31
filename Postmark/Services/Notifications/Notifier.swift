import Foundation
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter: one authorization request, then
/// per-run digest + error notifications.
@MainActor
final class Notifier {
    static let shared = Notifier()

    private var authorized = false
    private var quietHours: QuietHours?
    /// Menu-bar Quiet Hours toggle: suppresses ALL digests when set, independent
    /// of the scheduled quiet-hours window in the rules file.
    var forceQuiet = false

    func setQuietHours(_ qh: QuietHours?) {
        quietHours = qh
    }

    /// True when digest notifications should be suppressed right now.
    func isQuietNow() -> Bool {
        if forceQuiet { return true }
        guard let qh = quietHours else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard let s = parseMinutes(qh.start), let e = parseMinutes(qh.end) else { return false }
        if s <= e { return now >= s && now < e }
        return now >= s || now < e  // overnight window
    }

    private func parseMinutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h >= 0, h <= 23, m >= 0, m <= 59 else {
            return nil
        }
        return h * 60 + m
    }

    func requestAuthorizationIfNeeded() async {
        guard !authorized else { return }
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorized = granted
        } catch {
            authorized = false
        }
    }

    func postDigest(_ run: TriageRun) {
        guard authorized, !isQuietNow() else { return }
        guard run.processed > 0 || !run.errors.isEmpty else { return }

        let title: String
        if !run.errors.isEmpty {
            title = "Postmark: \(run.errors.count) error\(run.errors.count == 1 ? "" : "s")"
        } else {
            title = "Postmark: \(run.processed) message\(run.processed == 1 ? "" : "s") triaged"
        }
        let body = digestBody(run)
        post(title: title, body: body)
    }

    func postErrors(_ errors: [String]) {
        guard authorized else { return }
        let title = "Postmark needs attention"
        let body = errors.prefix(3).joined(separator: "\n")
        post(title: title, body: body)
    }

    private func digestBody(_ run: TriageRun) -> String {
        var parts: [String] = []
        for (cat, count) in run.byCategory.sorted(by: { $0.value > $1.value }) {
            parts.append("\(count)× \(cat)")
        }
        if run.forwarded > 0 { parts.append("\(run.forwarded) forwarded to Silo") }
        if run.skipped > 0 { parts.append("\(run.skipped) skipped (cooldown)") }
        if parts.isEmpty { parts.append("no unread messages") }
        return parts.joined(separator: " · ")
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}