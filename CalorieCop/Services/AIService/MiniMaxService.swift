import Foundation
import UIKit

/// Parses meal summaries whose total energy and all three macronutrients were
/// explicitly supplied by the user. This deliberately runs on device before
/// any network request: the values are facts supplied by the user, not values
/// that need an AI estimate.
enum NutritionSummaryParser {
    static func canParse(_ input: String) -> Bool {
        parse(input) != nil
    }

    static func parse(_ input: String) -> NutritionInfo? {
        let normalizedInput = input
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "；", with: ";")
            .replacingOccurrences(of: "：", with: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Nutrients described per 100 g are reference values, not the total
        // intake that this shortcut is meant to record.
        guard !normalizedInput.localizedCaseInsensitiveContains("每100"),
              !normalizedInput.localizedCaseInsensitiveContains("per 100"),
              let calories = totalCalories(in: normalizedInput),
              let protein = value(
                in: normalizedInput,
                labels: ["蛋白质", "蛋白"]
              ),
              let carbohydrates = value(
                in: normalizedInput,
                labels: ["碳水化合物", "碳水"]
              ),
              let fat = value(
                in: normalizedInput,
                labels: ["脂肪"]
              ) else {
            return nil
        }

        let grams = intakeQuantity(in: normalizedInput) ?? 0
        let quantityNote = grams > 0
            ? "已直接采用输入的总热量和营养成分，未进行 AI 推断。"
            : "已直接采用输入的总热量和营养成分，未进行 AI 推断；摄入量未提供，可按需编辑。"

        return NutritionInfo(
            foodName: foodName(from: normalizedInput),
            grams: grams,
            calories: calories,
            protein: protein,
            carbohydrates: carbohydrates,
            fat: fat,
            confidence: "manual",
            notes: quantityNote
        )
    }

    private static func totalCalories(in input: String) -> Double? {
        guard let match = firstMatch(
            pattern: #"(?:总\s*(?:热量|能量)|总计|合计|热量|能量)\s*(?:约|≈|=|为|是|:)?\s*([0-9]+(?:[\.,][0-9]+)?)\s*(千卡|大卡|卡路里|kcal|千焦|kj)"#,
            in: input
        ), let value = number(from: match, in: input, at: 1) else {
            return nil
        }

        let unit = string(from: match, in: input, at: 2)?.lowercased() ?? ""
        return unit == "千焦" || unit == "kj" ? value / 4.184 : value
    }

    private static func value(in input: String, labels: [String]) -> Double? {
        let escapedLabels = labels.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = #"(?:"# + escapedLabels + #")\s*(?:含量)?\s*(?:约|≈|=|为|是|:)?\s*([0-9]+(?:[\.,][0-9]+)?)\s*(?:g|克)"#
        guard let match = firstMatch(pattern: pattern, in: input) else { return nil }
        return number(from: match, in: input, at: 1)
    }

    private static func intakeQuantity(in input: String) -> Double? {
        guard let match = firstMatch(
            pattern: #"(?:摄入量|食用量|份量|重量|净含量|规格)\s*(?:约|≈|=|为|是|:)?\s*([0-9]+(?:[\.,][0-9]+)?)\s*(?:g|克|ml|毫升)"#,
            in: input
        ) else {
            return nil
        }
        return number(from: match, in: input, at: 1)
    }

    private static func foodName(from input: String) -> String {
        let firstClause = input
            .split(whereSeparator: { ",;。.!！？?\n".contains($0) })
            .first
            .map(String.init) ?? ""
        let removablePrefixes = ["今天", "今日", "早餐", "午餐", "晚餐", "夜宵", "我吃了", "吃了", "记录"]
        var name = firstClause.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in removablePrefixes where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        }

        return name.isEmpty || name.contains("热量") || name.contains("能量")
            ? "本次摄入"
            : name
    }

    private static func firstMatch(pattern: String, in input: String) -> NSTextCheckingResult? {
        let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(input.startIndex..., in: input)
        return expression?.firstMatch(in: input, options: [], range: range)
    }

    private static func number(from match: NSTextCheckingResult, in input: String, at index: Int) -> Double? {
        guard let text = string(from: match, in: input, at: index) else { return nil }
        return Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private static func string(from match: NSTextCheckingResult, in input: String, at index: Int) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: input) else {
            return nil
        }
        return String(input[swiftRange])
    }
}

final class MiniMaxService: AIServiceProtocol {
    // Endpoints are now dynamic based on user's region setting
    private var endpoint: URL { APIKeyManager.miniMaxEndpoint }
    private var deepSeekResponsesEndpoint: URL { APIKeyManager.deepSeekResponsesEndpoint }
    private var qwenEndpoint: URL { APIKeyManager.qwenEndpoint }
    // MiniMax-M2.7-highspeed for text parsing
    private let qwenTextModel = "qwen-plus"
    private let deepSeekVisionModel = "deepseek-v4-flash-vision-exp"
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

        if let summary = NutritionSummaryParser.parse(trimmedInput) {
            logger.log("Used direct nutrition summary from text input")
            return [summary]
        }

        let selectedModel = APIKeyManager.textParsingModel
        guard APIKeyManager.isTextParsingModelConfigured(selectedModel) else {
            throw AIServiceError.parsingError(
                "已选择 \(selectedModel.displayName)，请先在设置中配置 \(selectedModel.providerName) API 密钥。"
            )
        }

