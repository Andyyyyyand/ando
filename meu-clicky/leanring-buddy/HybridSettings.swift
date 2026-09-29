//
//  HybridSettings.swift
//  leanring-buddy
//
//  User-facing settings for the local/hybrid build: which "brain" answers
//  (local model, Claude, or automatic routing), which Claude model to use,
//  where the local servers live, and the Claude API key (stored in the
//  macOS Keychain, never in UserDefaults or the app bundle).
//

import Combine
import Foundation
import Security

/// A labeled choice shown as a segmented button in the panel.
struct LabeledSettingOption: Identifiable {
    let label: String
    let value: String
    var id: String { value }
}

/// Which brain answers a push-to-talk question.
enum HybridBrainMode: String, CaseIterable {
    /// Simple questions stay on the Mac, hard ones go to Claude.
    case automatic = "automatic"
    /// Everything runs on the Mac. Free and fully private.
    case localOnly = "local"
    /// Everything goes to Claude. Best quality, paid per use.
    case claudeOnly = "claude"

    var displayName: String {
        switch self {
        case .automatic: return "Auto"
        case .localOnly: return "Local"
        case .claudeOnly: return "Claude"
        }
    }
}

@MainActor
final class HybridSettings: ObservableObject {
    static let shared = HybridSettings()

    private enum DefaultsKey {
        static let brainMode = "hybridBrainMode"
        static let claudeModel = "hybridClaudeModel"
        static let localModelServerURL = "hybridLocalModelServerURL"
        static let localVisionModelName = "hybridLocalVisionModelName"
        static let kokoroServerURL = "hybridKokoroServerURL"
        static let kokoroVoice = "hybridKokoroVoice"
        static let speechLocaleIdentifier = "hybridSpeechLocaleIdentifier"
        static let agentAllowsTerminalCommands = "hybridAgentAllowsTerminalCommands"
        static let agentUsesConnectedIntegrations = "hybridAgentUsesConnectedIntegrations"
        static let dictationCleanupWithClaude = "hybridDictationCleanupWithClaude"
        static let wakeWordEnabled = "hybridWakeWordEnabled"
    }

    /// Claude models offered in the panel picker. Opus is the most capable;
    /// Sonnet is cheaper per question.
    static let claudeModelOptions: [LabeledSettingOption] = [
        LabeledSettingOption(label: "Opus 5", value: "claude-opus-5"),
        LabeledSettingOption(label: "Sonnet 5", value: "claude-sonnet-5")
    ]

    /// Brazilian Portuguese Kokoro voices.
    static let kokoroVoiceOptions: [LabeledSettingOption] = [
        LabeledSettingOption(label: "Dora", value: "pf_dora"),
        LabeledSettingOption(label: "Alex", value: "pm_alex"),
        LabeledSettingOption(label: "Santa", value: "pm_santa")
    ]

    @Published var brainMode: HybridBrainMode {
        didSet { UserDefaults.standard.set(brainMode.rawValue, forKey: DefaultsKey.brainMode) }
    }

    @Published var claudeModel: String {
        didSet { UserDefaults.standard.set(claudeModel, forKey: DefaultsKey.claudeModel) }
    }

    /// Base URL of the OpenAI-compatible local model server. Ollama listens on
    /// port 11434 by default; LM Studio and mlx_lm.server work too.
    @Published var localModelServerURL: String {
        didSet { UserDefaults.standard.set(localModelServerURL, forKey: DefaultsKey.localModelServerURL) }
    }

    /// Vision-capable local model. qwen3-vl:4b-instruct uses ~3.3 GB of memory, which
    /// leaves room for everything else on a 16 GB Mac.
    @Published var localVisionModelName: String {
        didSet { UserDefaults.standard.set(localVisionModelName, forKey: DefaultsKey.localVisionModelName) }
    }

    /// Base URL of the mlx-audio server running the Kokoro voice model.
    @Published var kokoroServerURL: String {
        didSet { UserDefaults.standard.set(kokoroServerURL, forKey: DefaultsKey.kokoroServerURL) }
    }

    /// Kokoro voice preset. Brazilian Portuguese voices: pf_dora (female),
    /// pm_alex and pm_santa (male).
    @Published var kokoroVoice: String {
        didSet { UserDefaults.standard.set(kokoroVoice, forKey: DefaultsKey.kokoroVoice) }
    }

