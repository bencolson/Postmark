import Foundation

/// MailKit fast path: the `PostmarkMail` appex pokes a DistributedNotification
/// Center notification carrying the message ID in `userInfo`. This observer
/// converts that into an earlier, debounced, rate-limited triage run. The
/// poll (live or shadow, on the rules schedule) is the source of truth and
/// the backstop for dropped signals, a closed Mail, or a disabled extension.
@MainActor
final class TriageTrigger {
    static let dncName = Notification.Name("PostmarkMailKitNewMail")

    private let coordinator: TriageCoordinator
    private var observer: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var lastTriggerRun: Date?

    /// Signals arriving closer together than this collapse into one run.
    private let debounceInterval: TimeInterval = 20
    /// Minimum gap between MailKit-triggered runs.
    private let rateLimitInterval: TimeInterval = 60

    init(coordinator: TriageCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.dncName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                let id = (notification.userInfo?["messageID"] as? String) ?? ""
                self?.nudge(messageID: id)
            }
        }
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Signal handling

    private func nudge(messageID: String) {
        if messageID.isEmpty {
            ActivityLog.shared.record("MailKit signal (no message ID)", kind: .app, level: .debug)
        } else {
            ActivityLog.shared.record("Trigger: MailKit signal (\(messageID))", kind: .app, level: .debug)
        }
        scheduleRun()
    }

    private func scheduleRun() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }

            let now = Date()
            if let last = self.lastTriggerRun,
               now.timeIntervalSince(last) < self.rateLimitInterval {
                ActivityLog.shared.record(
                    "MailKit run rate-limited (\(Int(now.timeIntervalSince(last)))s since last)",
                    kind: .app,
                    level: .debug
                )
                return
            }
            self.lastTriggerRun = now
            ActivityLog.shared.record("MailKit-triggered triage run", kind: .app)
            await self.coordinator.run(scheduled: false)
        }
    }
}