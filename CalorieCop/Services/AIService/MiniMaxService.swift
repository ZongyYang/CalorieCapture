import Foundation
import UIKit

final class MiniMaxService: AIServiceProtocol {
    // Endpoints are now dynamic based on user's region setting
    private var endpoint: URL { APIKeyManager.miniMaxEndpoint }
    private var deepSeekEndpoint: URL { APIKeyManager.deepSeekEndpoint }
    private var qwenEndpoint: URL { APIKeyManager.qwenEndpoint }
    // MiniMax-M2.7-highspeed for text parsing
    private let miniMaxTextModel = "MiniMax-M2.7-highspeed"
    private let deepSeekTextModel = "deepseek-v4-flash"
    private let qwenTextModel = "qwen-plus"
    private let qwenVisionModel = "qwen3-vl-plus"
    private let logger = DebugLogger.shared

    func parseFoodInput(_ input: String) async throws -> NutritionInfo {
        try await parseFoodInput(input, preferences: [])
    }

    func parseFoodInput(_ input: String, preferences: [FoodPreference]) async throws -> NutritionInfo {
        // Use the multiple parsing method and return the first item
        let items = try await parseFoodInputMultiple(input, preferences: preferences)
        guard let first = items.first else {
            throw AIServiceError.parsingError("未能解析食物")
        }
        return first
    }

    func parseFoodInputMultiple(_ input: String, preferences: [FoodPreference]) async throws -> [NutritionInfo] {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            throw AIServiceError.parsingError("请输入食物描述")
        }

        guard APIKeyManager.isDeepSeekConfigured || APIKeyManager.isMiniMaxConfigured || APIKeyManager.isQwenConfigured else {
            throw AIServiceError.apiKeyNotConfigured
        }

        let systemPrompt = FoodParsingPrompt.systemPrompt(with: preferences)
        var parseErrors: [String] = []

        if APIKeyManager.isDeepSeekConfigured {
            do {
                return try await parseFoodTextWithDeepSeek(trimmedInput, systemPrompt: systemPrompt)
            } catch {
                logger.logError(error, context: "DeepSeek text parsing failed, trying MiniMax fallback")
                parseErrors.append("DeepSeek：\(compactError(error))")
            }
        } else {
            parseErrors.append("DeepSeek：未配置")
        }

        if APIKeyManager.isMiniMaxConfigured {
            let requestBody = MiniMaxRequest(
                model: miniMaxTextModel,
                messages: [
                    Message(role: "system", content: .text(systemPrompt)),
                    Message(role: "user", content: .text(trimmedInput))
                ]
            )

            do {
                return try await sendRequestMultiple(requestBody)
            } catch {
                logger.logError(error, context: "MiniMax text parsing failed, trying Qwen fallback")
                parseErrors.append("MiniMax：\(compactError(error))")
            }
        } else {
            parseErrors.append("MiniMax：未配置")
        }

        if APIKeyManager.isQwenConfigured {
            do {
                return try await parseFoodTextWithQwen(trimmedInput, systemPrompt: systemPrompt)
            } catch {
                logger.logError(error, context: "Qwen text parsing failed")
                parseErrors.append("Qwen：\(compactError(error))")
            }
        } else {
            parseErrors.append("Qwen：未配置")
        }

