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

enum TextParsingModel: String, CaseIterable, Identifiable {
    /// Fast daily text recognition with DeepSeek's reasoning explicitly disabled.
    case flash
    /// A fast MiniMax alternative for users who prefer its responses.
    case highspeed
    /// DeepSeek's stronger model with reasoning enabled for more complex descriptions.
    case pro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flash: return "Flash"
        case .highspeed: return "Highspeed"
        case .pro: return "Pro"
        }
    }

    var providerName: String {
        switch self {
        case .flash, .pro: return "DeepSeek"
        case .highspeed: return "MiniMax"
        }
    }

    var speedDescription: String {
        switch self {
        case .flash:
            return "最快：关闭推理，适合日常食物文字解析。"
        case .highspeed:
            return "快速：使用 MiniMax M2.7 Highspeed。"
        case .pro:
            return "更仔细：开启推理，适合复杂的餐食描述。"
        }
    }

    var apiModelName: String {
        switch self {
        case .flash: return "deepseek-v4-flash"
        case .highspeed: return "MiniMax-M2.7-highspeed"
        case .pro: return "deepseek-v4-pro"
        }
    }

    var usesDeepSeekReasoning: Bool {
        self == .pro
    }
}

enum APIKeyManager {
    private static let miniMaxKeyUserDefaultsKey = "user_minimax_api_key"
    private static let deepSeekKeyUserDefaultsKey = "user_deepseek_api_key"
    private static let qwenKeyUserDefaultsKey = "user_qwen_api_key"
    private static let regionUserDefaultsKey = "user_api_region"
    static let textParsingModelUserDefaultsKey = "user_text_parsing_model"

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

    /// Only keys the user explicitly entered in the app are exposed here.
    /// Developer defaults and environment keys remain hidden in API Settings.
    static var userMiniMaxAPIKey: String? {
        normalizedKey(UserDefaults.standard.string(forKey: miniMaxKeyUserDefaultsKey))
    }

    static var userDeepSeekAPIKey: String? {
        normalizedKey(UserDefaults.standard.string(forKey: deepSeekKeyUserDefaultsKey))
    }

    static var userQwenAPIKey: String? {
        normalizedKey(UserDefaults.standard.string(forKey: qwenKeyUserDefaultsKey))
    }

    static var hasUserMiniMaxKey: Bool {
        userMiniMaxAPIKey != nil
    }

    static var hasUserDeepSeekKey: Bool {
        userDeepSeekAPIKey != nil
    }

    static var hasUserQwenKey: Bool {
        userQwenAPIKey != nil
    }

    // MARK: - Text Parsing Model

    static var textParsingModel: TextParsingModel {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: textParsingModelUserDefaultsKey),
                  let model = TextParsingModel(rawValue: rawValue) else {
                return .flash
            }
            return model
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: textParsingModelUserDefaultsKey)
        }
    }

    static func isTextParsingModelConfigured(_ model: TextParsingModel) -> Bool {
        switch model {
        case .flash, .pro:
            return isDeepSeekConfigured
        case .highspeed:
            return isMiniMaxConfigured
        }
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

    /// Responses API supports both server-side web search and vision input.
    static var deepSeekResponsesEndpoint: URL {
        URL(string: "https://api.deepseek.com/responses")!
    }

    static var qwenEndpoint: URL {
        region.qwenEndpoint
    }
}
