import CryptoKit
import Foundation
import Security
import SwiftUI
import UIKit

enum LocalCodexOrderSettings {
    static let addressKey = "localCodexOrderAddress"
    static let fingerprintKey = "localCodexOrderFingerprint"
    private static let keychainService = "com.zyyang116.caloriecapture.orderbridge"
    private static let keychainAccount = "pairing-token"

    static var address: String { UserDefaults.standard.string(forKey: addressKey) ?? "" }
    static var fingerprint: String { UserDefaults.standard.string(forKey: fingerprintKey) ?? "" }
    static var token: String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static var isConfigured: Bool {
        !address.isEmpty && !fingerprint.isEmpty && !token.isEmpty
    }

    static func save(address: String, fingerprint: String, token: String) throws {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFingerprint = fingerprint
            .filter { $0.isHexDigit }
            .lowercased()
        guard let url = URL(string: trimmedAddress), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil,
              normalizedFingerprint.count == 64,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalCodexOrderError.invalidSettings
        }

        let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw LocalCodexOrderError.keychainFailure
        }
        UserDefaults.standard.set(trimmedAddress.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: addressKey)
        UserDefaults.standard.set(normalizedFingerprint, forKey: fingerprintKey)
    }
}

enum LocalCodexOrderError: LocalizedError {
    case invalidSettings
    case keychainFailure
    case imageTooLarge
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidSettings: return "请填写有效的 Mac HTTPS 地址、配对令牌和 64 位证书指纹。"
        case .keychainFailure: return "无法保存配对令牌到钥匙串。"
        case .imageTooLarge: return "截图超过 8 MB，请裁剪后重试。"
        case .invalidResponse: return "Mac 返回的识别结果无效，请重试。"
        case .server(let message): return message
        }
    }
}

private final class PinnedOrderBridgeDelegate: NSObject, URLSessionDelegate {
    let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let data = SecCertificateCopyData(certificate) as Data
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

struct LocalCodexOrderService {
    private struct Response: Decodable {
        let items: [NutritionInfo]
    }

    private static func session() throws -> URLSession {
        guard LocalCodexOrderSettings.isConfigured else { throw LocalCodexOrderError.invalidSettings }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 190
        configuration.timeoutIntervalForResource = 200
        return URLSession(configuration: configuration,
                          delegate: PinnedOrderBridgeDelegate(fingerprint: LocalCodexOrderSettings.fingerprint),
                          delegateQueue: nil)
    }

    private static func request(path: String) throws -> URLRequest {
        guard let base = URL(string: LocalCodexOrderSettings.address),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme == "https" else { throw LocalCodexOrderError.invalidSettings }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(LocalCodexOrderSettings.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func testConnection() async throws {
        let session = try session()
        var request = try request(path: "/health")
        request.timeoutInterval = 10
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw LocalCodexOrderError.server("连接失败，请核对地址、配对令牌和 Mac 服务状态。")
        }
    }

    static func parse(image: UIImage, context: String) async throws -> [NutritionInfo] {
        guard let imageData = image.jpegData(compressionQuality: 0.85), imageData.count <= 8 * 1024 * 1024 else {
            throw LocalCodexOrderError.imageTooLarge
        }
        let session = try session()
        var request = try request(path: "/parse-order")
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let contextData = Data(context.prefix(500).utf8)
        request.setValue(contextData.base64EncodedString(), forHTTPHeaderField: "X-Order-Context")
        request.httpBody = imageData
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LocalCodexOrderError.invalidResponse }
        guard response.statusCode == 200 else {
            throw LocalCodexOrderError.server("Mac 识别失败（HTTP \(response.statusCode)），请检查 Codex 登录和服务终端。")
        }
        guard let result = try? JSONDecoder().decode(Response.self, from: data),
              result.items.count <= 30,
              result.items.allSatisfy({ !$0.foodName.isEmpty && $0.calories >= 0 && $0.grams >= 0 }) else {
            throw LocalCodexOrderError.invalidResponse
        }
        return result.items
    }
}

struct LocalCodexOrderSettingsView: View {
    @State private var address = LocalCodexOrderSettings.address
    @State private var fingerprint = LocalCodexOrderSettings.fingerprint
    @State private var token = LocalCodexOrderSettings.token
    @State private var statusMessage: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Mac 连接") {
                TextField("https://Mac 地址:8765", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("配对令牌", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("证书 SHA-256 指纹", text: $fingerprint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存并测试连接") {
                    Task {
                        isTesting = true
                        defer { isTesting = false }
                        do {
                            try LocalCodexOrderSettings.save(address: address, fingerprint: fingerprint, token: token)
                            try await LocalCodexOrderService.testConnection()
                            statusMessage = "Mac 服务已连接"
                        } catch {
                            statusMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(isTesting)
                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Mac 上运行 tools/order-bridge/order_bridge.py 后，将终端显示的地址、令牌和证书指纹填入这里。仅在私人网络中使用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Mac Codex")
        .navigationBarTitleDisplayMode(.inline)
    }
}
