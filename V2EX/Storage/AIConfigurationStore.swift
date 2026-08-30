import Foundation
import Security

struct AIServerConfiguration: Sendable {
    let apiKey: String
    let baseURL: URL
    let model: String

    var providerName: String {
        let host = baseURL.host()?.lowercased() ?? ""
        if host.contains("deepseek") { return "DeepSeek" }
        if host.contains("openai") { return "OpenAI" }
        if host.contains("siliconflow") { return "硅基流动" }
        return model
    }
}

@MainActor
final class AIConfigurationStore: ObservableObject {
    @Published private(set) var apiKey = ""
    @Published private(set) var baseURL = "https://api.deepseek.com/v1"
    @Published private(set) var model = "deepseek-chat"

    private let baseURLKey = "aiBaseURL"
    private let modelKey = "aiModel"
    private let keychainService = "com.vibe.v2ex.ai-api"
    private let keychainAccount = "default"

    init() {
        apiKey = readKey() ?? ""
        baseURL = UserDefaults.standard.string(forKey: baseURLKey) ?? baseURL
        model = UserDefaults.standard.string(forKey: modelKey) ?? model
    }

    var isConfigured: Bool { configuration != nil }

    var configuration: AIServerConfiguration? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !model.isEmpty,
              let url = Self.validatedBaseURL(baseURL) else { return nil }
        return AIServerConfiguration(apiKey: key, baseURL: url, model: model)
    }

    var providerName: String? { configuration?.providerName }

    func save(apiKey: String, baseURL: String, model: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIConfigurationError.missingAPIKey }
        guard !model.isEmpty else { throw AIConfigurationError.missingModel }
        guard let url = Self.validatedBaseURL(baseURL) else {
            throw AIConfigurationError.invalidBaseURL
        }

        self.apiKey = key
        self.baseURL = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.model = model
        UserDefaults.standard.set(self.baseURL, forKey: baseURLKey)
        UserDefaults.standard.set(model, forKey: modelKey)
        saveKey(key)
    }

    func clear() {
        apiKey = ""
        deleteKey()
    }

    private static func validatedBaseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else { return nil }
        return components.url
    }

    private func saveKey(_ value: String) {
        deleteKey()
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func readKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum AIConfigurationError: LocalizedError {
    case missingAPIKey
    case missingModel
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "请输入 API Key"
        case .missingModel: return "请输入模型名称"
        case .invalidBaseURL: return "API 地址必须是有效的 HTTPS 地址"
        }
    }
}
