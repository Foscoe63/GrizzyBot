import Foundation

/// A model catalog entry, mirroring rakazo's `PiCatalogEntry`.
public struct CatalogEntry: Codable, Sendable, Hashable, Identifiable {
    public var provider: String
    public var providerName: String?
    public var id: String
    public var label: String
    public var billing: String
    public var auth: AuthKind
    public var oauthLabel: String?
    public var subscription: Bool
    public var signIn: SignInKind?

    public enum AuthKind: String, Codable, Sendable {
        case apiKey = "api-key"
        case oauth
        case both
    }

    public enum SignInKind: String, Codable, Sendable {
        case deviceCode = "device-code"
    }

    public var idKey: String { "\(provider):\(id)" }

    public init(
        provider: String,
        providerName: String? = nil,
        id: String,
        label: String,
        billing: String,
        auth: AuthKind = .apiKey,
        oauthLabel: String? = nil,
        subscription: Bool = false,
        signIn: SignInKind? = nil
    ) {
        self.provider = provider
        self.providerName = providerName
        self.id = id
        self.label = label
        self.billing = billing
        self.auth = auth
        self.oauthLabel = oauthLabel
        self.subscription = subscription
        self.signIn = signIn
    }
}

/// The built-in model catalog. Mirrors the shape of rakazo's Pi catalog:
/// OpenRouter by default, plus ChatGPT / Copilot / SuperGrok device-code sign-in.
public enum ModelCatalog {
    public static let defaultProvider = "openrouter"
    public static let defaultModelId = "deepseek/deepseek-v4-flash-0731"

    public static let entries: [CatalogEntry] = {
        var list: [CatalogEntry] = []

        func add(
            _ provider: String,
            _ name: String,
            billing: String,
            auth: CatalogEntry.AuthKind = .apiKey,
            oauthLabel: String? = nil,
            subscription: Bool = false,
            signIn: CatalogEntry.SignInKind? = nil,
            _ models: [(id: String, label: String)]
        ) {
            for model in models {
                list.append(
                    CatalogEntry(
                        provider: provider,
                        providerName: name,
                        id: model.id,
                        label: model.label,
                        billing: billing,
                        auth: auth,
                        oauthLabel: oauthLabel,
                        subscription: subscription,
                        signIn: signIn
                    )
                )
            }
        }

        add(
            "openrouter",
            "OpenRouter",
            billing: "Uses your OpenRouter API key. GrizzyBot does not pay for model usage.",
            [
                ("deepseek/deepseek-v4-flash-0731", "DeepSeek V4 Flash"),
                ("anthropic/claude-sonnet-4.5", "Claude Sonnet 4.5"),
                ("openai/gpt-5", "GPT-5"),
                ("google/gemini-3-pro", "Gemini 3 Pro"),
                ("x-ai/grok-4", "Grok 4"),
                ("mistralai/mistral-large-2512", "Mistral Large 2"),
            ]
        )

        add(
            "openai-codex",
            "OpenAI Codex",
            billing: "Sign in with ChatGPT Plus or Pro. Uses your OpenAI subscription. GrizzyBot does not pay.",
            auth: .both,
            oauthLabel: "Sign in with ChatGPT Plus/Pro",
            subscription: true,
            signIn: .deviceCode,
            [
                ("gpt-5-codex", "GPT-5 Codex"),
                ("gpt-5", "GPT-5"),
            ]
        )

        add(
            "github-copilot",
            "GitHub Copilot",
            billing: "Sign in with GitHub Copilot. Uses your Copilot subscription. GrizzyBot does not pay.",
            auth: .oauth,
            oauthLabel: "Sign in with GitHub Copilot",
            subscription: true,
            signIn: .deviceCode,
            [
                ("claude-sonnet-4.5", "Claude Sonnet 4.5"),
                ("gpt-5", "GPT-5"),
            ]
        )

        add(
            "xai",
            "xAI",
            billing: "Sign in with SuperGrok or X Premium, or paste an xAI API key. GrizzyBot does not pay.",
            auth: .both,
            oauthLabel: "Sign in with SuperGrok or X Premium",
            signIn: .deviceCode,
            [
                ("grok-4", "Grok 4"),
                ("grok-code-fast-1", "Grok Code Fast 1"),
            ]
        )

        add(
            "anthropic",
            "Anthropic",
            billing: "Uses your Anthropic API key. GrizzyBot does not pay for model usage.",
            [
                ("claude-sonnet-4-5", "Claude Sonnet 4.5"),
                ("claude-opus-4-1", "Claude Opus 4.1"),
            ]
        )

        add(
            "google",
            "Google",
            billing: "Uses your Google API key. GrizzyBot does not pay for model usage.",
            [
                ("gemini-3-pro", "Gemini 3 Pro"),
                ("gemini-2.5-flash", "Gemini 2.5 Flash"),
            ]
        )

        add(
            "openai",
            "OpenAI",
            billing: "Uses your OpenAI API key. GrizzyBot does not pay for model usage.",
            [
                ("gpt-5", "GPT-5"),
                ("gpt-4.1", "GPT-4.1"),
            ]
        )

        add(
            "mistral",
            "Mistral",
            billing: "Uses your Mistral API key. GrizzyBot does not pay for model usage.",
            [
                ("mistral-large-latest", "Mistral Large"),
            ]
        )

        add(
            "groq",
            "Groq",
            billing: "Uses your Groq API key. GrizzyBot does not pay for model usage.",
            [
                ("llama-3.3-70b-versatile", "Llama 3.3 70B"),
            ]
        )

        add(
            "deepseek",
            "DeepSeek",
            billing: "Uses your DeepSeek API key. GrizzyBot does not pay for model usage.",
            [
                ("deepseek-v4-flash", "DeepSeek V4 Flash"),
            ]
        )

        return list
    }()

    /// One entry per provider (first model wins), mirroring the onboarding rail.
    public static var providers: [CatalogEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            if seen.contains(entry.provider) { return false }
            seen.insert(entry.provider)
            return true
        }
    }

    public static func models(forProvider provider: String) -> [CatalogEntry] {
        entries.filter { $0.provider == provider }
    }

    /// The small hint shown on the right of each provider row.
    public static func hint(for entry: CatalogEntry) -> String {
        if entry.signIn == .deviceCode {
            switch entry.provider {
            case "openai-codex": return "ChatGPT Plus/Pro"
            case "github-copilot": return "Copilot"
            case "xai": return "SuperGrok / key"
            default: return "Sign in"
            }
        }
        if entry.auth == .oauth { return "Skip or deploy key" }
        return "API key"
    }

    /// The label for the device-code sign-in button.
    public static func signInLabel(for entry: CatalogEntry) -> String {
        entry.oauthLabel ?? "Sign in"
    }

    /// Simulated device-code activation URL, per provider.
    public static func verificationURI(forProvider provider: String) -> String {
        switch provider {
        case "openai-codex": return "https://auth.openai.com/activate"
        case "github-copilot": return "https://github.com/login/device/code"
        case "xai": return "https://console.x.ai/oauth/activate"
        default: return "https://auth.grizzybot.app/activate"
        }
    }

    public static func makeUserCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        func pick() -> Character { alphabet[Int.random(in: 0..<alphabet.count)] }
        return "\(pick())\(pick())\(pick())-\(pick())\(pick())\(pick())\(pick())"
    }
}
