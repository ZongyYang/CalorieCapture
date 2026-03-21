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

    var errorDescription: String? {
        switch self {
        case .apiKeyNotConfigured:
            return "API key not configured. Please set up your API keys in Secrets.swift."
        case .invalidResponse:
            return "Invalid response from AI service."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .parsingError(let message):
            return "Failed to parse food input: \(message)"
        case .chatError(let message):
            return message
        }
    }
}