        return try await parseFoodText(
            trimmedInput,
            using: selectedModel,
            systemPrompt: FoodParsingPrompt.systemPrompt(with: preferences)
        )
    }

    private func parseFoodText(
        _ input: String,
        using selectedModel: TextParsingModel,
        systemPrompt: String
    ) async throws -> [NutritionInfo] {
        switch selectedModel {
        case .flash, .pro:
            return try await parseFoodTextWithDeepSeek(
                input,
                systemPrompt: systemPrompt,
                model: selectedModel.apiModelName,
                reasoningEnabled: selectedModel.usesDeepSeekReasoning
            )
        case .highspeed:
            let requestBody = MiniMaxRequest(
                model: selectedModel.apiModelName,
                messages: [
                    Message(role: "system", content: .text(systemPrompt)),
                    Message(role: "user", content: .text(input))
                ]
            )
            return try await sendRequestMultiple(requestBody)
        }
    }

    func parseFoodImage(_ image: UIImage, additionalContext: String? = nil, preferences: [FoodPreference] = []) async throws -> NutritionInfo {
        // Food photos use DeepSeek Vision, independent of the text model selected in the UI.
        let items = try await parseFoodImageMultiple(image, additionalContext: additionalContext, preferences: preferences)
        guard let first = items.first else {
            throw AIServiceError.parsingError("未能识别图片中的食物")
        }
        return first
    }

    func parseFoodImageMultiple(_ image: UIImage, additionalContext: String? = nil, preferences: [FoodPreference] = []) async throws -> [NutritionInfo] {
        guard let apiKey = APIKeyManager.deepSeekAPIKey, !apiKey.isEmpty else {
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

        return try await requestDeepSeekResponse(
            model: deepSeekVisionModel,
            systemPrompt: systemPrompt,
            content: [
                ["type": "input_text", "text": userPrompt],
                [
                    "type": "input_image",
                    "image_url": "data:image/jpeg;base64,\(base64String)",
                    "detail": "low"
                ]
            ],
            reasoningEffort: "none",
            imageBytes: imageData.count,
            apiKey: apiKey,
            context: "DeepSeek image"
        )
    }

    private func parseFoodTextWithQwen(
        _ input: String,
        systemPrompt: String,
        model: String? = nil
    ) async throws -> [NutritionInfo] {
        guard let apiKey = APIKeyManager.qwenAPIKey, !apiKey.isEmpty else {
            throw AIServiceError.apiKeyNotConfigured
        }

        let requestBody: [String: Any] = [
            "model": model ?? qwenTextModel,
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

    private func parseFoodTextWithDeepSeek(
        _ input: String,
        systemPrompt: String,
        model: String,
        reasoningEnabled: Bool
    ) async throws -> [NutritionInfo] {
        guard let apiKey = APIKeyManager.deepSeekAPIKey, !apiKey.isEmpty else {
            throw AIServiceError.apiKeyNotConfigured
        }

        return try await requestDeepSeekResponse(
            model: model,
            systemPrompt: systemPrompt,
            content: [["type": "input_text", "text": input]],
            reasoningEffort: reasoningEnabled ? "high" : "none",
            apiKey: apiKey,
            context: "DeepSeek text"
        )
    }

    /// Uses DeepSeek's Responses API so the model can automatically look up
    /// branded or otherwise uncertain food details before returning nutrition JSON.
    private func requestDeepSeekResponse(
        model: String,
        systemPrompt: String,
        content: [[String: Any]],
        reasoningEffort: String,
        imageBytes: Int? = nil,
        apiKey: String,
        context: String
    ) async throws -> [NutritionInfo] {
        let requestBody: [String: Any] = [
            "model": model,
            "instructions": systemPrompt,
            "input": [["role": "user", "content": content]],
            "reasoning": ["effort": reasoningEffort],
            "temperature": 0.1,
            // The server decides whether a search is useful, so simple meals do
            // not always pay the latency cost of a web lookup.
            "tools": [["type": "web_search"]],
            "tool_choice": "auto",
            "stream": false
        ]

        var request = URLRequest(url: deepSeekResponsesEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let metadata = imageBytes.map { ", imageBytes=\($0)" } ?? ""
        logger.logAPIRequest(
            endpoint: deepSeekResponsesEndpoint.absoluteString,
            body: "model=\(model), webSearch=auto\(metadata)"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }

        let rawString = String(data: data, encoding: .utf8) ?? "无法解码响应"
        logger.logAPIResponse(statusCode: httpResponse.statusCode, body: rawString)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AIServiceError.parsingError("DeepSeek API Error (\(httpResponse.statusCode)): \(rawString.prefix(300))")
        }

        let deepSeekResponse: DeepSeekResponsesResponse
        do {
            deepSeekResponse = try JSONDecoder().decode(DeepSeekResponsesResponse.self, from: data)
        } catch {
            logger.logError(error, context: "DeepSeek Responses decode")
            throw AIServiceError.parsingError("DeepSeek响应格式错误: \(rawString.prefix(300))")
        }

        if let error = deepSeekResponse.error {
            throw AIServiceError.parsingError("DeepSeek错误: \(error.message ?? error.code ?? "未知错误")")
        }

        guard deepSeekResponse.status == nil || deepSeekResponse.status == "completed",
              let outputText = deepSeekResponse.outputText,
              !outputText.isEmpty else {
            throw AIServiceError.parsingError("DeepSeek返回为空: \(rawString.prefix(300))")
        }

        return try decodeNutritionList(from: outputText, context: context)
    }

    private struct DeepSeekResponsesResponse: Decodable {
        let status: String?
        let output: [OutputItem]?
        let error: ResponseError?

        struct OutputItem: Decodable {
            let content: [ContentPart]?
        }

        struct ContentPart: Decodable {
            let type: String?
            let text: String?
        }

        struct ResponseError: Decodable {
            let message: String?
            let code: String?
        }

        var outputText: String? {
            let text = output?
                .flatMap { $0.content ?? [] }
                .compactMap { part in
                    part.type == "output_text" ? part.text : nil
                }
                .joined(separator: "\n") ?? ""
            return text.isEmpty ? nil : text
        }
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
