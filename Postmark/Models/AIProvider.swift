import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case litellm
    case openai
    case gemini
    case anthropic
    case openrouter
    case trustedtokens
    case local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .litellm:       return "LiteLLM Proxy"
        case .openai:        return "OpenAI"
        case .gemini:        return "Google Gemini"
        case .anthropic:     return "Anthropic"
        case .openrouter:    return "OpenRouter"
        case .trustedtokens: return "TrustedTokens"
        case .local:         return "Local AI"
        }
    }

    var badgeLetter: String {
        switch self {
        case .litellm:       return "L"
        case .openai:        return "O"
        case .gemini:        return "G"
        case .anthropic:     return "A"
        case .openrouter:    return "R"
        case .trustedtokens: return "T"
        case .local:         return "·"
        }
    }

    /// The OpenAI-compatible endpoint shape this provider speaks. `litellm`,
    /// `openai`, `openrouter`, `trustedtokens` and `local` are all OpenAI-
    /// compatible; the rest need their own request shape (see `AIClientFactory`).
    var isOpenAICompatible: Bool {
        switch self {
        case .litellm, .openai, .openrouter, .trustedtokens, .local: return true
        case .gemini, .anthropic: return false
        }
    }
}