        throw AIServiceError.parsingError("文字解析失败。\n\(parseErrors.joined(separator: "\n"))")
    }

    func parseFoodImage(_ image: UIImage, additionalContext: String? = nil, preferences: [FoodPreference] = []) async throws -> NutritionInfo {
        // Use Qwen VL Plus for image parsing (MiniMax vision models not available via API)
        let items = try await parseFoodImageMultiple(image, additionalContext: additionalContext, preferences: preferences)
        guard let first = items.first else {
            throw AIServiceError.parsingError("未能识别图片中的食物")
        }
        return first
    }

    func parseFoodImageMultiple(_ image: UIImage, additionalContext: String? = nil, preferences: [FoodPreference] = []) async throws -> [NutritionInfo] {
        guard let apiKey = APIKeyManager.qwenAPIKey, !apiKey.isEmpty else {
            throw AIServiceError.apiKeyNotConfigured
        }

        // Resize image for faster upload (512px is sufficient for food recognition)
        let resizedImage = resizeImage(image, maxDimension: 512)

        // Convert to base64 with lower quality for speed
        guard let imageData = resizedImage.jpegData(compressionQuality: 0.6) else {
            throw AIServiceError.parsingError("Failed to process image")
        }
        let base64String = imageData.base64EncodedString()

        var userPrompt = "请识别这张图片中的所有食物，并估算每种食物的营养成分。"
        if let context = additionalContext {
            userPrompt += " 额外信息：\(context)"
        }

        let systemPrompt = FoodParsingPrompt.systemPrompt(with: preferences)

        // Build Qwen VL Plus request (OpenAI-compatible format)
        let requestBody: [String: Any] = [
            "model": qwenVisionModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64String)"]],
                    ["type": "text", "text": userPrompt]
                ]]
            ],
            "temperature": 0.1,
            "stream": false
        ]

        // Use dynamic endpoint based on user's region setting
        var request = URLRequest(url: qwenEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        logger.logAPIRequest(endpoint: qwenEndpoint.absoluteString, body: "model=\(qwenVisionModel), imageBytes=\(imageData.count)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }

        // Debug - log raw response
        let rawString = String(data: data, encoding: .utf8) ?? "无法解码响应"
        logger.logAPIResponse(statusCode: httpResponse.statusCode, body: rawString)

        guard (200...299).contains(httpResponse.statusCode) else {
            throw AIServiceError.parsingError("Qwen API Error (\(httpResponse.statusCode)): \(rawString)")
        }

        // Parse Qwen response (OpenAI-compatible format)
        struct QwenResponse: Decodable {
            let choices: [Choice]?
            let error: QwenError?

            struct Choice: Decodable {
                let message: Message
                struct Message: Decodable {
                    let content: String
                }
            }

            struct QwenError: Decodable {
                let message: String?
                let code: String?
            }
        }

        let qwenResponse: QwenResponse
        do {
            qwenResponse = try JSONDecoder().decode(QwenResponse.self, from: data)
        } catch {
            logger.logError(error, context: "Qwen response decode")
            throw AIServiceError.parsingError("Qwen响应格式错误: \(rawString.prefix(300))")
        }

        // Check for API error
        if let error = qwenResponse.error {
            throw AIServiceError.parsingError("Qwen错误: \(error.message ?? error.code ?? "未知错误")")
        }

        guard let content = qwenResponse.choices?.first?.message.content else {
            throw AIServiceError.parsingError("Qwen返回为空: \(rawString.prefix(300))")
        }

        return try decodeNutritionList(from: content, context: "Qwen image")
    }

    private func parseFoodTextWithQwen(_ input: String, systemPrompt: String) async throws -> [NutritionInfo] {
        guard let apiKey = APIKeyManager.qwenAPIKey, !apiKey.isEmpty else {
            throw AIServiceError.apiKeyNotConfigured
        }

        let requestBody: [String: Any] = [
            "model": qwenTextModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": input]
            ],
            "temperature": 0.1
        ]

        var request = URLRequest(url: qwenEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = bodyData
        logger.logAPIRequest(endpoint: qwenEndpoint.absoluteString, body: String(data: bodyData, encoding: .utf8))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }

        let rawString = String(data: data, encoding: .utf8) ?? "无法解码响应"
        logger.logAPIResponse(statusCode: httpResponse.statusCode, body: rawString)

        guard (200...299).contains(httpResponse.statusCode) else {
            throw AIServiceError.parsingError("Qwen API Error (\(httpResponse.statusCode)): \(rawString.prefix(300))")
        }

        struct QwenTextResponse: Decodable {
            let choices: [Choice]?
            let error: QwenError?

            struct Choice: Decodable {
                let message: Message
                struct Message: Decodable {
                    let content: String
                }
            }

            struct QwenError: Decodable {
                let message: String?
                let code: String?
            }
        }

        let qwenResponse: QwenTextResponse
        do {
            qwenResponse = try JSONDecoder().decode(QwenTextResponse.self, from: data)
        } catch {
            logger.logError(error, context: "Qwen text response decode")
            throw AIServiceError.parsingError("Qwen响应格式错误: \(rawString.prefix(300))")
        }

        if let error = qwenResponse.error {
            throw AIServiceError.parsingError("Qwen错误: \(error.message ?? error.code ?? "未知错误")")
        }

        guard let content = qwenResponse.choices?.first?.message.content else {
            throw AIServiceError.parsingError("Qwen返回为空: \(rawString.prefix(300))")
        }

        return try decodeNutritionList(from: content, context: "Qwen text")
    }

    private func parseFoodTextWithDeepSeek(_ input: String, systemPrompt: String) async throws -> [NutritionInfo] {
        guard let apiKey = APIKeyManager.deepSeekAPIKey, !apiKey.isEmpty else {
            throw AIServiceError.apiKeyNotConfigured
        }

        let requestBody: [String: Any] = [
            "model": deepSeekTextModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": input]
            ],
            "temperature": 0.1,
            "stream": false
        ]

        var request = URLRequest(url: deepSeekEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = bodyData
        logger.logAPIRequest(endpoint: deepSeekEndpoint.absoluteString, body: String(data: bodyData, encoding: .utf8))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }

        let rawString = String(data: data, encoding: .utf8) ?? "无法解码响应"
        logger.logAPIResponse(statusCode: httpResponse.statusCode, body: rawString)

        guard (200...299).contains(httpResponse.statusCode) else {
            throw AIServiceError.parsingError("DeepSeek API Error (\(httpResponse.statusCode)): \(rawString.prefix(300))")
        }

        struct DeepSeekTextResponse: Decodable {
            let choices: [Choice]?
            let error: DeepSeekError?

            struct Choice: Decodable {
                let message: Message
                struct Message: Decodable {
                    let content: String
                }
            }

            struct DeepSeekError: Decodable {
                let message: String?
                let code: String?
            }
        }

        let deepSeekResponse: DeepSeekTextResponse
        do {
            deepSeekResponse = try JSONDecoder().decode(DeepSeekTextResponse.self, from: data)
        } catch {
            logger.logError(error, context: "DeepSeek text response decode")
            throw AIServiceError.parsingError("DeepSeek响应格式错误: \(rawString.prefix(300))")
        }

        if let error = deepSeekResponse.error {
            throw AIServiceError.parsingError("DeepSeek错误: \(error.message ?? error.code ?? "未知错误")")
        }

        guard let content = deepSeekResponse.choices?.first?.message.content else {
            throw AIServiceError.parsingError("DeepSeek返回为空: \(rawString.prefix(300))")
        }

        return try decodeNutritionList(from: content, context: "DeepSeek text")
    }

    private func sendRequestMultiple(_ requestBody: MiniMaxRequest) async throws -> [NutritionInfo] {
        guard let apiKey = APIKeyManager.miniMaxAPIKey, !apiKey.isEmpty else {
            throw AIServiceError.apiKeyNotConfigured
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = try JSONEncoder().encode(requestBody)
        request.httpBody = bodyData
        logger.logAPIRequest(endpoint: endpoint.absoluteString, body: String(data: bodyData, encoding: .utf8))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }

        let rawString = String(data: data, encoding: .utf8) ?? "无法解码响应"
        logger.logAPIResponse(statusCode: httpResponse.statusCode, body: rawString)

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.logError(AIServiceError.parsingError("HTTP \(httpResponse.statusCode)"), context: "API call failed")
            throw AIServiceError.parsingError("API Error (\(httpResponse.statusCode)): \(rawString)")
        }

        let miniMaxResponse: MiniMaxResponse
        do {
            miniMaxResponse = try JSONDecoder().decode(MiniMaxResponse.self, from: data)
        } catch {
            logger.logError(error, context: "MiniMaxResponse decode")
            throw AIServiceError.parsingError("API响应格式错误: \(rawString.prefix(300))")
        }

        if let errorMessage = miniMaxResponse.errorMessage {
            logger.log("API returned error: \(errorMessage)")
            throw AIServiceError.parsingError("API错误: \(errorMessage)")
        }

        guard let content = miniMaxResponse.firstContent else {
            logger.log("API returned empty content. Raw: \(rawString)")
            throw AIServiceError.parsingError("API返回为空: \(rawString.prefix(300))")
        }

        return try decodeNutritionList(from: content, context: "MiniMax text")
    }

    private func sendRequest(_ requestBody: MiniMaxRequest) async throws -> NutritionInfo {
        guard let apiKey = APIKeyManager.miniMaxAPIKey else {
            throw AIServiceError.apiKeyNotConfigured
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }

        let rawString = String(data: data, encoding: .utf8) ?? "无法解码响应"
        logger.logAPIResponse(statusCode: httpResponse.statusCode, body: rawString)

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.logError(AIServiceError.parsingError("HTTP \(httpResponse.statusCode)"), context: "API call failed")
            throw AIServiceError.parsingError("API Error (\(httpResponse.statusCode)): \(rawString)")
        }

        let miniMaxResponse: MiniMaxResponse
        do {
            miniMaxResponse = try JSONDecoder().decode(MiniMaxResponse.self, from: data)
        } catch {
            logger.logError(error, context: "MiniMaxResponse decode")
            throw AIServiceError.parsingError("API响应格式错误: \(rawString.prefix(300))")
        }

        if let errorMessage = miniMaxResponse.errorMessage {
            logger.log("API returned error: \(errorMessage)")
            throw AIServiceError.parsingError("API错误: \(errorMessage)")
        }

        guard let content = miniMaxResponse.firstContent else {
            logger.log("API returned empty content. Raw: \(rawString)")
            throw AIServiceError.parsingError("API返回为空: \(rawString.prefix(300))")
        }

        let jsonString = extractJSON(from: content)
        logger.log("Extracted JSON: \(jsonString)")

        guard let contentData = jsonString.data(using: .utf8) else {
            throw AIServiceError.parsingError("无法转换内容")
        }

        do {
            let nutritionInfo = try JSONDecoder().decode(NutritionInfo.self, from: contentData)
            return nutritionInfo
        } catch {
            logger.logError(error, context: "NutritionInfo decode. JSON: \(jsonString)")
            throw AIServiceError.parsingError("营养信息解析失败: \(jsonString.prefix(200))")
        }
    }

    private func extractJSON(from content: String) -> String {
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to find JSON array first
        if let start = cleaned.firstIndex(of: "["),
           let end = cleaned.lastIndex(of: "]") {
            return String(cleaned[start...end])
        }

        // Try to find JSON object
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            return String(cleaned[start...end])
        }

        // Fallback: Convert YAML-like format to JSON
        // Format like: food_name: 煮玉米\ngrams: 200\n...
        if cleaned.contains(":") && !cleaned.contains("{") && !cleaned.contains("[") {
            return convertYAMLToJSON(cleaned)
        }

        return cleaned
    }

    private func decodeNutritionList(from content: String, context: String) throws -> [NutritionInfo] {
        let jsonString = extractJSON(from: content)
        logger.log("\(context) extracted JSON: \(jsonString)")

        guard let contentData = jsonString.data(using: .utf8) else {
            throw AIServiceError.parsingError("无法转换内容")
        }

        do {
            return try JSONDecoder().decode([NutritionInfo].self, from: contentData)
        } catch {
            logger.log("Array decode failed for \(context), trying single object: \(error)")
            do {
                let nutritionInfo = try JSONDecoder().decode(NutritionInfo.self, from: contentData)
                return [nutritionInfo]
            } catch {
                logger.logError(error, context: "\(context) nutrition decode. JSON: \(jsonString)")
                throw AIServiceError.parsingError("营养信息解析失败: \(jsonString.prefix(200))")
            }
        }
    }

    private func compactError(_ error: Error) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(message.prefix(220))
    }

    private func convertYAMLToJSON(_ yaml: String) -> String {
        var dict: [String: Any] = [:]
        let lines = yaml.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Split on first colon
            if let colonIndex = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

                // Skip empty values
                guard !value.isEmpty else { continue }

                // Try to parse as number
                if let doubleValue = Double(value) {
                    dict[key] = doubleValue
                } else if let intValue = Int(value) {
                    dict[key] = intValue
                } else {
                    // Remove quotes if present
                    var strValue = value
                    if (strValue.hasPrefix("\"") && strValue.hasSuffix("\"")) ||
                       (strValue.hasPrefix("'") && strValue.hasSuffix("'")) {
                        strValue = String(strValue.dropFirst().dropLast())
                    }
                    dict[key] = strValue
                }
            }
        }

        // Convert to JSON
        if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }

        return yaml
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSize = max(size.width, size.height)

        if maxSize <= maxDimension {
            return image
        }

        let scale = maxDimension / maxSize
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resizedImage ?? image
    }
}

