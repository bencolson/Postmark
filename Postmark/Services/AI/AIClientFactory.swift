import Foundation

/// The provider/model/base-URL configuration the classifier actually uses, read
/// from `PostmarkRules.json`'s `provider` block. Version-controllable and editable
/// from Settings → Providers.
struct ProviderSpec: Codable, Equatable {
    var type: String   // AIProvider.rawValue
    var model: String  // routing string (model id, or LiteLLM route like "openrouter/x")
    var baseURL: String?

    var provider: AIProvider { AIProvider(rawValue: type) ?? .openai }

    /// Fixed public base URLs for the first-class providers.
    var resolvedBaseURL: String {
        guard let b = baseURL, !baseURL!.isEmpty else {
            switch provider {
            case .openai:        return "https://api.openai.com/v1"
            case .openrouter:    return "https://openrouter.ai/api/v1"
            case .trustedtokens: return "https://api.trustedtokens.eu/v1"
            case .local:         return "http://localhost:1234/v1"
            default:             return ""
            }
        }
        return b
    }
}

enum AIClientFactory {
    static func client(for spec: ProviderSpec, keychain: KeychainService) throws -> AIClient {
        switch spec.provider {
        case .litellm:
            let key = try keychain.getKey(for: .litellm) ?? ""
            return OpenAIClient(baseURL: spec.resolvedBaseURL.isEmpty ? "http://localhost:4000/v1" : spec.resolvedBaseURL,
                                apiKey: key, model: spec.model, provider: .litellm)
        case .openai:
            return try selfClient(spec, provider: .openai, keychain: keychain)
        case .openrouter:
            return try selfClient(spec, provider: .openrouter, keychain: keychain)
        case .trustedtokens:
            return try selfClient(spec, provider: .trustedtokens, keychain: keychain)
        case .local:
            return try selfClient(spec, provider: .local, keychain: keychain)
        case .gemini:
            let key = try requiredKey(for: .gemini, keychain: keychain)
            return GeminiClient(apiKey: key, model: spec.model)
        case .anthropic:
            let key = try requiredKey(for: .anthropic, keychain: keychain)
            return AnthropicClient(apiKey: key, model: spec.model)
        }
    }

    private static func selfClient(_ spec: ProviderSpec, provider: AIProvider, keychain: KeychainService) throws -> OpenAIClient {
        let key = try requiredKey(for: provider, keychain: keychain)
        return OpenAIClient(baseURL: spec.resolvedBaseURL, apiKey: key, model: spec.model, provider: provider)
    }

    private static func requiredKey(for provider: AIProvider, keychain: KeychainService) throws -> String {
        guard let key = keychain.getKey(for: provider), !key.isEmpty else {
            throw AIClientError.missingAPIKey(provider.displayName)
        }
        return key
    }
}
