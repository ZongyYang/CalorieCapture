import Foundation
import UIKit

final class MiniMaxService: AIServiceProtocol {
    private let endpoint = URL(string: "https://api.minimaxi.chat/v1/text/chatcompletion_v2")!
    // MiniMax-M2.5-highspeed for fast text parsing (~3s vs ~11s for regular M2.5)
    private let model = "MiniMax-M2.5-highspeed"
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
        guard let apiKey = APIKeyManager.miniMaxAPIKey, !apiKey.isEmpty else {
            throw AIServiceError.apiKeyNotConfigured
        }

        let systemPrompt = FoodParsingPrompt.systemPrompt(with: preferences)

        let requestBody = MiniMaxRequest(
            model: model,
            messages: [
                Message(role: "system", content: .text(systemPrompt)),
                Message(role: "user", content: .text(input))
            ]
        )

        return try await sendRequestMultiple(requestBody)
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
            "model": "qwen-vl-plus",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64String)"]],
                    ["type": "text", "text": userPrompt]
                ]]
            ]
        ]

        let qwenEndpoint = URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")!
        var request = URLRequest(url: qwenEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

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

        let jsonString = extractJSON(from: content)
        logger.log("Image parsing extracted JSON: \(jsonString)")

        guard let contentData = jsonString.data(using: .utf8) else {
            throw AIServiceError.parsingError("Failed to convert content to data")
        }

        // Try to decode as array first
        do {
            let nutritionArray = try JSONDecoder().decode([NutritionInfo].self, from: contentData)
            return nutritionArray
        } catch {
            // Fallback: try single object and wrap in array
            do {
                let nutritionInfo = try JSONDecoder().decode(NutritionInfo.self, from: contentData)
                return [nutritionInfo]
            } catch {
                logger.logError(error, context: "Image nutrition decode. JSON: \(jsonString)")
                throw AIServiceError.parsingError("图片解析失败: \(jsonString.prefix(200))")
            }
        }
    }

    private func sendRequestMultiple(_ requestBody: MiniMaxRequest) async throws -> [NutritionInfo] {
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

        if let apiError = miniMaxResponse.error {
            logger.log("API returned error: \(apiError.message ?? apiError.code ?? "unknown")")
            throw AIServiceError.parsingError("API错误: \(apiError.message ?? apiError.code ?? "未知错误")")
        }

        guard let content = miniMaxResponse.firstContent else {
            logger.log("API returned empty content. Raw: \(rawString)")
            throw AIServiceError.parsingError("API返回为空: \(rawString.prefix(300))")
        }

        let jsonString = extractJSON(from: content)
        logger.log("Extracted JSON (multiple): \(jsonString)")

        guard let contentData = jsonString.data(using: .utf8) else {
            throw AIServiceError.parsingError("无法转换内容")
        }

        // Try to decode as array first
        do {
            let nutritionInfoArray = try JSONDecoder().decode([NutritionInfo].self, from: contentData)
            return nutritionInfoArray
        } catch {
            // If array parsing fails, try single object and wrap in array
            logger.log("Array decode failed, trying single object: \(error)")
            do {
                let nutritionInfo = try JSONDecoder().decode(NutritionInfo.self, from: contentData)
                return [nutritionInfo]
            } catch {
                logger.logError(error, context: "NutritionInfo decode. JSON: \(jsonString)")
                throw AIServiceError.parsingError("营养信息解析失败: \(jsonString.prefix(200))")
            }
        }
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

        if let apiError = miniMaxResponse.error {
            logger.log("API returned error: \(apiError.message ?? apiError.code ?? "unknown")")
            throw AIServiceError.parsingError("API错误: \(apiError.message ?? apiError.code ?? "未知错误")")
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

    // Handle both possible response structures
    var firstContent: String? {
        choices?.first?.message.content
    }
}

private struct MiniMaxError: Decodable {
    let message: String?
    let code: String?
}

private struct Choice: Decodable {
    let message: ResponseMessage
}

private struct ResponseMessage: Decodable {
    let content: String
}
