import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let defaultPollInterval: TimeInterval = 15 * 60

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var settingsWindow: NSWindow?
    private var activityWindow: NSWindow?

    private var triageNowItem: NSMenuItem!
    private var enableTriageItem: NSMenuItem!
    private var digestItem: NSMenuItem!
    private var quietHoursItem: NSMenuItem!
    private var updateMenuItem: NSMenuItem!
    private var updateSeparator: NSMenuItem!

    private var pollTimer: Timer?
    private var lastRun: TriageRun?
    private var isBusy = false
    private var hadErrors = false
    private var updateStateCancellable: AnyCancellable?

    let settingsStore = SettingsStore()
    private let triage = TriageCoordinator()
    private let updateChecker = UpdateChecker()

    // MARK: - Icon state machine (envelope family)

    private enum IconState {
        case disabled     // triage off
        case idle         // armed, nothing pending
        case busy         // polling
        case digest       // results waiting
        case error        // last run had failures
    }

    private var iconState: IconState = .disabled {
        didSet {
            guard oldValue != iconState else { return }
            applyIconState(iconState)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.windows.forEach { $0.close() }

        ActivityLog.shared.record("Postmark launched", kind: .app)
        setupMenuBar()
        observeUpdateState()
        observeTriageSettingChanges()
        bindTriage()
        refreshTriageMenuState()
        schedulePoll()

        Task {
            await Notifier.shared.requestAuthorizationIfNeeded()
        }
        Task { updateChecker.checkForUpdates() }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        triageNowItem = NSMenuItem(title: "Triage Now", action: #selector(triageNow), keyEquivalent: "t")
        triageNowItem.target = self

        enableTriageItem = NSMenuItem(title: "Enable Triage", action: #selector(toggleTriage), keyEquivalent: "")
        enableTriageItem.target = self

        digestItem = NSMenuItem(title: "No runs yet", action: nil, keyEquivalent: "")
        digestItem.isEnabled = false

        quietHoursItem = NSMenuItem(title: "Quiet Hours", action: #selector(toggleQuietHours), keyEquivalent: "")
        quietHoursItem.target = self

        // Reserved slot for "Install Update vX.Y.Z…".
        updateMenuItem = NSMenuItem(title: "", action: #selector(installUpdate), keyEquivalent: "")
        updateMenuItem.target = self
        updateMenuItem.isHidden = true
        updateSeparator = NSMenuItem.separator()
        updateSeparator.isHidden = true

        statusMenu = NSMenu()
        statusMenu.addItem(updateMenuItem)
        statusMenu.addItem(updateSeparator)
        statusMenu.addItem(triageNowItem)
        statusMenu.addItem(enableTriageItem)
        statusMenu.addItem(digestItem)
        statusMenu.addItem(quietHoursItem)
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        let activityItem = NSMenuItem(title: "Activity…", action: #selector(openActivity), keyEquivalent: "a")
        activityItem.keyEquivalentModifierMask = [.command, .shift]
        statusMenu.addItem(activityItem)
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Quit Postmark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: "Postmark")
            button.image?.isTemplate = true
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            DispatchQueue.main.async { [weak self] in
                self?.statusItem.menu = nil
            }
        } else {
            openSettings()
        }
    }

    // MARK: - Menu actions

    @objc private func triageNow() {
        ActivityLog.shared.record("Triage Now (manual)", kind: .app)
        isBusy = true
        refreshIcon()
        Task {
            await triage.run(scheduled: false)
            isBusy = false
            refreshIcon()
        }
    }

    @objc private func toggleTriage() {
        let enabled = !settingsStore.triageEnabled
        do {
            try settingsStore.setTriageEnabled(enabled)
            ActivityLog.shared.record("Triage \(enabled ? "enabled" : "disabled")", kind: .app)
        } catch {
            ActivityLog.shared.record("Could not update rules file: \(error.localizedDescription)", kind: .error, level: .error)
            Notifier.shared.postErrors(["Could not update rules file: \(error.localizedDescription)"])
        }
        refreshTriageMenuState()
    }

    @objc private func toggleQuietHours() {
        settingsStore.quietHoursEnabled.toggle()
        Notifier.shared.forceQuiet = settingsStore.quietHoursEnabled
        quietHoursItem.state = settingsStore.quietHoursEnabled ? .on : .off
        ActivityLog.shared.record("Quiet hours \(settingsStore.quietHoursEnabled ? "on" : "off")", kind: .app)
    }

    @objc private func installUpdate() {
        updateChecker.install()
    }

    // MARK: - Triage binding

    private func bindTriage() {
        triage.onRun = { [weak self] run in
            self?.lastRun = run
            self?.hadErrors = !run.errors.isEmpty
            self?.updateDigestMenu(run)
            self?.refreshIcon()
        }
        triage.onFatalError = { [weak self] message in
            self?.hadErrors = true
            self?.refreshIcon()
            Task { @MainActor in Notifier.shared.postErrors([message]) }
        }
    }

    private func updateDigestMenu(_ run: TriageRun) {
        var parts: [String] = []
        for (cat, count) in run.byCategory.sorted(by: { $0.value > $1.value }) {
            parts.append("\(count)× \(cat)")
        }
        if run.forwarded > 0 { parts.append("\(run.forwarded)→Silo") }
        if !run.errors.isEmpty { parts.append("\(run.errors.count) errors") }
        let summary = parts.isEmpty ? "nothing new" : parts.joined(separator: " · ")
        digestItem.title = "Last run: \(summary)"
    }

    private func refreshTriageMenuState() {
        let enabled = settingsStore.triageEnabled
        enableTriageItem.state = enabled ? .on : .off
        enableTriageItem.title = enabled ? "Disable Triage" : "Enable Triage"
        quietHoursItem.state = settingsStore.quietHoursEnabled ? .on : .off
        Notifier.shared.forceQuiet = settingsStore.quietHoursEnabled
        if let rules = RulesStore.shared.load() {
            Notifier.shared.setQuietHours(rules.polling.quietHours)
            triageNowItem.title = settingsStore.triageEnabled ? "Triage Now" : "Triage Now (shadow mode)"
        }
        refreshIcon()
    }

    // MARK: - Icon

    private func refreshIcon() {
        let enabled = settingsStore.triageEnabled
        if isBusy {
            iconState = .busy
        } else if hadErrors {
            iconState = .error
        } else if lastRun != nil {
            iconState = .digest
        } else if enabled {
            iconState = .idle
        } else {
            iconState = .disabled
        }
    }

    private func applyIconState(_ state: IconState) {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch state {
        case .disabled: symbol = "envelope"
        case .idle:     symbol = "envelope.badge"
        case .busy:     symbol = "hourglass"
        case .digest:   symbol = "envelope.badge.fill"
        case .error:    symbol = "exclamationmark.triangle.fill"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Postmark")
        button.image?.isTemplate = true
        switch state {
        case .busy:    button.contentTintColor = nil
        case .digest:  button.contentTintColor = .systemOrange
        case .error:   button.contentTintColor = .systemRed
        default:       button.contentTintColor = nil
        }
    }

    // MARK: - Poll loop

    private func observeTriageSettingChanges() {
        NotificationCenter.default.addObserver(
            forName: SettingsStore.triageSettingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshTriageMenuState()
                self.schedulePoll()
            }
        }
    }

    private func schedulePoll() {
        pollTimer?.invalidate()
        let interval = TimeInterval(max(settingsStore.pollingIntervalMinutes, 1) * 60)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = true
                self.refreshIcon()
                await self.triage.run(scheduled: true)
                self.isBusy = false
                self.refreshIcon()
            }
        }
        ActivityLog.shared.record("Scheduled triage fired", kind: .app, level: .debug)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Updates

    private func observeUpdateState() {
        updateStateCancellable = updateChecker.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                let isReady: Bool
                if case .readyToInstall = state { isReady = true } else { isReady = false }
                if isReady {
                    let version = self?.updateChecker.latestVersion ?? "new version"
                    self?.updateMenuItem.title = "Install Update v\(version)…"
                }
                self?.updateMenuItem.isHidden = !isReady
                self?.updateSeparator.isHidden = !isReady

                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .downloading:
                        self.recordUpdateState("Downloading update")
                    case .readyToInstall:
                        if let version = self.updateChecker.latestVersion {
                            self.recordUpdateState("Update v\(version) ready to install")
                        }
                    case .failed(let message):
                        self.recordUpdateState("Update failed: \(message)", level: .error)
                    case .installing:
                        self.recordUpdateState("Installing update")
                    case .idle, .checking, .upToDate:
                        break
                    }
                }
            }
    }

    private func recordUpdateState(_ message: String, level: ActivityLog.Level = .info) {
        ActivityLog.shared.record("Update: \(message)", kind: .app, level: level)
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        if let window = settingsWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView()
            .environmentObject(settingsStore)
            .environmentObject(updateChecker)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Postmark"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.contentMinSize = NSSize(width: 560, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
        ActivityLog.shared.record("Settings window opened", kind: .app, level: .debug)
    }

    // MARK: - Activity window

    @objc private func openActivity() {
        if let window = activityWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Postmark Activity"
        window.contentView = NSHostingView(rootView: ActivityWindowView(log: ActivityLog.shared))
        window.center()
        window.contentMinSize = NSSize(width: 620, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        activityWindow = window
        ActivityLog.shared.record("Activity window opened", kind: .app, level: .debug)
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            switch window {
            case settingsWindow:
                ActivityLog.shared.record("Settings window closed", kind: .app, level: .debug)
                settingsWindow = nil
            case activityWindow:
                ActivityLog.shared.record("Activity window closed", kind: .app, level: .debug)
                activityWindow = nil
            default:
                break
            }
        }
    }
}