// MARK: - Request Models

private struct MiniMaxRequest: Encodable {
    let model: String
    let messages: [Message]
}

private struct Message: Encodable {
    let role: String
    let content: MessageContent

    enum MessageContent: Encodable {
        case text(String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let string):
                try container.encode(string)
            }
        }
    }
}

// Vision request models
private struct MiniMaxVisionRequest: Encodable {
    let model: String
    let messages: [VisionMessage]
}

private struct VisionMessage: Encodable {
    let role: String
    let content: VisionContent

    enum VisionContent: Encodable {
        case text(String)
        case mixed([Any])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let string):
                try container.encode(string)
            case .mixed(_):
                break // Handled by custom init
            }
        }
    }

    init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
    }

    init(role: String, content: [any Encodable]) {
        self.role = role
        self.content = .mixed([])
        self._content = content
    }

    private var _content: [any Encodable]?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        if let mixedContent = _content {
            var contentContainer = container.nestedUnkeyedContainer(forKey: .content)
            for item in mixedContent {
                if let imageContent = item as? ImageContent {
                    try contentContainer.encode(imageContent)
                } else if let textContent = item as? TextContent {
                    try contentContainer.encode(textContent)
                }
            }
        } else {
            switch content {
            case .text(let string):
                try container.encode(string, forKey: .content)
            case .mixed:
                break
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case role, content
    }
}

