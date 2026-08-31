import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    private let keychain = KeychainService()

    @AppStorage("litellmBaseURL") var litellmBaseURL: String = "http://localhost:4000/v1"
    @AppStorage("litellmModel") var litellmModel: String = "openrouter/laguna-s-2.1"
    @AppStorage("quietHoursEnabled") var quietHoursEnabled: Bool = false

    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Failed to update launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Provider keys (Keychain)

    func setAPIKey(_ key: String, for provider: AIProvider) throws {
        try keychain.setKey(key, for: provider)
    }

    func getAPIKey(for provider: AIProvider) -> String? {
        keychain.getKey(for: provider)
    }

    func deleteAPIKey(for provider: AIProvider) {
        keychain.deleteKey(for: provider)
    }

    /// Convenience for the LiteLLM master key: users may supply it, or leave it
    /// empty if the local proxy doesn't require one.
    func setLitellmKey(_ key: String) throws {
        try keychain.setKey(key, for: .litellm)
    }

    func litellmKey() -> String? {
        keychain.getKey(for: .litellm)
    }

    // MARK: - Silo inbound addresses (Keychain)

    func setSiloAddress(_ address: String) throws {
        try keychain.setKey(address, label: KeychainService.siloInboundLabel)
    }

    func siloAddress() -> String? {
        keychain.getKey(label: KeychainService.siloInboundLabel)
    }

    func setSiloDevAddress(_ address: String) throws {
        try keychain.setKey(address, label: KeychainService.siloInboundDevLabel)
    }

    func siloDevAddress() -> String? {
        keychain.getKey(label: KeychainService.siloInboundDevLabel)
    }

    static let triageSettingDidChange = Notification.Name("postmark.triageSettingDidChange")

    // MARK: - Rules file shortcuts

    /// Persist the current provider/model/baseURL into the rules file so the
    /// daemon classifier uses it on the next run.
    func writeRulesProvider() throws {
        guard var rules = RulesStore.shared.load() else { return }
        rules.provider = ProviderSpec(type: "litellm", model: litellmModel, baseURL: litellmBaseURL)
        try RulesStore.shared.save(rules: rules)
    }

    var triageEnabled: Bool {
        RulesStore.shared.load()?.polling.enabled ?? false
    }

    func setTriageEnabled(_ enabled: Bool) throws {
        guard var rules = RulesStore.shared.load() else { return }
        rules.polling.enabled = enabled
        try RulesStore.shared.save(rules: rules)
        NotificationCenter.default.post(name: Self.triageSettingDidChange, object: enabled)
    }

    var pollingIntervalMinutes: Int {
        RulesStore.shared.load()?.polling.intervalMinutes ?? 15
    }

    var daysWindow: Int {
        RulesStore.shared.load()?.polling.daysWindow ?? 7
    }
}