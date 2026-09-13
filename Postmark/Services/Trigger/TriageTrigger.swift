import Foundation

/// MailKit fast path: the `PostmarkMail` appex stamps a signal file inside
/// Mail's container each time a message arrives (see MessageActionHandler).
/// This watcher notices a stamp advance and converts it into an earlier,
/// debounced, rate-limited triage run. The poll (live or shadow, on the rules
/// schedule) is the source of truth and the backstop for a dropped signal, a
/// closed Mail, or a disabled extension.
///
/// The signal file (not a distributed notification) is deliberate: the appex
/// is sandboxed and the daemon is not, and distributed notifications are not
/// delivered across that boundary. Both processes resolve the same physical
/// path — the sandbox maps the appex's home onto Mail's container Data root.
@MainActor
final class TriageTrigger {
    /// Absolute path of the signal file the appex stamps, relative to the
    /// daemon's own home. The appex is sandboxed into its own container, so
    /// its `.documentDirectory` maps to
    /// `~/Library/Containers/ltd.colson.postmark.PostmarkMail/Data/Documents/`
    /// — the one place it can write that both processes resolve identically.
    static let signalFilePath = "Library/Containers/ltd.colson.postmark.PostmarkMail/Data/Documents/postmark-signal.txt"

    private let coordinator: TriageCoordinator
    private var watcherTimer: Timer?
    private var lastStamp: UInt64 = 0
    private var lastMessageID: String = ""
    private var debounceTask: Task<Void, Never>?
    private var lastTriggerRun: Date?

    /// How often the watcher re-stats the signal file.
    private let watchInterval: TimeInterval = 15
    /// Signals arriving closer together than this collapse into one run.
    private let debounceInterval: TimeInterval = 20
    /// Minimum gap between MailKit-triggered runs.
    private let rateLimitInterval: TimeInterval = 60

    init(coordinator: TriageCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        // Baseline so a stale signal file left over from before a restart does
        // not trigger a run immediately.
        if let (stamp, id) = tryReadSignal() {
            lastStamp = stamp
            lastMessageID = id
        }

        let timer = Timer.scheduledTimer(withTimeInterval: watchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForSignal()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watcherTimer = timer
    }

    func stop() {
        watcherTimer?.invalidate()
        watcherTimer = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Signal handling

    private func checkForSignal() {
        guard let (stamp, id) = tryReadSignal() else { return }
        guard stamp > lastStamp || (stamp == lastStamp && id != lastMessageID) else { return }
        lastStamp = stamp
        lastMessageID = id

        if id.isEmpty {
            ActivityLog.shared.record("MailKit signal (no message ID)", kind: .app, level: .debug)
        } else {
            ActivityLog.shared.record("Trigger: MailKit signal (\(id))", kind: .app, level: .debug)
        }
        scheduleRun()
    }

    /// Read `<unixEpoch>\n<messageID>\n` from the signal file. Returns nil while
    /// the file is absent, empty (mid-write), or unreadable — the next tick
    /// retries.
    private func tryReadSignal() -> (stamp: UInt64, id: String)? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let url = library.deletingLastPathComponent().appendingPathComponent(Self.signalFilePath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let stampLine = lines.first, let stamp = UInt64(String(stampLine)) else { return nil }
        let id = lines.count >= 2 ? String(lines[1]) : ""
        return (stamp: stamp, id: id)
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