private struct ImageContent: Encodable {
    let type: String
    let imageUrl: ImageURL

    enum CodingKeys: String, CodingKey {
        case type
        case imageUrl = "image_url"
    }
}

private struct ImageURL: Encodable {
    let url: String
}

private struct TextContent: Encodable {
    let type: String
    let text: String
}

// MARK: - Response Models

private struct MiniMaxResponse: Decodable {
    let choices: [Choice]?
    let error: MiniMaxError?
    let baseResp: MiniMaxBaseResponse?

    enum CodingKeys: String, CodingKey {
        case choices
        case error
        case baseResp = "base_resp"
    }

    // Handle both possible response structures
    var firstContent: String? {
        choices?.first?.message.content
    }

    var errorMessage: String? {
        if let error {
            return error.message ?? error.code ?? "未知错误"
        }

        if let baseResp, baseResp.statusCode != 0 {
            return baseResp.statusMessage ?? "status_code \(baseResp.statusCode)"
        }

        return nil
    }
}

private struct MiniMaxError: Decodable {
    let message: String?
    let code: String?
}

private struct MiniMaxBaseResponse: Decodable {
    let statusCode: Int
    let statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMessage = "status_msg"
    }
}

private struct Choice: Decodable {
    let message: ResponseMessage
}

private struct ResponseMessage: Decodable {
    let content: String
}
