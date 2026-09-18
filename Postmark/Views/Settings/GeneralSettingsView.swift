import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var updateChecker: UpdateChecker

    @State private var intervalMinutes: Int = 30
    @State private var daysWindow: Int = 7
    @State private var includeRead: Bool = true
    @State private var quietStart: String = "22:00"
    @State private var quietEnd: String = "08:00"
    @State private var saveState: SaveState = .idle
    @State private var triageEnabled: Bool = false

    enum SaveState: Equatable {
        case idle, saved, failed(String)
    }

    var body: some View {
        Form {
            Section("Triage") {
                Toggle("Enable triage (apply Mail actions)", isOn: $triageEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: triageEnabled) { _, newValue in
                        do {
                            try settingsStore.setTriageEnabled(newValue)
                            saveState = .saved
                        } catch {
                            saveState = .failed(error.localizedDescription)
                        }
                    }
                Text("When off, “Triage Now” runs in shadow mode: it classifies and logs only, with no Mail actions and no Silo forwards.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("Polling") {
                Stepper("Poll every \(intervalMinutes) minutes", value: $intervalMinutes, in: 1...120)
                Stepper("Window: last \(daysWindow) days", value: $daysWindow, in: 1...30)
                Toggle("Include already-read messages", isOn: $includeRead)
                    .toggleStyle(.switch)
                LabeledContent("Quiet hours window") {
                    HStack(spacing: 6) {
                        TextField("22:00", text: $quietStart)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("–")
                        TextField("08:00", text: $quietEnd)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                }
                HStack {
                    Button("Save polling settings") { savePolling() }
                    switch saveState {
                    case .idle: EmptyView()
                    case .saved: Text("Saved").font(.system(size: 11)).foregroundStyle(.green)
                    case .failed(let msg): Text(msg).font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
            }

            Section {
                Toggle("Suppress digest notifications", isOn: Binding(
                    get: { settingsStore.quietHoursEnabled },
                    set: { settingsStore.quietHoursEnabled = $0; Notifier.shared.forceQuiet = $0 }
                ))
                .toggleStyle(.switch)

                Toggle("Launch at login", isOn: Binding(
                    get: { settingsStore.launchAtLogin },
                    set: { settingsStore.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
            }

            Section("Updates") {
                LabeledContent("Version \(updateChecker.currentVersion)") { updateStatusView }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadRules)
    }

    private func loadRules() {
        if let rules = RulesStore.shared.load() {
            intervalMinutes = rules.polling.intervalMinutes
            daysWindow = rules.polling.daysWindow
            includeRead = rules.polling.includeReadOrDefault
            if let qh = rules.polling.quietHours {
                quietStart = qh.start
                quietEnd = qh.end
            }
        }
        triageEnabled = settingsStore.triageEnabled
    }

    private func savePolling() {
        guard var rules = RulesStore.shared.load() else {
            saveState = .failed("Rules file missing or invalid")
            return
        }
        rules.polling.intervalMinutes = intervalMinutes
        rules.polling.daysWindow = daysWindow
        rules.polling.includeRead = includeRead
        rules.polling.quietHours = QuietHours(start: quietStart, end: quietEnd)
        do {
            try RulesStore.shared.save(rules: rules)
            Notifier.shared.setQuietHours(rules.polling.quietHours)
            saveState = .saved
            NotificationCenter.default.post(name: SettingsStore.triageSettingDidChange, object: nil)
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateChecker.state {
        case .idle:
            Button("Check for Updates") { updateChecker.checkForUpdates(manual: true) }.controlSize(.small)
        case .upToDate:
            HStack(spacing: 8) {
                Text("Up to date").foregroundStyle(.secondary)
                Button("Check Again") { updateChecker.checkForUpdates(manual: true) }.controlSize(.small)
            }
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
        case .downloading:
            Text("Downloading…").foregroundStyle(.secondary)
        case .readyToInstall:
            Button("Relaunch to Update") { updateChecker.install() }.controlSize(.small)
        case .installing:
            Text("Installing…").foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                Button("Retry") { updateChecker.checkForUpdates(manual: true) }.controlSize(.small)
            }
        }
    }
}