    /// Language used by Apple's on-device speech recognizer.
    @Published var speechLocaleIdentifier: String {
        didSet { UserDefaults.standard.set(speechLocaleIdentifier, forKey: DefaultsKey.speechLocaleIdentifier) }
    }

    /// When off (the default), the Claude Code agent can read, write and
    /// search the web, but cannot run terminal commands.
    @Published var agentAllowsTerminalCommands: Bool {
        didSet { UserDefaults.standard.set(agentAllowsTerminalCommands, forKey: DefaultsKey.agentAllowsTerminalCommands) }
    }

    /// When on (the default), the Claude Code agent may use the accounts
    /// connected at claude.ai/customize/connectors (Gmail, Google Calendar,
    /// Notion, Linear...).
    @Published var agentUsesConnectedIntegrations: Bool {
        didSet { UserDefaults.standard.set(agentUsesConnectedIntegrations, forKey: DefaultsKey.agentUsesConnectedIntegrations) }
    }

    /// When on (the default) and a Claude key is saved, dictated text is
    /// cleaned up (punctuation, capitalization, misheard words) before typing.
    @Published var dictationCleanupWithClaude: Bool {
        didSet { UserDefaults.standard.set(dictationCleanupWithClaude, forKey: DefaultsKey.dictationCleanupWithClaude) }
    }

    /// Hands-free mode: say "ei Clicky" instead of holding ctrl + option.
    @Published var wakeWordEnabled: Bool {
        didSet { UserDefaults.standard.set(wakeWordEnabled, forKey: DefaultsKey.wakeWordEnabled) }
    }

    /// Mirrors whether a Claude API key is saved, so the UI can react
    /// without reading the Keychain on every render.
    @Published private(set) var hasClaudeAPIKey: Bool = false

    private init() {
        let defaults = UserDefaults.standard
        brainMode = HybridBrainMode(rawValue: defaults.string(forKey: DefaultsKey.brainMode) ?? "") ?? .automatic
        claudeModel = defaults.string(forKey: DefaultsKey.claudeModel) ?? "claude-opus-5"
        localModelServerURL = defaults.string(forKey: DefaultsKey.localModelServerURL) ?? "http://127.0.0.1:11434"
        localVisionModelName = defaults.string(forKey: DefaultsKey.localVisionModelName) ?? "qwen3-vl:4b-instruct"
        kokoroServerURL = defaults.string(forKey: DefaultsKey.kokoroServerURL) ?? "http://127.0.0.1:8123"
        kokoroVoice = defaults.string(forKey: DefaultsKey.kokoroVoice) ?? "pf_dora"
        speechLocaleIdentifier = defaults.string(forKey: DefaultsKey.speechLocaleIdentifier) ?? "pt-BR"
        agentAllowsTerminalCommands = defaults.bool(forKey: DefaultsKey.agentAllowsTerminalCommands)
        agentUsesConnectedIntegrations = defaults.object(forKey: DefaultsKey.agentUsesConnectedIntegrations) as? Bool ?? true
        dictationCleanupWithClaude = defaults.object(forKey: DefaultsKey.dictationCleanupWithClaude) as? Bool ?? true
        wakeWordEnabled = defaults.object(forKey: DefaultsKey.wakeWordEnabled) as? Bool ?? true
        hasClaudeAPIKey = !(KeychainStore.readString(account: KeychainStore.claudeAPIKeyAccount) ?? "").isEmpty
    }

    /// The saved Claude API key, or nil when none is configured.
    var claudeAPIKey: String? {
        let storedKey = KeychainStore.readString(account: KeychainStore.claudeAPIKeyAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let storedKey, !storedKey.isEmpty else { return nil }
        return storedKey
    }

    func saveClaudeAPIKey(_ apiKey: String) {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAPIKey.isEmpty {
            KeychainStore.delete(account: KeychainStore.claudeAPIKeyAccount)
        } else {
            KeychainStore.saveString(trimmedAPIKey, account: KeychainStore.claudeAPIKeyAccount)
        }
        hasClaudeAPIKey = !trimmedAPIKey.isEmpty
    }
}

/// Minimal wrapper around the macOS Keychain for storing secrets as
/// generic passwords scoped to this app.
enum KeychainStore {
    static let claudeAPIKeyAccount = "claude-api-key"
    private static let serviceName = "meu-clicky"

    static func saveString(_ value: String, account: String) {
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ Keychain: failed to save \(account) (status \(status))")
        }
    }

    static func readString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
