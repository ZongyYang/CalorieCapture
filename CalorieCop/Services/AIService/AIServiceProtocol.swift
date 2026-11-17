import Foundation
import UIKit

protocol AIServiceProtocol {
    func parseFoodInput(_ input: String) async throws -> NutritionInfo
    func parseFoodInputMultiple(_ input: String, preferences: [FoodPreference]) async throws -> [NutritionInfo]
    func parseFoodImage(_ image: UIImage, additionalContext: String?, preferences: [FoodPreference]) async throws -> NutritionInfo
    func parseFoodImageMultiple(_ image: UIImage, additionalContext: String?, preferences: [FoodPreference]) async throws -> [NutritionInfo]
}

enum AIServiceError: LocalizedError {
    case apiKeyNotConfigured
    case invalidResponse
    case networkError(Error)
    case parsingError(String)
    case chatError(String)

    static func userFacingMessage(for error: Error, provider: String) -> String {
        if let serviceError = error as? AIServiceError {
            if case .networkError(let underlyingError) = serviceError {
                return userFacingMessage(for: underlyingError, provider: provider)
            }
            return serviceError.errorDescription ?? "AI 请求失败，请重试。"
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return error.localizedDescription
        }

        switch nsError.code {
        case URLError.notConnectedToInternet.rawValue:
            return "当前设备未连接互联网，请检查 Wi‑Fi 或蜂窝网络后重试。"
        case URLError.networkConnectionLost.rawValue:
            return "连接 \(provider) 服务时网络中断，请切换 Wi‑Fi/蜂窝网络或检查 VPN 后重试。"
        case URLError.timedOut.rawValue:
            return "连接 \(provider) 服务超时，请检查网络后重试。"
        case URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue:
            return "无法解析 \(provider) 服务地址，请检查网络或 VPN 设置。"
        case URLError.cannotConnectToHost.rawValue:
            return "暂时无法连接 \(provider) 服务，请稍后重试或检查网络/VPN。"
        case URLError.secureConnectionFailed.rawValue, URLError.serverCertificateUntrusted.rawValue:
            return "与 \(provider) 服务建立安全连接失败，请检查设备日期时间及网络代理设置。"
        default:
            return "连接 \(provider) 服务失败（网络错误 \(nsError.code)），请检查网络后重试。"
        }
    }

    var errorDescription: String? {
        switch self {
        case .apiKeyNotConfigured:
            return "未配置 API 密钥。请在应用内设置 DeepSeek、MiniMax 或 Qwen API 密钥。"
        case .invalidResponse:
            return "AI 返回格式无效，请重试。"
        case .networkError(let error):
            return "网络请求失败：\(error.localizedDescription)"
        case .parsingError(let message):
            return message
        case .chatError(let message):
            return message
        }
    }
}

struct UnitNutritionEstimate {
    let estimatedQuantity: Double
    let proteinPer100: Double
    let carbsPer100: Double
    let fatPer100: Double
}

final class NutritionAutofillService {
    private let aiService = MiniMaxService()

    func estimateUnitNutrition(
        for entry: FoodEntry,
        preferences: [FoodPreference]
    ) async throws -> UnitNutritionEstimate {
        let unit = entry.category.quantityUnitSymbol
        let brandDescription = entry.brand.map { "，品牌：\($0)" } ?? ""
        let prompt: String

        if entry.grams > 0 {
            prompt = """
            请估算以下食物每100\(unit)的营养成分：\(entry.foodName)\(brandDescription)。
            已知本次摄入量为\(entry.grams.formattedGrams)\(unit)，记录总热量为\(entry.calories.formattedCalories)kcal。
            请按100\(unit)返回结果，grams字段返回100，重点给出蛋白质、碳水化合物和脂肪。
            """
        } else {
            prompt = """
            请补全以下食物本次摄入的营养成分：\(entry.foodName)\(brandDescription)。
            已知本次总热量为\(entry.calories.formattedCalories)kcal，但摄入量未知。
            请估算常见单次摄入量；grams字段返回本次摄入量，calories、protein、carbohydrates和fat均返回本次总量。
            """
        }

        let nutritionPreferences = preferences.filter {
            ($0.resolvedProteinPer100 ?? 0)
                + ($0.resolvedCarbsPer100 ?? 0)
                + ($0.resolvedFatPer100 ?? 0) > 0
        }
        let estimate = try await aiService.parseFoodInput(
            prompt,
            preferences: nutritionPreferences
        )
        let estimatedQuantity = estimate.grams > 0 ? estimate.grams : 100
        let scale = 100 / estimatedQuantity
        let protein = max(0, estimate.protein * scale)
        let carbs = max(0, estimate.carbohydrates * scale)
        let fat = max(0, estimate.fat * scale)

        if entry.calories > 0 && protein + carbs + fat <= 0 {
            throw AIServiceError.parsingError("AI 未返回有效的营养成分。")
        }

        return UnitNutritionEstimate(
            estimatedQuantity: estimatedQuantity,
            proteinPer100: protein,
            carbsPer100: carbs,
            fatPer100: fat
        )
    }
}
