import Foundation

/// MailKit fast path: the `PostmarkMail` appex signals new mail via a
/// DistributedNotificationCenter poke plus an App Group message-ID ring. This
/// observer converts that into an earlier, debounced, rate-limited triage run.
/// The 15-minute poll remains the source of truth and the backstop for dropped
/// signals, a closed Mail, a disabled extension, or a suite-write race.
@MainActor
final class TriageTrigger {
    static let suiteName = "group.ltd.colson.postmark"
    static let newMailIDsKey = "PostmarkNewMailIDs"
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
                let ids = (notification.userInfo?["messageID"] as? String)
                    .flatMap { $0.isEmpty ? nil : [$0] } ?? []
                self?.nudge(liveMessageIDs: ids)
            }
        }
        // Catch-up: drain anything the appex queued while the daemon was not
        // running (extension enabled but app quit, for example). Silent when
        // there is nothing queued.
        let pending = drain()
        if !pending.isEmpty {
            nudge(liveMessageIDs: pending)
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

    private func nudge(liveMessageIDs: [String] = []) {
        let ids = drain() + liveMessageIDs
        if ids.isEmpty {
            ActivityLog.shared.record("MailKit signal (no message ID)", kind: .app, level: .debug)
        } else {
            for id in ids {
                ActivityLog.shared.record("Trigger: MailKit signal (\(id))", kind: .app, level: .debug)
            }
        }
        scheduleRun()
    }

    /// Removes and returns the queued message IDs. The app is not sandboxed, so
    /// its own `UserDefaults(suiteName:)` domain cannot see the sandboxed
    /// appex's App Group suite — the appex writes into the group container, so
    /// drain that file directly (the path is deterministic). Also drain the
    /// plain-suite domain in case a sandboxed app build ever ships.
    private func drain() -> [String] {
        var ids: [String] = []

        let groupContainer = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(Self.suiteName)")
            .appendingPathComponent("Library/Preferences/\(Self.suiteName).plist")
        if let data = try? Data(contentsOf: groupContainer),
           let plist = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ) as? [String: Any],
           let suiteIDs = plist[Self.newMailIDsKey] as? [String] {
            ids.append(contentsOf: suiteIDs)
            try? FileManager.default.removeItem(at: groupContainer)
        }

        if let defaults = UserDefaults(suiteName: Self.suiteName) {
            let suiteIDs = defaults.stringArray(forKey: Self.newMailIDsKey) ?? []
            if !suiteIDs.isEmpty {
                ids.append(contentsOf: suiteIDs)
                defaults.removeObject(forKey: Self.newMailIDsKey)
            }
        }

        return Array(NSOrderedSet(array: ids)).compactMap { $0 as? String }
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