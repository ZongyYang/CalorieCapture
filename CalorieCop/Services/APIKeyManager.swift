import Foundation

enum APIRegion: String, CaseIterable {
    case international = "international"
    case china = "china"

    var displayName: String {
        switch self {
        case .international: return "国际 (International)"
        case .china: return "中国大陆 (China)"
        }
    }

    var miniMaxEndpoint: URL {
        switch self {
        case .international:
            return URL(string: "https://api.minimax.io/v1/text/chatcompletion_v2")!
        case .china:
            return URL(string: "https://api.minimax.chat/v1/text/chatcompletion_v2")!
        }
    }

    var qwenEndpoint: URL {
        switch self {
        case .international:
            return URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")!
        case .china:
            return URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
        }
    }
}

enum APIKeyManager {
    private static let miniMaxKeyUserDefaultsKey = "user_minimax_api_key"
    private static let deepSeekKeyUserDefaultsKey = "user_deepseek_api_key"
    private static let qwenKeyUserDefaultsKey = "user_qwen_api_key"
    private static let regionUserDefaultsKey = "user_api_region"

    private static func normalizedKey(_ rawKey: String?) -> String? {
        guard let rawKey else { return nil }

        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != "your_api_key_here" else { return nil }
        return key
    }

    static var miniMaxAPIKey: String? {
        // First check UserDefaults (user-entered key)
        if let userKey = normalizedKey(UserDefaults.standard.string(forKey: miniMaxKeyUserDefaultsKey)) {
            return userKey
        }

        // Then check Secrets.swift (gitignored, for developer use)
        if let key = normalizedKey(Secrets.miniMaxAPIKey) {
            return key
        }

        // Fallback to environment variable
        return normalizedKey(ProcessInfo.processInfo.environment["MINIMAX_API_KEY"])
    }

    static var deepSeekAPIKey: String? {
        // First check UserDefaults (user-entered key)
        if let userKey = normalizedKey(UserDefaults.standard.string(forKey: deepSeekKeyUserDefaultsKey)) {
            return userKey
        }

        // Then check Secrets.swift (gitignored, for developer use)
        if let key = normalizedKey(Secrets.deepSeekAPIKey) {
            return key
        }

        // Fallback to environment variable
        return normalizedKey(ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"])
    }

    static var qwenAPIKey: String? {
        // First check UserDefaults (user-entered key)
        if let userKey = normalizedKey(UserDefaults.standard.string(forKey: qwenKeyUserDefaultsKey)) {
            return userKey
        }

        // Then check Secrets.swift (gitignored, for developer use)
        if let key = normalizedKey(Secrets.qwenAPIKey) {
            return key
        }

        // Fallback to environment variable
        return normalizedKey(ProcessInfo.processInfo.environment["QWEN_API_KEY"])
    }

    static var isMiniMaxConfigured: Bool {
        guard let key = miniMaxAPIKey else { return false }
        return !key.isEmpty
    }

    static var isDeepSeekConfigured: Bool {
        guard let key = deepSeekAPIKey else { return false }
        return !key.isEmpty
    }

    static var isQwenConfigured: Bool {
        guard let key = qwenAPIKey else { return false }
        return !key.isEmpty
    }

    // MARK: - User Key Management

    static func setUserMiniMaxKey(_ key: String) {
        storeUserKey(key, forKey: miniMaxKeyUserDefaultsKey)
    }

    static func setUserDeepSeekKey(_ key: String) {
        storeUserKey(key, forKey: deepSeekKeyUserDefaultsKey)
    }

    static func setUserQwenKey(_ key: String) {
        storeUserKey(key, forKey: qwenKeyUserDefaultsKey)
    }

    private static func storeUserKey(_ key: String, forKey defaultsKey: String) {
        if let normalizedKey = normalizedKey(key) {
            UserDefaults.standard.set(normalizedKey, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    static func clearUserKeys() {
        UserDefaults.standard.removeObject(forKey: miniMaxKeyUserDefaultsKey)
        UserDefaults.standard.removeObject(forKey: deepSeekKeyUserDefaultsKey)
        UserDefaults.standard.removeObject(forKey: qwenKeyUserDefaultsKey)
    }

    static var hasUserMiniMaxKey: Bool {
        normalizedKey(UserDefaults.standard.string(forKey: miniMaxKeyUserDefaultsKey)) != nil
    }

    static var hasUserDeepSeekKey: Bool {
        normalizedKey(UserDefaults.standard.string(forKey: deepSeekKeyUserDefaultsKey)) != nil
    }

    static var hasUserQwenKey: Bool {
        normalizedKey(UserDefaults.standard.string(forKey: qwenKeyUserDefaultsKey)) != nil
    }

    // MARK: - Region Management

    static var region: APIRegion {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: regionUserDefaultsKey),
                  let region = APIRegion(rawValue: rawValue) else {
                return .international  // Default to international
            }
            return region
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: regionUserDefaultsKey)
        }
    }

    static var miniMaxEndpoint: URL {
        region.miniMaxEndpoint
    }

    static var deepSeekEndpoint: URL {
        URL(string: "https://api.deepseek.com/chat/completions")!
    }

    static var qwenEndpoint: URL {
        region.qwenEndpoint
    }
}
