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
    private static let qwenKeyUserDefaultsKey = "user_qwen_api_key"
    private static let regionUserDefaultsKey = "user_api_region"

    static var miniMaxAPIKey: String? {
        // First check UserDefaults (user-entered key)
        if let userKey = UserDefaults.standard.string(forKey: miniMaxKeyUserDefaultsKey),
           !userKey.isEmpty {
            return userKey
        }

        // Then check Secrets.swift (gitignored, for developer use)
        let key = Secrets.miniMaxAPIKey
        if !key.isEmpty && key != "your_api_key_here" {
            return key
        }

        // Fallback to environment variable
        return ProcessInfo.processInfo.environment["MINIMAX_API_KEY"]
    }

    static var qwenAPIKey: String? {
        // First check UserDefaults (user-entered key)
        if let userKey = UserDefaults.standard.string(forKey: qwenKeyUserDefaultsKey),
           !userKey.isEmpty {
            return userKey
        }

        // Then check Secrets.swift (gitignored, for developer use)
        let key = Secrets.qwenAPIKey
        if !key.isEmpty && key != "your_api_key_here" {
            return key
        }

        // Fallback to environment variable
        return ProcessInfo.processInfo.environment["QWEN_API_KEY"]
    }

    static var isMiniMaxConfigured: Bool {
        guard let key = miniMaxAPIKey else { return false }
        return !key.isEmpty
    }

    static var isQwenConfigured: Bool {
        guard let key = qwenAPIKey else { return false }
        return !key.isEmpty
    }

    // MARK: - User Key Management

    static func setUserMiniMaxKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: miniMaxKeyUserDefaultsKey)
    }

    static func setUserQwenKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: qwenKeyUserDefaultsKey)
    }

    static func clearUserKeys() {
        UserDefaults.standard.removeObject(forKey: miniMaxKeyUserDefaultsKey)
        UserDefaults.standard.removeObject(forKey: qwenKeyUserDefaultsKey)
    }

    static var hasUserMiniMaxKey: Bool {
        guard let key = UserDefaults.standard.string(forKey: miniMaxKeyUserDefaultsKey) else { return false }
        return !key.isEmpty
    }

    static var hasUserQwenKey: Bool {
        guard let key = UserDefaults.standard.string(forKey: qwenKeyUserDefaultsKey) else { return false }
        return !key.isEmpty
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

    static var qwenEndpoint: URL {
        region.qwenEndpoint
    }
}
