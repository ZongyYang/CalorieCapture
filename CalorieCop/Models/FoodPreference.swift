import Foundation
import SwiftData

@Model
final class FoodPreference {
    var id: UUID
    var keyword: String          // 用户输入的关键词，如 "咖啡牛奶"
    var defaultDescription: String  // 默认描述，如 "150ml全脂牛奶"
    var createdAt: Date
    var usageCount: Int          // 使用次数，用于排序

    // 具体的营养数值，用于确保一致性
    var defaultGrams: Double?
    var defaultCalories: Double?
    var defaultProtein: Double?
    var defaultCarbs: Double?
    var defaultFat: Double?

    init(keyword: String, defaultDescription: String) {
        self.id = UUID()
        self.keyword = keyword
        self.defaultDescription = defaultDescription
        self.createdAt = Date()
        self.usageCount = 1
    }

    /// 创建带有具体营养数值的偏好
    convenience init(keyword: String, grams: Double, calories: Double, protein: Double, carbs: Double, fat: Double) {
        self.init(keyword: keyword, defaultDescription: "\(Int(grams))g, \(Int(calories))kcal")
        self.defaultGrams = grams
        self.defaultCalories = calories
        self.defaultProtein = protein
        self.defaultCarbs = carbs
        self.defaultFat = fat
    }

    /// 生成用于 AI prompt 的详细描述
    var promptDescription: String {
        if let grams = defaultGrams,
           let calories = defaultCalories,
           let protein = defaultProtein,
           let carbs = defaultCarbs,
           let fat = defaultFat {
            return "\(Int(grams))g, \(Int(calories))kcal, 蛋白质\(String(format: "%.1f", protein))g, 碳水\(String(format: "%.1f", carbs))g, 脂肪\(String(format: "%.1f", fat))g"
        }
        return defaultDescription
    }
}
