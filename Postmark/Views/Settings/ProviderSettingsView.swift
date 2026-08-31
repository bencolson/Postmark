import SwiftUI

/// API keys are stored in Keychain per provider; the LiteLLM base URL + model are
/// written into the rules file's `provider` block which the daemon actually uses.
struct ProviderSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var litellmBaseURL: String = "http://localhost:4000/v1"
    @State private var litellmModel: String = "openrouter/laguna-s-2.1"
    @State private var savedMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Base URL") {
                    TextField("http://localhost:4000/v1", text: $litellmBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                LabeledContent("Model (LiteLLM route)") {
                    TextField("openrouter/laguna-s-2.1", text: $litellmModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                LabeledContent("Master key (optional)") {
                    KeyField(provider: .litellm, placeholder: "LiteLLM master key")
                }
                Button("Use this provider for triage") {
                    settingsStore.litellmBaseURL = litellmBaseURL
                    settingsStore.litellmModel = litellmModel
                    do {
                        try settingsStore.writeRulesProvider()
                        savedMessage = "Saved — next run uses LiteLLM"
                    } catch {
                        savedMessage = error.localizedDescription
                    }
                }
                .controlSize(.small)
                if let savedMessage {
                    Text(savedMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(savedMessage.hasPrefix("Saved") ? .green : .red)
                }
            } header: {
                Text("LiteLLM Proxy (recommended)")
            } footer: {
                Text("LiteLLM routes through your local proxy (Glimmer + OpenRouter fallback chain). The daemon builds its client from the rules file's provider block.")
            }

            Section {
                ForEach(directProviders) { provider in
                    LabeledContent(provider.displayName) {
                        KeyField(provider: provider, placeholder: "API key")
                    }
                }
            } header: {
                Text("Direct API keys")
            } footer: {
                Text("Keys live in macOS Keychain and are never written to disk. Direct providers (Anthropic, OpenAI, Gemini, OpenRouter, TrustedTokens) are for users who want to bypass the local LiteLLM proxy.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private var directProviders: [AIProvider] {
        AIProvider.allCases.filter { $0 != .litellm }
    }

    private func load() {
        if let rules = RulesStore.shared.load() {
            litellmBaseURL = rules.provider.baseURL ?? "http://localhost:4000/v1"
            litellmModel = rules.provider.model
        }
    }
}

/// SecureField + "save" for a Keychain-backed provider key.
private struct KeyField: View {
    let provider: AIProvider
    let placeholder: String
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var value: String = ""
    @State private var saved = false

    var body: some View {
        HStack(spacing: 8) {
            SecureField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Button(saved ? "✓" : "Save") { save() }
                .controlSize(.small)
                .disabled(value.isEmpty)
        }
        .onAppear { value = settingsStore.getAPIKey(for: provider) ?? "" }
    }

    private func save() {
        do {
            try settingsStore.setAPIKey(value, for: provider)
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { saved = false }
        } catch {
            saved = false
        }
    }
}