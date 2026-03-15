import Foundation

enum APIKeyManager {
    static var miniMaxAPIKey: String? {
        // Read from Secrets.swift (gitignored)
        let key = Secrets.miniMaxAPIKey
        if !key.isEmpty && key != "your_api_key_here" {
            return key
        }

        // Fallback to environment variable
        return ProcessInfo.processInfo.environment["MINIMAX_API_KEY"]
    }

    static var qwenAPIKey: String? {
        // Read from Secrets.swift (gitignored)
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
}
